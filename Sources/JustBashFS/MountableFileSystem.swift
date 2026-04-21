import Foundation

/// A filesystem that mounts different `BashFilesystem` implementations at
/// different virtual paths, routing each operation to the correct backend.
///
/// This is useful for composing filesystems — for example, mounting a
/// read-only app bundle at `/app`, a writable documents directory at `/data`,
/// and a pure in-memory scratch area at `/tmp`.
///
/// ## Mount Resolution
///
/// Operations are routed to the mount with the longest matching path prefix.
/// If no mount matches, the operation falls through to the root filesystem.
///
/// ## Example
///
/// ```swift
/// let mem = VirtualFileSystem()
/// let bundle = OverlayFileSystem(base: Bundle.main.resourcePath!)
/// let docs = ReadWriteFileSystem(base: docsDir)
///
/// let fs = MountableFileSystem(root: mem)
/// fs.mount(bundle, at: "/app")
/// fs.mount(docs, at: "/data")
///
/// // Reads from the bundle overlay:
/// let cfg = try fs.readFile(path: "/app/config.json", relativeTo: "/")
/// // Writes to the documents directory:
/// try fs.writeFile(path: "/data/output.txt", content: Data("hi".utf8), relativeTo: "/")
/// // Everything else goes to the in-memory VFS:
/// try fs.writeFile(path: "/tmp/scratch", content: Data("x".utf8), relativeTo: "/")
/// ```
public final class MountableFileSystem: @unchecked Sendable {

    /// A mount entry: a filesystem bound to a virtual path prefix.
    private struct Mount {
        let path: String            // Normalized mount point, e.g. "/app"
        let filesystem: any BashFilesystem
    }

    /// The root filesystem that handles paths not covered by any mount.
    private let root: any BashFilesystem

    /// Mounts sorted by path length descending so longest-prefix wins.
    private var mounts: [Mount] = []

    /// Creates a mountable filesystem with the given root backend.
    ///
    /// - Parameter root: The filesystem that handles any path not covered by a mount.
    public init(root: any BashFilesystem) {
        self.root = root
    }

    /// Mounts a filesystem at a virtual path.
    ///
    /// - Parameters:
    ///   - filesystem: The filesystem to mount.
    ///   - path: The virtual path prefix (e.g. "/app"). Must start with "/".
    public func mount(_ filesystem: any BashFilesystem, at path: String) {
        let normalized = VirtualPath.normalize(path, relativeTo: "/")
        // Remove existing mount at same path
        mounts.removeAll { $0.path == normalized }
        mounts.append(Mount(path: normalized, filesystem: filesystem))
        // Keep sorted by path length descending for longest-prefix matching
        mounts.sort { $0.path.count > $1.path.count }
    }

    /// Unmounts the filesystem at the given path.
    ///
    /// - Parameter path: The mount point to remove.
    public func unmount(at path: String) {
        let normalized = VirtualPath.normalize(path, relativeTo: "/")
        mounts.removeAll { $0.path == normalized }
    }

    /// Returns the list of current mount points.
    public var mountPoints: [String] {
        mounts.map(\.path)
    }

    // MARK: - Routing

    /// Finds the filesystem and translated path for a given virtual path.
    private func resolve(_ virtualPath: String) -> (any BashFilesystem, String) {
        let normalized = VirtualPath.normalize(virtualPath, relativeTo: "/")

        for mount in mounts {
            if normalized == mount.path {
                return (mount.filesystem, "/")
            }
            let prefix = mount.path == "/" ? "/" : mount.path + "/"
            if normalized.hasPrefix(prefix) {
                let relative = "/" + String(normalized.dropFirst(prefix.count))
                return (mount.filesystem, relative)
            }
        }

        return (root, normalized)
    }

    /// Resolves a path given a relativeTo context.
    private func resolveWithBase(path: String, relativeTo: String) -> (any BashFilesystem, String) {
        let normalized = VirtualPath.normalize(path, relativeTo: relativeTo)
        return resolve(normalized)
    }
}

// MARK: - BashFilesystem

extension MountableFileSystem: BashFilesystem {

    public func readFile(path: String, relativeTo: String) throws -> Data {
        let (fs, resolved) = resolveWithBase(path: path, relativeTo: relativeTo)
        return try fs.readFile(path: resolved, relativeTo: "/")
    }

    public func writeFile(path: String, content: Data, relativeTo: String) throws {
        let (fs, resolved) = resolveWithBase(path: path, relativeTo: relativeTo)
        try fs.writeFile(path: resolved, content: content, relativeTo: "/")
    }

    public func deleteFile(path: String, relativeTo: String, recursive: Bool, force: Bool) throws {
        let (fs, resolved) = resolveWithBase(path: path, relativeTo: relativeTo)
        try fs.deleteFile(path: resolved, relativeTo: "/", recursive: recursive, force: force)
    }

    public func fileExists(path: String, relativeTo: String) -> Bool {
        let normalized = VirtualPath.normalize(path, relativeTo: relativeTo)

        // A mount point itself always "exists" as a directory
        if mounts.contains(where: { $0.path == normalized }) { return true }

        let (fs, resolved) = resolve(normalized)
        return fs.fileExists(path: resolved, relativeTo: "/")
    }

