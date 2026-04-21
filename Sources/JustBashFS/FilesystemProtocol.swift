import Foundation

// MARK: - File Info

/// Metadata about a file or directory in the filesystem.
///
/// This structure provides essential information about a filesystem entry,
/// including its path, type, and size. It is designed to be lightweight
/// and suitable for use across different filesystem implementations.
public struct FileInfo: Sendable, Equatable {
    /// The normalized absolute path of the file or directory.
    public let path: String

    /// The type of filesystem node (file, directory, or symlink).
    public let kind: FileNodeKind

    /// The size of the entry in bytes.
    /// - For files: the content size
    /// - For directories: the number of entries
    /// - For symlinks: the length of the target path
    public let size: Int

    /// Creates a new file info instance.
    ///
    /// - Parameters:
    ///   - path: The normalized absolute path
    ///   - kind: The type of filesystem node
    ///   - size: The size in bytes or entry count
    public init(path: String, kind: FileNodeKind, size: Int) {
        self.path = path
        self.kind = kind
        self.size = size
    }
}

// MARK: - File Node Kind

/// The type of a filesystem node.
///
/// Represents the fundamental types of entries that can exist in a
/// bash-compatible filesystem abstraction.
public enum FileNodeKind: String, Sendable, Equatable {
    /// A regular file containing data.
    case file

    /// A directory containing other entries.
    case directory

    /// A symbolic link pointing to another path.
    case symlink
}

// MARK: - Filesystem Errors

/// Errors that can occur during filesystem operations.
///
/// These errors map to common POSIX-style filesystem error conditions
/// that bash scripts expect to handle.
public enum FilesystemError: Error, LocalizedError, Equatable {
    /// The specified path is invalid or malformed.
    case invalidPath(String)

    /// The file or directory does not exist.
    case notFound(String)

    /// The path exists but is not a directory.
    case notDirectory(String)

    /// The path exists and is a directory (not a file).
    case isDirectory(String)

    /// A file or directory already exists at the target path.
    case alreadyExists(String)

    /// The directory is not empty and cannot be removed.
    case directoryNotEmpty(String)

    /// Permission denied for the operation.
    case permissionDenied(String)

    /// An I/O error occurred during the operation.
    case ioError(String)

    /// The operation is not supported by this filesystem implementation.
    case notSupported(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path):
            return "invalid path: \(path)"
        case .notFound(let path):
            return "no such file or directory: \(path)"
        case .notDirectory(let path):
            return "not a directory: \(path)"
        case .isDirectory(let path):
            return "is a directory: \(path)"
        case .alreadyExists(let path):
            return "file exists: \(path)"
        case .directoryNotEmpty(let path):
            return "directory not empty: \(path)"
        case .permissionDenied(let path):
            return "permission denied: \(path)"
        case .ioError(let details):
            return "I/O error: \(details)"
        case .notSupported(let operation):
            return "operation not supported: \(operation)"
        }
    }
}

// MARK: - Bash Filesystem Protocol

/// A protocol that abstracts filesystem operations for bash-compatible environments.
///
/// The `BashFilesystem` protocol defines a common interface for filesystem
/// implementations that can be used by the shell interpreter and command handlers.
/// It provides operations for reading, writing, and manipulating files and directories
/// in a way that's compatible with bash semantics.
///
/// ## Concurrency Safety
///
/// This protocol extends `Sendable`, meaning all implementations must be safe to
/// use across concurrent contexts. Implementations should handle synchronization
/// internally or use immutable data structures.
///
/// ## Path Handling
///
/// All paths passed to and returned from these methods should follow these rules:
/// - Paths are normalized using `normalizePath(_:relativeTo:)` before operations
/// - Absolute paths start with `/`
/// - Relative paths are resolved against the provided `relativeTo` parameter
/// - Path components are separated by `/`
/// - Empty components and `.` are ignored
/// - `..` moves to the parent directory
///
/// ## Example Usage
///
/// ```swift
/// func exampleUsage(fs: some BashFilesystem) throws {
///     // Create a directory
///     try fs.createDirectory(path: "/tmp/test", relativeTo: "/")
///
///     // Write a file
///     let data = "Hello, World!".data(using: .utf8)!
///     try fs.writeFile(path: "/tmp/test/hello.txt", content: data)
///
///     // Read it back
///     let readData = try fs.readFile(path: "/tmp/test/hello.txt")
///
///     // Check if file exists
///     if fs.fileExists(path: "/tmp/test/hello.txt") {
///         print("File exists!")
///     }
/// }
/// ```
public protocol BashFilesystem: Sendable {
    // MARK: - File Operations

