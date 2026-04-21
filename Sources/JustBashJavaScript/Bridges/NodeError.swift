import Foundation
import JavaScriptCore
import JustBashFS

/// Builds Node-shaped error objects from Swift filesystem errors so JS code
/// can catch them with familiar `err.code === 'ENOENT'` patterns.
///
/// Mapping mirrors POSIX-equivalent codes used by Node's fs module.
/// Accepts both the protocol-level `FilesystemError` and the older
/// `VirtualFileSystemError` so both VFS implementations route correctly.
enum NodeErrorMapper {
    static func code(for error: FilesystemError) -> String {
        switch error {
        case .invalidPath: return "EINVAL"
        case .notFound: return "ENOENT"
        case .notDirectory: return "ENOTDIR"
        case .isDirectory: return "EISDIR"
        case .alreadyExists: return "EEXIST"
        case .directoryNotEmpty: return "ENOTEMPTY"
        case .permissionDenied: return "EACCES"
        case .ioError: return "EIO"
        case .notSupported: return "ENOSYS"
        }
    }

    static func errno(for error: FilesystemError) -> Int {
        switch error {
        case .invalidPath: return -22
        case .notFound: return -2
        case .notDirectory: return -20
        case .isDirectory: return -21
        case .alreadyExists: return -17
        case .directoryNotEmpty: return -39
        case .permissionDenied: return -13
        case .ioError: return -5
        case .notSupported: return -38
        }
    }

    static func code(for error: VirtualFileSystemError) -> String {
        switch error {
        case .invalidPath: return "EINVAL"
        case .notFound: return "ENOENT"
        case .notDirectory: return "ENOTDIR"
        case .isDirectory: return "EISDIR"
        case .alreadyExists: return "EEXIST"
        case .directoryNotEmpty: return "ENOTEMPTY"
        }
    }

    static func errno(for error: VirtualFileSystemError) -> Int {
        switch error {
        case .invalidPath: return -22
        case .notFound: return -2
        case .notDirectory: return -20
        case .isDirectory: return -21
        case .alreadyExists: return -17
        case .directoryNotEmpty: return -39
        }
    }

    /// Maps any thrown filesystem error (FilesystemError, VirtualFileSystemError,
    /// or generic Error) to a Node-shaped Error JSValue.
    static func makeError(forAny error: Error, path: String?, syscall: String?, in context: JSContext) -> JSValue {
        let code: String
        let errno: Int
        if let fs = error as? FilesystemError {
            code = self.code(for: fs); errno = self.errno(for: fs)
        } else if let vfs = error as? VirtualFileSystemError {
            code = self.code(for: vfs); errno = self.errno(for: vfs)
        } else {
            code = "EIO"; errno = -5
        }
        let message = sanitizeMessage((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        return makeError(message: message, code: code, errno: errno, path: path, syscall: syscall, in: context)
    }

    static func makeError(for error: FilesystemError, path: String?, syscall: String?, in context: JSContext) -> JSValue {
        let message = sanitizeMessage(error.errorDescription ?? code(for: error))
        return makeError(message: message, code: code(for: error), errno: errno(for: error), path: path, syscall: syscall, in: context)
    }

    private static func makeError(message: String, code: String, errno: Int, path: String?, syscall: String?, in context: JSContext) -> JSValue {
        // Construct via JS factory so the resulting value is a real Error
        // instance with attached `code`, `errno`, `path`, and `syscall`
        // properties — matching Node's fs error shape.
        let factory = context.evaluateScript("""
        (function(message, code, errno, path, syscall) {
          var e = new Error(message);
          e.code = code;
          e.errno = errno;
          if (path) e.path = path;
          if (syscall) e.syscall = syscall;
          return e;
        })
        """)!
        return factory.call(withArguments: [message, code, errno, path ?? NSNull(), syscall ?? NSNull()])!
    }

    /// Strip host-OS path prefixes from error messages so sandbox code never
    /// sees the embedder's filesystem layout. Mirrors upstream
    /// `src/fs/sanitize-error.ts`.
    static func sanitizeMessage(_ message: String) -> String {
        var sanitized = message
        let hostPrefixes = ["/Users/", "/private/var/", "/var/folders/"]
        for prefix in hostPrefixes {
            while let range = sanitized.range(of: prefix) {
                if let end = sanitized[range.upperBound...].firstIndex(where: { $0 == " " || $0 == "\n" || $0 == "\"" || $0 == "'" }) {
                    sanitized.replaceSubrange(range.lowerBound..<end, with: "<host-path>")
                } else {
                    sanitized.replaceSubrange(range.lowerBound..<sanitized.endIndex, with: "<host-path>")
                }
            }
        }
        return sanitized
    }
}