    public func isDirectory(path: String, relativeTo: String) -> Bool {
        let normalized = VirtualPath.normalize(path, relativeTo: relativeTo)

        // A mount point is always a directory
        if mounts.contains(where: { $0.path == normalized }) { return true }

        let (fs, resolved) = resolve(normalized)
        return fs.isDirectory(path: resolved, relativeTo: "/")
    }

    public func listDirectory(path: String, relativeTo: String) throws -> [String] {
        let normalized = VirtualPath.normalize(path, relativeTo: relativeTo)
        let (fs, resolved) = resolve(normalized)

        var entries = Set<String>()

        // Get entries from the resolved filesystem
        if let fsEntries = try? fs.listDirectory(path: resolved, relativeTo: "/") {
            for name in fsEntries {
                entries.insert(name)
            }
        }

        // Also include mount points that are direct children of this directory
        let prefix = normalized == "/" ? "/" : normalized + "/"
        for mount in mounts {
            if mount.path.hasPrefix(prefix) {
                let remainder = String(mount.path.dropFirst(prefix.count))
                if !remainder.contains("/") && !remainder.isEmpty {
                    entries.insert(remainder)
                }
            }
        }

        if entries.isEmpty {
            // Verify the directory exists
            if !fs.isDirectory(path: resolved, relativeTo: "/") {
                if fs.fileExists(path: resolved, relativeTo: "/") {
                    throw FilesystemError.notDirectory(normalized)
                }
                throw FilesystemError.notFound(normalized)
            }
        }

        return entries.sorted()
    }

    public func createDirectory(path: String, relativeTo: String, recursive: Bool) throws {
        let (fs, resolved) = resolveWithBase(path: path, relativeTo: relativeTo)
        try fs.createDirectory(path: resolved, relativeTo: "/", recursive: recursive)
    }

    public func fileInfo(path: String, relativeTo: String) throws -> FileInfo {
        let normalized = VirtualPath.normalize(path, relativeTo: relativeTo)

        // Mount points appear as directories
        if let _ = mounts.first(where: { $0.path == normalized }) {
            let count = (try? listDirectory(path: normalized, relativeTo: "/"))?.count ?? 0
            return FileInfo(path: normalized, kind: .directory, size: count)
        }

        let (fs, resolved) = resolve(normalized)
        let info = try fs.fileInfo(path: resolved, relativeTo: "/")
        // Remap the path back to the virtual namespace
        return FileInfo(path: normalized, kind: info.kind, size: info.size)
    }

    public func walk(path: String, relativeTo: String) throws -> [String] {
        let normalized = VirtualPath.normalize(path, relativeTo: relativeTo)

        guard fileExists(path: normalized, relativeTo: "/") else {
            throw FilesystemError.notFound(normalized)
        }

        guard isDirectory(path: normalized, relativeTo: "/") else {
            return [normalized]
        }

        var results = [normalized]
        let entries = (try? listDirectory(path: normalized, relativeTo: "/")) ?? []
        for name in entries {
            let childPath = normalized == "/" ? "/\(name)" : "\(normalized)/\(name)"
            results.append(contentsOf: try walk(path: childPath, relativeTo: "/"))
        }
        return results
    }

    public func normalizePath(_ path: String, relativeTo: String) -> String {
        VirtualPath.normalize(path, relativeTo: relativeTo)
    }

    public func glob(_ pattern: String, relativeTo: String, dotglob: Bool, extglob: Bool) -> [String] {
        let isAbsolute = pattern.hasPrefix("/")
        let cwd = isAbsolute ? "/" : relativeTo
        let baseComponents = isAbsolute ? [String]() : VirtualPath.components(for: cwd)
        let patternComponents = pattern.split(separator: "/").map(String.init)
        let searchComponents = baseComponents + patternComponents
        var results: [String] = []

        func descend(path: String, remaining: ArraySlice<String>) {
            guard let segment = remaining.first else {
                if fileExists(path: path, relativeTo: "/") {
                    results.append(path)
                }
                return
            }

            guard isDirectory(path: path, relativeTo: "/") else { return }

            if !segment.contains("*") && !segment.contains("?") && !segment.contains("[") {
                let childPath = path == "/" ? "/\(segment)" : "\(path)/\(segment)"
                descend(path: childPath, remaining: remaining.dropFirst())
                return
            }

            guard let entries = try? listDirectory(path: path, relativeTo: "/") else { return }
            for name in entries {
                if !dotglob && !segment.hasPrefix(".") && name.hasPrefix(".") { continue }
                if VirtualFileSystem.globMatch(name: name, pattern: segment, extglob: extglob) {
                    let childPath = path == "/" ? "/\(name)" : "\(path)/\(name)"
                    descend(path: childPath, remaining: remaining.dropFirst())
                }
            }
        }

        let startPath = isAbsolute ? "/" : VirtualPath.normalize(cwd, relativeTo: "/")
        descend(path: startPath, remaining: ArraySlice(searchComponents))
        return Array(Set(results)).sorted()
    }
}
