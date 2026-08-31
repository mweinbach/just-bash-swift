import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Shared transport for built-in commands and embedded runtimes. Hosts adding
/// their own network commands should use this transport or enforce the context's
/// allow-list themselves.
public enum CommandNetworkAccess {
    /// HTTP(S) requests must match an allowed prefix and its origin. A host-only
    /// prefix cannot match a different host with the same textual beginning.
    public static func isAllowed(_ url: URL, prefixes: [String]) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil, url.user == nil, url.password == nil else { return false }
        let canonical = url.standardized.absoluteString
        return prefixes.contains { prefix in
            if prefix.lowercased() == "\(scheme)://" { return true }
            guard let base = URL(string: prefix), base.scheme?.lowercased() == scheme,
                  base.host?.lowercased() == url.host?.lowercased(),
                  effectivePort(base) == effectivePort(url), base.user == nil, base.password == nil
            else { return false }
            return canonical.hasPrefix(base.standardized.absoluteString)
        }
    }

    /// Data URLs and local file URLs never use Foundation's physical filesystem.
    /// A file URL names a path inside the supplied virtual/workspace filesystem.
    public static func localData(for url: URL, context: CommandContext) throws -> Data? {
        if url.scheme?.lowercased() == "data" {
            let source = url.absoluteString
            guard let comma = source.firstIndex(of: ",") else { throw AccessError("invalid data URL") }
            let metadata = String(source[..<comma])
            let payload = String(source[source.index(after: comma)...])
            let decoded = payload.removingPercentEncoding ?? payload
            if metadata.lowercased().contains(";base64") {
                guard let data = Data(base64Encoded: decoded) else { throw AccessError("invalid base64 data URL") }
                return data
            }
            return Data(decoded.utf8)
        }
        if url.isFileURL {
            guard url.host == nil || url.host == "" || url.host?.lowercased() == "localhost" else {
                throw AccessError("file URL must refer to the workspace filesystem")
            }
            return try context.fileSystem.readFile(path: url.path, relativeTo: context.cwd)
        }
        return nil
    }

    /// Checks every redirect before it is sent, including transport used by git.
    public static func data(for request: URLRequest, allowedURLPrefixes: [String]) async throws -> (Data, URLResponse) {
        guard let url = request.url, isAllowed(url, prefixes: allowedURLPrefixes) else {
            throw AccessError("access denied — URL not in allow-list: \(request.url?.absoluteString ?? "invalid URL")")
        }
        try Task.checkCancellation()
        let delegate = RedirectPolicy(prefixes: allowedURLPrefixes)
        let result = try await URLSession.shared.data(for: request, delegate: delegate)
        if let denied = delegate.deniedURL {
            throw AccessError("access denied — redirect URL not in allow-list: \(denied)")
        }
        return result
    }

    private static func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }

    private struct AccessError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let prefixes: [String]
        private let lock = NSLock()
        private var denied: String?
        var deniedURL: String? { lock.withLock { denied } }

        init(prefixes: [String]) { self.prefixes = prefixes }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard let url = request.url, CommandNetworkAccess.isAllowed(url, prefixes: prefixes) else {
                lock.withLock { denied = request.url?.absoluteString ?? "invalid URL" }
                completionHandler(nil)
                return
            }
            var next = request
            if response.url?.host != url.host || response.url?.scheme != url.scheme || response.url?.port != url.port {
                next.setValue(nil, forHTTPHeaderField: "Authorization")
                next.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
                next.setValue(nil, forHTTPHeaderField: "Cookie")
            }
            completionHandler(next)
        }
    }
}