    /// Reads the contents of a file at the specified path.
    ///
    /// - Parameters:
    ///   - path: The path to the file to read
    ///   - relativeTo: The working directory for resolving relative paths (defaults to "/")
    /// - Returns: The raw file contents as `Data`
    /// - Throws: `FilesystemError.notFound` if the file doesn't exist
    /// - Throws: `FilesystemError.isDirectory` if the path is a directory
    /// - Throws: `FilesystemError.invalidPath` if the path is malformed
    func readFile(path: String, relativeTo: String) throws -> Data

    /// Writes content to a file at the specified path.
    ///
    /// If the file already exists, its contents are replaced. If the file
    /// doesn't exist, it is created. Parent directories must exist unless
    /// the implementation provides automatic directory creation.
    ///
    /// - Parameters:
    ///   - path: The path to the file to write
    ///   - content: The data to write to the file
    ///   - relativeTo: The working directory for resolving relative paths (defaults to "/")
    /// - Throws: `FilesystemError.isDirectory` if the path is a directory
    /// - Throws: `FilesystemError.notDirectory` if a parent path exists but isn't a directory
    /// - Throws: `FilesystemError.invalidPath` if the path is malformed
    func writeFile(path: String, content: Data, relativeTo: String) throws

    /// Deletes the file or directory at the specified path.
    ///
    /// For directories, the behavior depends on whether they are empty.
    /// Some implementations may support recursive deletion.
    ///
    /// - Parameters:
    ///   - path: The path to the file or directory to delete
    ///   - relativeTo: The working directory for resolving relative paths (defaults to "/")
    ///   - recursive: If true, directories and their contents are removed recursively
    ///   - force: If true, non-existent paths don't raise errors
    /// - Throws: `FilesystemError.notFound` if the path doesn't exist (and force is false)
    /// - Throws: `FilesystemError.directoryNotEmpty` if the directory isn't empty (and recursive is false)
    /// - Throws: `FilesystemError.invalidPath` if the path is malformed
    func deleteFile(path: String, relativeTo: String, recursive: Bool, force: Bool) throws

    // MARK: - Path Queries

    /// Returns whether a file or directory exists at the specified path.
    ///
    /// This method returns `false` for broken symlinks (symlinks pointing
    /// to non-existent targets).
    ///
    /// - Parameters:
    ///   - path: The path to check
    ///   - relativeTo: The working directory for resolving relative paths (defaults to "/")
    /// - Returns: `true` if a file or directory exists at the path, `false` otherwise
    func fileExists(path: String, relativeTo: String) -> Bool

    /// Returns whether the path exists and is a directory.
    ///
    /// This method returns `false` if the path doesn't exist or if it's a file
    /// or symlink (even if the symlink points to a directory). To check symlink
    /// targets, use `fileInfo(path:relativeTo:)`.
    ///
    /// - Parameters:
    ///   - path: The path to check
    ///   - relativeTo: The working directory for resolving relative paths (defaults to "/")
    /// - Returns: `true` if the path exists and is a directory, `false` otherwise
    func isDirectory(path: String, relativeTo: String) -> Bool

    // MARK: - Directory Operations

