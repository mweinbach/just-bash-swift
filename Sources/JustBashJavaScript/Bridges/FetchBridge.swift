import Foundation
import JavaScriptCore

/// Installs the `fetch()` global, backed by URLSession and gated by
/// `CommandContext.allowedURLPrefixes` (same allow-list semantics as
/// `Sources/JustBashCommands/CurlCommand.swift:33-38`).
///
/// `fetch` returns a Promise to look like Node's contract, but the underlying
/// URLSession call blocks the JSC thread until completion. This works because
/// the engine actor's thread is the only JS thread, so blocking it doesn't
/// deprive any JS code of execution. The Promise is already resolved (or
/// rejected) by the time the JS receiver calls `.then`, so microtask
/// scheduling proceeds normally.
func installFetchBridge(into context: JSContext, execution: JSCExecutionContext) {
    let fetchFn: @convention(block) (String, JSValue?) -> JSValue? = { urlString, init_ in
        let allowed = execution.cmdCtx.allowedURLPrefixes
        let isLocal = urlString.hasPrefix("data:") || urlString.hasPrefix("file:")
        if !isLocal {
            if allowed.isEmpty || !allowed.contains(where: { urlString.hasPrefix($0) }) {
                return rejectedPromise(message: "fetch: URL not in allow-list: \(urlString)", in: context)
            }
        }

        let method = (init_?.objectForKeyedSubscript("method")?.toString() ?? "GET").uppercased()
        var headers: [String: String] = [:]
        if let init_ = init_, let headersValue = init_.objectForKeyedSubscript("headers"), !headersValue.isUndefined {
            if let dict = headersValue.toObject() as? [String: Any] {
                for (k, v) in dict { headers[k] = "\(v)" }
            }
        }
        var bodyData: Data? = nil
        if let init_ = init_, let bodyValue = init_.objectForKeyedSubscript("body"), !bodyValue.isUndefined && !bodyValue.isNull {
            bodyData = jsValueToData(bodyValue)
        }

        guard let url = URL(string: urlString) else {
            return rejectedPromise(message: "fetch: invalid URL: \(urlString)", in: context)
        }

        let timeoutMs = execution.cmdCtx.allowedURLPrefixes.isEmpty
            ? execution.options.defaultTimeoutMs
            : execution.options.defaultNetworkTimeoutMs

        let result = performBlockingFetch(url: url, method: method, headers: headers, body: bodyData, timeoutMs: timeoutMs)
        switch result {
        case .failure(let message):
            return rejectedPromise(message: message, in: context)
        case .success(let payload):
            let response = makeResponse(status: payload.status, headers: payload.headers, bodyText: payload.bodyText, in: context)
            return resolvedPromise(value: response, in: context)
        }
    }
    context.setObject(fetchFn, forKeyedSubscript: "fetch" as NSString)
}

private struct FetchPayload {
    let status: Int
    let headers: [String: String]
    let bodyText: String
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
private func performBlockingFetch(url: URL, method: String, headers: [String: String], body: Data?, timeoutMs: Int) -> FetchResult {
    let semaphore = DispatchSemaphore(value: 0)
    let box = FetchBox()
    Task.detached(priority: .userInitiated) {
        do {
            var request = URLRequest(url: url)
            request.httpMethod = method
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            if let body = body { request.httpBody = body }
            let (data, response) = try await URLSession.shared.data(for: request)
            let status: Int
            var responseHeaders: [String: String] = [:]
            if let http = response as? HTTPURLResponse {
                status = http.statusCode
                for (k, v) in http.allHeaderFields { responseHeaders["\(k)"] = "\(v)" }
            } else {
                status = 200
            }
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            box.store(.success(FetchPayload(status: status, headers: responseHeaders, bodyText: bodyText)))
        } catch {
            box.store(.failure("fetch failed: \(error.localizedDescription)"))
        }
        semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + .milliseconds(timeoutMs)) == .timedOut {
        return .failure("fetch: timed out after \(timeoutMs)ms")
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

private func makeResponse(status: Int, headers: [String: String], bodyText: String, in context: JSContext) -> JSValue {
    let factory = context.evaluateScript("""
    (function(status, headers, bodyText) {
      return {
        status: status,
        statusText: status === 200 ? 'OK' : '',
        ok: status >= 200 && status < 300,
        headers: { get: function(k) { return headers[k] || headers[k.toLowerCase()] || null; }, raw: headers },
        text: function() { return Promise.resolve(bodyText); },
        json: function() { try { return Promise.resolve(JSON.parse(bodyText)); } catch (e) { return Promise.reject(e); } },
        arrayBuffer: function() {
          var arr = new Uint8Array(bodyText.length);
          for (var i = 0; i < bodyText.length; i++) arr[i] = bodyText.charCodeAt(i) & 0xff;
          return Promise.resolve(arr.buffer);
        }
      };
    })
    """)!
    return factory.call(withArguments: [status, headers, bodyText])!
}
