import Foundation

/// A disk-backed filesystem prepared for coding-agent and document-style apps.
///
/// The virtual filesystem is rooted at `rootURL` on the host filesystem and is
/// seeded with a mac-like layout:
///
/// - `/Users/<username>`
/// - `~/Desktop`, `~/Documents`, `~/Downloads`, `~/Movies`, `~/Music`,
///   `~/Pictures`, `~/Public`, `~/Library`, and `~/.Trash`
/// - `/Applications`, `/Library`, `/System`, `/Volumes`, `/tmp`, `/private/tmp`,
///   `/var/tmp`, `/bin`, `/usr/bin`
///
/// Host apps can use `importItem` and `exportItem` for document-picker style
/// flows while shell commands use the same files through normal paths.
public final class UserWorkspaceFileSystem: @unchecked Sendable {
    public struct Layout: Sendable, Equatable {
        public var username: String
        public var standardDirectories: [String]
        public var rootDirectories: [String]
        public var includeWorkspaceAlias: Bool

        public init(
            username: String = "coder",
            standardDirectories: [String] = Self.defaultStandardDirectories,
            rootDirectories: [String] = Self.defaultRootDirectories,
            includeWorkspaceAlias: Bool = true
        ) {
            self.username = username
            self.standardDirectories = standardDirectories
            self.rootDirectories = rootDirectories
            self.includeWorkspaceAlias = includeWorkspaceAlias
        }

        public var homePath: String {
            "/Users/\(username)"
        }

        public static let defaultStandardDirectories = [
            "Desktop",
            "Documents",
            "Downloads",
            "Movies",
            "Music",
            "Pictures",
            "Public",
            "Library",
            ".Trash",
        ]

        public static let defaultRootDirectories = [
            "/Applications",
            "/Library",
            "/System",
            "/Users",
            "/Volumes",
            "/bin",
            "/usr",
            "/usr/bin",
            "/tmp",
            "/private",
            "/private/tmp",
            "/var",
            "/var/tmp",
        ]
    }

    public let rootURL: URL
    public let layout: Layout

    private let backend: ReadWriteFileSystem

    public init(rootURL: URL, layout: Layout = .init()) throws {
        self.rootURL = rootURL.standardizedFileURL
        self.layout = layout
        try FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        self.backend = ReadWriteFileSystem(base: self.rootURL.path)
        try seedLayout()
    }

    public var homePath: String {
        layout.homePath
    }

    public var documentsPath: String {
        "\(homePath)/Documents"
    }

    public var downloadsPath: String {
        "\(homePath)/Downloads"
    }

    public var desktopPath: String {
        "\(homePath)/Desktop"
    }

    /// Returns the host URL for a virtual path within this workspace.
    public func url(forVirtualPath path: String, relativeTo: String = "/") throws -> URL {
        try backend.url(for: path, relativeTo: relativeTo)
    }