    /// Lists the entries in a directory.
    ///
    /// Returns the names of entries (not full paths) in the specified directory.
    /// The order of entries is implementation-defined.
    ///
    /// - Parameters:
    ///   - path: The path to the directory to list
    ///   - relativeTo: The working directory for resolving relative paths (defaults to "/")
    /// - Returns: An array of entry names in the directory
    /// - Throws: `FilesystemError.notFound` if the directory doesn't exist
    /// - Throws: `FilesystemError.notDirectory` if the path is not a directory
    /// - Throws: `FilesystemError.invalidPath` if the path is malformed
    func listDirectory(path: String, relativeTo: String) throws -> [String]

    /// Creates a directory at the specified path.
    ///
    /// If the directory already exists, this operation succeeds silently.
    /// Parent directories are created only if `recursive` is `true`.
    ///
    /// - Parameters:
    ///   - path: The path to the directory to create
    ///   - relativeTo: The working directory for resolving relative paths (defaults to "/")
    ///   - recursive: If true, create parent directories as needed
    /// - Throws: `FilesystemError.notDirectory` if a parent path exists but isn't a directory
    /// - Throws: `FilesystemError.invalidPath` if the path is malformed
    func createDirectory(path: String, relativeTo: String, recursive: Bool) throws

    // MARK: - File Information

    /// Returns detailed information about a file or directory.
    ///
    /// - Parameters:
    ///   - path: The path to get information about
    ///   - relativeTo: The working directory for resolving relative paths (defaults to "/")
    /// - Returns: A `FileInfo` structure containing metadata about the entry
    /// - Throws: `FilesystemError.notFound` if the path doesn't exist
    /// - Throws: `FilesystemError.invalidPath` if the path is malformed
    func fileInfo(path: String, relativeTo: String) throws -> FileInfo

    // MARK: - Directory Walking

    /// Recursively walks a directory tree and returns all paths.
    ///
    /// Returns all paths under the specified path, including the starting
    /// path itself. The paths are returned in depth-first order.
    ///
    /// For a directory at `/foo` containing files `/foo/bar.txt` and
    /// `/foo/baz/qux.txt`, the returned array would be:
    /// `[/foo, /foo/bar.txt, /foo/baz, /foo/baz/qux.txt]`
    ///
    /// - Parameters:
    ///   - path: The root path to start walking from
    ///   - relativeTo: The working directory for resolving relative paths (defaults to "/")
    /// - Returns: An array of all paths under the root, in depth-first order
    /// - Throws: `FilesystemError.notFound` if the starting path doesn't exist
    /// - Throws: `FilesystemError.invalidPath` if the path is malformed
    func walk(path: String, relativeTo: String) throws -> [String]

    // MARK: - Path Utilities

    /// Normalizes a path to its canonical form.
    ///
    /// This method resolves relative paths against the `relativeTo` parameter,
    /// collapses `.` and `..` components, removes redundant separators, and
    /// returns an absolute path starting with `/`.
    ///
    /// Normalization rules:
    /// - Relative paths are resolved against `relativeTo`
    /// - Empty path components are removed
    /// - `.` components are removed
    /// - `..` components move up one level (or are removed at root)
    /// - Multiple `/` separators are collapsed to one
    /// - The result always starts with `/`
    ///
    /// Examples:
    /// - `normalizePath("foo/bar", relativeTo: "/home")` → `/home/foo/bar`
    /// - `normalizePath("../baz", relativeTo: "/home/user")` → `/home/baz`
    /// - `normalizePath("/a/b/../c", relativeTo: "/")` → `/a/c`
    /// - `normalizePath(".", relativeTo: "/home")` → `/home`
    ///
    /// - Parameters:
    ///   - path: The path to normalize
    ///   - relativeTo: The base directory for resolving relative paths (defaults to "/")
    /// - Returns: The normalized absolute path
    func normalizePath(_ path: String, relativeTo: String) -> String
    
    // MARK: - Glob Pattern Matching
    
