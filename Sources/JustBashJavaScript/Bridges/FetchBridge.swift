import Foundation
import JavaScriptCore
import JustBashCommands

/// Installs the `fetch()` global, backed by URLSession and gated by
/// `CommandContext.allowedURLPrefixes`, including redirects. File URLs resolve
/// through the command's workspace filesystem.
///
/// `fetch` returns a Promise to look like Node's contract, but the underlying
/// URLSession call blocks the JSC thread until completion. This works because
/// the engine actor's thread is the only JS thread, so blocking it doesn't
/// deprive any JS code of execution. The Promise is already resolved (or
/// rejected) by the time the JS receiver calls `.then`, so microtask
/// scheduling proceeds normally.
func installFetchBridge(into context: JSContext, execution: JSCExecutionContext) {
    let fetchFn: @convention(block) (String, JSValue?) -> JSValue? = { urlString, init_ in
        let initObject = init_.flatMap { $0.isObject && !$0.isNull ? $0 : nil }
        let methodValue = initObject?.objectForKeyedSubscript("method")
        let method = (methodValue.flatMap { $0.isUndefined || $0.isNull ? nil : $0.toString() } ?? "GET").uppercased()
        var headers: [String: String] = [:]
        if let headersValue = initObject?.objectForKeyedSubscript("headers"), !headersValue.isUndefined {
            if let dict = headersValue.toObject() as? [String: Any] {
                for (k, v) in dict { headers[k] = "\(v)" }
            }
        }
        var bodyData: Data? = nil
        if let bodyValue = initObject?.objectForKeyedSubscript("body"), !bodyValue.isUndefined && !bodyValue.isNull {
            bodyData = jsValueToData(bodyValue)
        }

        guard let url = URL(string: urlString) else {
            return rejectedPromise(message: "fetch: invalid URL: \(urlString)", in: context)
        }

        do {
            if let data = try CommandNetworkAccess.localData(for: url, context: execution.cmdCtx) {
                guard method == "GET" || method == "HEAD" else {
                    return rejectedPromise(message: "fetch: local resources support only GET and HEAD", in: context)
                }
                let response = makeResponse(status: 200, headers: [:], data: method == "HEAD" ? Data() : data, in: context)
                return resolvedPromise(value: response, in: context)
            }
        } catch {
            return rejectedPromise(message: "fetch: \(error.localizedDescription)", in: context)
        }
        guard CommandNetworkAccess.isAllowed(url, prefixes: execution.cmdCtx.allowedURLPrefixes) else {
            return rejectedPromise(message: "fetch: URL not in allow-list: \(urlString)", in: context)
        }

        let timeoutMs = execution.cmdCtx.allowedURLPrefixes.isEmpty
            ? execution.options.defaultTimeoutMs
            : execution.options.defaultNetworkTimeoutMs

        let result = performBlockingFetch(url: url, method: method, headers: headers, body: bodyData, timeoutMs: timeoutMs, allowedURLPrefixes: execution.cmdCtx.allowedURLPrefixes)
        switch result {
        case .failure(let message):
            return rejectedPromise(message: message, in: context)
        case .success(let payload):
            let response = makeResponse(status: payload.status, headers: payload.headers, data: payload.data, in: context)
            return resolvedPromise(value: response, in: context)
        }
    }
    context.setObject(fetchFn, forKeyedSubscript: "fetch" as NSString)
}

private struct FetchPayload {
    let status: Int
    let headers: [String: String]
    let data: Data
}

private enum FetchResult {
    case success(FetchPayload)
    case failure(String)
}

private final class FetchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: FetchResult?
    func store(_ v: FetchResult) { lock.lock(); value = v; lock.unlock() }
    func read() -> FetchResult? { lock.lock(); let v = value; lock.unlock(); return v }
}

/// Synchronously invokes URLSession.data(for:) by waiting on a semaphore.
/// Safe inside the engine actor: the call to fetch already runs on the
/// actor's executor, so blocking that executor doesn't starve other JS.
private func performBlockingFetch(url: URL, method: String, headers: [String: String], body: Data?, timeoutMs: Int, allowedURLPrefixes: [String]) -> FetchResult {
    let semaphore = DispatchSemaphore(value: 0)
    let box = FetchBox()
    let task = Task.detached(priority: .userInitiated) {
        do {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = Double(max(1, timeoutMs)) / 1000
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            if let body = body { request.httpBody = body }
            let (data, response) = try await CommandNetworkAccess.data(for: request, allowedURLPrefixes: allowedURLPrefixes)
            let status: Int
            var responseHeaders: [String: String] = [:]
            if let http = response as? HTTPURLResponse {
                status = http.statusCode
                for (k, v) in http.allHeaderFields { responseHeaders["\(k)"] = "\(v)" }
            } else {
                status = 200
            }
            box.store(.success(FetchPayload(status: status, headers: responseHeaders, data: data)))
        } catch {
            box.store(.failure("fetch failed: \(error.localizedDescription)"))
        }
        semaphore.signal()
    }
    let deadline = DispatchTime.now() + .milliseconds(max(1, timeoutMs))
    while semaphore.wait(timeout: min(deadline, .now() + .milliseconds(10))) == .timedOut {
        if Task.isCancelled {
            task.cancel()
            return .failure("fetch: cancelled")
        }
        if DispatchTime.now() >= deadline {
            task.cancel()
            return .failure("fetch: timed out after \(timeoutMs)ms")
        }
    }
    return box.read() ?? .failure("fetch: no result")
}

private func resolvedPromise(value: JSValue, in context: JSContext) -> JSValue? {
    let factory = context.evaluateScript("(function(v) { return Promise.resolve(v); })")
    return factory?.call(withArguments: [value])
}

private func rejectedPromise(message: String, in context: JSContext) -> JSValue? {
    let factory = context.evaluateScript("(function(msg) { return Promise.reject(new Error(msg)); })")
    return factory?.call(withArguments: [message])
}

private func makeResponse(status: Int, headers: [String: String], data: Data, in context: JSContext) -> JSValue {
    let factory = context.evaluateScript("""
    (function(status, headers, bodyText, bodyBase64) {
      return {
        status: status,
        statusText: status === 200 ? 'OK' : '',
        ok: status >= 200 && status < 300,
        headers: { get: function(k) { return headers[k] || headers[k.toLowerCase()] || null; }, raw: headers },
        text: function() { return Promise.resolve(bodyText); },
        json: function() { try { return Promise.resolve(JSON.parse(bodyText)); } catch (e) { return Promise.reject(e); } },
        arrayBuffer: function() {
          var binary = atob(bodyBase64);
          var arr = new Uint8Array(binary.length);
          for (var i = 0; i < binary.length; i++) arr[i] = binary.charCodeAt(i);
          return Promise.resolve(arr.buffer);
        }
      };
    })
    """)!
    return factory.call(withArguments: [status, headers, String(decoding: data, as: UTF8.self), data.base64EncodedString()])!
}