    /// Imports a host file or directory into the virtual workspace.
    ///
    /// When `destinationPath` is nil, files are copied into `~/Downloads` and
    /// directories into `~/Documents`.
    @discardableResult
    public func importItem(
        from sourceURL: URL,
        to destinationPath: String? = nil,
        relativeTo: String = "/",
        replaceExisting: Bool = true
    ) throws -> String {
        let source = sourceURL.standardizedFileURL
        let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let baseDestination = destinationPath ?? "\(isDirectory ? documentsPath : downloadsPath)/\(source.lastPathComponent)"
        let normalizedDestination = normalizePath(baseDestination, relativeTo: relativeTo)
        let destinationURL = try url(forVirtualPath: normalizedDestination)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            if replaceExisting {
                try FileManager.default.removeItem(at: destinationURL)
            } else {
                throw FilesystemError.alreadyExists(normalizedDestination)
            }
        }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: destinationURL)
        return normalizedDestination
    }

    /// Exports a virtual file or directory to a host directory or exact URL.
    ///
    /// If `destinationURL` already exists as a directory, the exported item keeps
    /// its virtual basename inside that directory.
    @discardableResult
    public func exportItem(
        _ virtualPath: String,
        to destinationURL: URL,
        relativeTo: String = "/",
        replaceExisting: Bool = true
    ) throws -> URL {
        let normalizedSource = normalizePath(virtualPath, relativeTo: relativeTo)
        let sourceURL = try url(forVirtualPath: normalizedSource)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw FilesystemError.notFound(normalizedSource)
        }

        let destination = destinationURL.standardizedFileURL
        let destinationIsDirectory = (try? destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let finalURL = destinationIsDirectory
            ? destination.appendingPathComponent(VirtualPath.basename(normalizedSource))
            : destination

        if FileManager.default.fileExists(atPath: finalURL.path) {
            if replaceExisting {
                try FileManager.default.removeItem(at: finalURL)
            } else {
                throw FilesystemError.alreadyExists(finalURL.path)
            }
        }
        try FileManager.default.createDirectory(
            at: finalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: sourceURL, to: finalURL)
        return finalURL
    }

    private func seedLayout() throws {
        for directory in layout.rootDirectories {
            try backend.createDirectory(path: directory, relativeTo: "/", recursive: true)
        }
        try backend.createDirectory(path: homePath, relativeTo: "/", recursive: true)
        for directory in layout.standardDirectories {
            try backend.createDirectory(path: "\(homePath)/\(directory)", relativeTo: "/", recursive: true)
        }
        if layout.includeWorkspaceAlias {
            try backend.createDirectory(path: "/workspace", relativeTo: "/", recursive: true)
        }
        try backend.writeFile("Swift Virtual Kernel 1.0\n", to: "/System/version.txt")
        try backend.writeFile("", to: "\(homePath)/.bash_history")
    }
}

extension UserWorkspaceFileSystem: BashFilesystem {
    public func readFile(path: String, relativeTo: String) throws -> Data {
        try backend.readFile(path: path, relativeTo: relativeTo)
    }

    public func writeFile(path: String, content: Data, relativeTo: String) throws {
        try backend.writeFile(path: path, content: content, relativeTo: relativeTo)
    }

    public func deleteFile(path: String, relativeTo: String, recursive: Bool, force: Bool) throws {
        try backend.deleteFile(path: path, relativeTo: relativeTo, recursive: recursive, force: force)
    }

    public func fileExists(path: String, relativeTo: String) -> Bool {
        backend.fileExists(path: path, relativeTo: relativeTo)
    }

    public func isDirectory(path: String, relativeTo: String) -> Bool {
        backend.isDirectory(path: path, relativeTo: relativeTo)
    }

    public func listDirectory(path: String, relativeTo: String) throws -> [String] {
        try backend.listDirectory(path: path, relativeTo: relativeTo)
    }

    public func createDirectory(path: String, relativeTo: String, recursive: Bool) throws {
        try backend.createDirectory(path: path, relativeTo: relativeTo, recursive: recursive)
    }

    public func fileInfo(path: String, relativeTo: String) throws -> FileInfo {
        try backend.fileInfo(path: path, relativeTo: relativeTo)
    }

    public func createSymlink(_ target: String, at path: String, relativeTo: String) throws {
        try backend.createSymlink(target, at: path, relativeTo: relativeTo)
    }

    public func readlink(_ path: String, relativeTo: String) throws -> String {
        try backend.readlink(path, relativeTo: relativeTo)
    }

    public func walk(path: String, relativeTo: String) throws -> [String] {
        try backend.walk(path: path, relativeTo: relativeTo)
    }

    public func normalizePath(_ path: String, relativeTo: String) -> String {
        backend.normalizePath(path, relativeTo: relativeTo)
    }

    public func glob(_ pattern: String, relativeTo: String, dotglob: Bool, extglob: Bool) -> [String] {
        backend.glob(pattern, relativeTo: relativeTo, dotglob: dotglob, extglob: extglob)
    }
}