    /// Performs glob pattern matching on the filesystem.
    ///
    /// This method expands glob patterns like `*.txt` or `/tmp/*/file` into
    /// matching file paths in the filesystem. Supports standard glob patterns
    /// including `*`, `?`, and character classes `[...]`.
    ///
    /// - Parameters:
    ///   - pattern: The glob pattern to match
    ///   - relativeTo: The working directory for resolving relative paths (defaults to "/")
    ///   - dotglob: If true, include hidden files (starting with ".") in matches
    ///   - extglob: If true, enable extended glob patterns like `*(pattern)`
    /// - Returns: An array of matching paths, sorted alphabetically
    func glob(_ pattern: String, relativeTo: String, dotglob: Bool, extglob: Bool) -> [String]
}

// MARK: - Default Parameters Extension

extension BashFilesystem {
    /// Reads the contents of a file at the specified path.
    ///
    /// - Parameter path: The path to the file to read
    /// - Returns: The raw file contents as `Data`
    public func readFile(path: String) throws -> Data {
        return try readFile(path: path, relativeTo: "/")
    }

    /// Writes content to a file at the specified path.
    ///
    /// - Parameters:
    ///   - path: The path to the file to write
    ///   - content: The data to write to the file
    public func writeFile(path: String, content: Data) throws {
        try writeFile(path: path, content: content, relativeTo: "/")
    }

    /// Deletes the file or directory at the specified path.
    ///
    /// - Parameter path: The path to the file or directory to delete
    public func deleteFile(path: String) throws {
        try deleteFile(path: path, relativeTo: "/", recursive: false, force: false)
    }

    /// Returns whether a file or directory exists at the specified path.
    ///
    /// - Parameter path: The path to check
    /// - Returns: `true` if a file or directory exists at the path
    public func fileExists(path: String) -> Bool {
        return fileExists(path: path, relativeTo: "/")
    }

    /// Returns whether the path exists and is a directory.
    ///
    /// - Parameter path: The path to check
    /// - Returns: `true` if the path exists and is a directory
    public func isDirectory(path: String) -> Bool {
        return isDirectory(path: path, relativeTo: "/")
    }

    /// Lists the entries in a directory.
    ///
    /// - Parameter path: The path to the directory to list
    /// - Returns: An array of entry names in the directory
    public func listDirectory(path: String) throws -> [String] {
        return try listDirectory(path: path, relativeTo: "/")
    }

    /// Creates a directory at the specified path.
    ///
    /// - Parameters:
    ///   - path: The path to the directory to create
    ///   - recursive: If true, create parent directories as needed
    public func createDirectory(path: String, recursive: Bool = false) throws {
        try createDirectory(path: path, relativeTo: "/", recursive: recursive)
    }

    /// Returns detailed information about a file or directory.
    ///
    /// - Parameter path: The path to get information about
    /// - Returns: A `FileInfo` structure containing metadata
    public func fileInfo(path: String) throws -> FileInfo {
        return try fileInfo(path: path, relativeTo: "/")
    }

    /// Recursively walks a directory tree and returns all paths.
    ///
    /// - Parameter path: The root path to start walking from
    /// - Returns: An array of all paths under the root
    public func walk(path: String) throws -> [String] {
        return try walk(path: path, relativeTo: "/")
    }

    /// Normalizes a path to its canonical form.
    ///
    /// - Parameter path: The path to normalize
    /// - Returns: The normalized absolute path
    public func normalizePath(_ path: String) -> String {
        return normalizePath(path, relativeTo: "/")
    }
}

// MARK: - Legacy API Extension for Backward Compatibility

extension BashFilesystem {
    /// Reads the contents of a file as a String (legacy API).
    ///
    /// - Parameters:
    ///   - path: The path to the file to read
    ///   - relativeTo: The working directory for resolving relative paths
    /// - Returns: The file contents as a String
    /// - Throws: `FilesystemError` if the file cannot be read
    public func readFile(_ path: String, relativeTo: String = "/") throws -> String {
        let data = try readFile(path: path, relativeTo: relativeTo)
        return String(decoding: data, as: UTF8.self)
    }
    
    /// Writes a String to a file (legacy API).
    ///
    /// - Parameters:
    ///   - content: The string content to write
    ///   - path: The path to the file to write
    ///   - relativeTo: The working directory for resolving relative paths
    /// - Throws: `FilesystemError` if the file cannot be written
    public func writeFile(_ content: String, to path: String, relativeTo: String = "/") throws {
        let data = Data(content.utf8)
        try writeFile(path: path, content: data, relativeTo: relativeTo)
    }
    
    /// Returns whether a file or directory exists at the specified path (legacy API).
    ///
    /// - Parameters:
    ///   - path: The path to check
    ///   - relativeTo: The working directory for resolving relative paths
    /// - Returns: `true` if a file or directory exists at the path
    public func exists(_ path: String, relativeTo: String = "/") -> Bool {
        return fileExists(path: path, relativeTo: relativeTo)
    }
    
    /// Deletes the file or directory at the specified path (legacy API).
    ///
    /// - Parameters:
    ///   - path: The path to the file or directory to delete
    ///   - relativeTo: The working directory for resolving relative paths
    ///   - recursive: If true, directories and their contents are removed recursively
    ///   - force: If true, non-existent paths don't raise errors
    /// - Throws: `FilesystemError` if the path doesn't exist (and force is false)
    public func removeItem(_ path: String, relativeTo: String = "/", recursive: Bool = false, force: Bool = false) throws {
        try deleteFile(path: path, relativeTo: relativeTo, recursive: recursive, force: force)
    }
    
    /// Creates a directory at the specified path (legacy API).
    ///
    /// - Parameters:
    ///   - path: The path to the directory to create
    ///   - relativeTo: The working directory for resolving relative paths
    ///   - recursive: If true, create parent directories as needed
    /// - Throws: `FilesystemError` if the directory cannot be created
    public func createDirectory(_ path: String, relativeTo: String = "/", recursive: Bool = false) throws {
        try createDirectory(path: path, relativeTo: relativeTo, recursive: recursive)
    }
    
    /// Returns detailed information about a file or directory (legacy API).
    ///
    /// - Parameters:
    ///   - path: The path to get information about
    ///   - relativeTo: The working directory for resolving relative paths
    /// - Returns: A `FileInfo` structure containing metadata
    /// - Throws: `FilesystemError` if the path doesn't exist
    public func fileInfo(_ path: String, relativeTo: String = "/") throws -> FileInfo {
        return try fileInfo(path: path, relativeTo: relativeTo)
    }
    
    /// Returns whether the path exists and is a directory (legacy API).
    ///
    /// - Parameters:
    ///   - path: The path to check
    ///   - relativeTo: The working directory for resolving relative paths
    /// - Returns: `true` if the path exists and is a directory
    public func isDirectory(_ path: String, relativeTo: String = "/") -> Bool {
        return isDirectory(path: path, relativeTo: relativeTo)
    }
    
    /// Lists the entries in a directory (legacy API with includeHidden support for VirtualFileSystem).
    /// This default implementation ignores includeHidden; VirtualFileSystem provides the full implementation.
    ///
    /// - Parameters:
    ///   - path: The path to the directory to list
    ///   - relativeTo: The working directory for resolving relative paths
    ///   - includeHidden: If true, include hidden entries (entries starting with ".")
    /// - Returns: An array of entry names in the directory
    /// - Throws: `FilesystemError` if the directory doesn't exist
    public func listDirectory(_ path: String, relativeTo: String = "/", includeHidden: Bool = false) throws -> [String] {
        let entries = try listDirectory(path: path, relativeTo: relativeTo)
        if includeHidden {
            return entries
        }
        return entries.filter { !$0.hasPrefix(".") }
    }
    
    /// Copies an item from source to destination (legacy API).
    /// Default implementation throws `notSupported`; VirtualFileSystem provides the full implementation.
    ///
    /// - Parameters:
    ///   - source: The source path
    ///   - destination: The destination path
    ///   - relativeTo: The working directory for resolving relative paths
    /// - Throws: `FilesystemError.notSupported` by default
    public func copyItem(from source: String, to destination: String, relativeTo: String = "/") throws {
        throw FilesystemError.notSupported("copyItem")
    }
    
    /// Moves an item from source to destination (legacy API).
    /// Default implementation throws `notSupported`; VirtualFileSystem provides the full implementation.
    ///
    /// - Parameters:
    ///   - source: The source path
    ///   - destination: The destination path
    ///   - relativeTo: The working directory for resolving relative paths
    /// - Throws: `FilesystemError.notSupported` by default
    public func moveItem(from source: String, to destination: String, relativeTo: String = "/") throws {
        throw FilesystemError.notSupported("moveItem")
    }
    
    /// Creates a symbolic link (legacy API).
    /// Default implementation throws `notSupported`; VirtualFileSystem provides the full implementation.
    ///
    /// - Parameters:
    ///   - target: The target path the symlink points to
    ///   - path: The path where the symlink should be created
    ///   - relativeTo: The working directory for resolving relative paths
    /// - Throws: `FilesystemError.notSupported` by default
    public func createSymlink(_ target: String, at path: String, relativeTo: String = "/") throws {
        throw FilesystemError.notSupported("createSymlink")
    }
    
    /// Reads the target of a symbolic link (legacy API).
    /// Default implementation throws `notSupported`; VirtualFileSystem provides the full implementation.
    ///
    /// - Parameters:
    ///   - path: The path to the symlink
    ///   - relativeTo: The working directory for resolving relative paths
    /// - Returns: The target path as a String
    /// - Throws: `FilesystemError.notSupported` by default
    public func readlink(_ path: String, relativeTo: String = "/") throws -> String {
        throw FilesystemError.notSupported("readlink")
    }
    
    /// Recursively walks a directory tree and returns all paths (legacy API).
    ///
    /// - Parameters:
    ///   - path: The root path to start walking from
    ///   - relativeTo: The working directory for resolving relative paths
    /// - Returns: An array of all paths under the root
    /// - Throws: `FilesystemError` if the starting path doesn't exist
    public func walk(_ path: String, relativeTo: String = "/") throws -> [String] {
        return try walk(path: path, relativeTo: relativeTo)
    }
    
    /// Writes a String to a file with optional append mode (legacy API for VirtualFileSystem compatibility).
    /// Default implementation ignores append parameter; VirtualFileSystem provides full append support.
    ///
    /// - Parameters:
    ///   - content: The string content to write
    ///   - path: The path to the file to write
    ///   - relativeTo: The working directory for resolving relative paths
    ///   - append: If true, append to existing content instead of replacing
    /// - Throws: `FilesystemError` if the file cannot be written
    public func writeFile(_ content: String, to path: String, relativeTo: String = "/", append: Bool = false) throws {
        if append {
            // Try to read existing content and append
            let existing = (try? readFile(path: path, relativeTo: relativeTo)) ?? Data()
            let newContent = existing + Data(content.utf8)
            try writeFile(path: path, content: newContent, relativeTo: relativeTo)
        } else {
            try writeFile(path: path, content: Data(content.utf8), relativeTo: relativeTo)
        }
    }
    
    /// Performs glob pattern matching on the filesystem (legacy API).
    /// Default implementation throws `notSupported`; VirtualFileSystem provides the full implementation.
    ///
    /// - Parameters:
    ///   - pattern: The glob pattern to match
    ///   - relativeTo: The working directory for resolving relative paths
    ///   - dotglob: If true, include hidden files in matches
    ///   - extglob: If true, enable extended glob patterns
    /// - Returns: An array of matching paths
    public func glob(_ pattern: String, relativeTo: String = "/", dotglob: Bool = false, extglob: Bool = false) -> [String] {
        // Default implementation returns empty array or the pattern itself
        // VirtualFileSystem provides the actual implementation
        return [pattern]
    }
}
