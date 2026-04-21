import Foundation

/// A copy-on-write filesystem that reads from a real directory on disk
/// but keeps all writes in an in-memory layer.
///
/// This is the most important filesystem backend for iOS embedding —
/// it lets you expose an app bundle or documents directory to bash scripts
/// without allowing modifications to the underlying files.
///
/// ## Behavior
///
/// - **Reads**: Check the in-memory overlay first, then fall through to disk.
/// - **Writes**: Always go to the in-memory overlay; the real directory is never modified.
/// - **Deletes**: Record a "whiteout" in the overlay so the file appears deleted even
///   though it still exists on disk.
///
/// ## Example
///
/// ```swift
/// let fs = OverlayFileSystem(base: "/path/to/bundle/resources")
/// // Reading files that exist on disk works transparently:
/// let data = try fs.readFile(path: "/config.json", relativeTo: "/")
/// // Writes are captured in memory:
/// try fs.writeFile(path: "/config.json", content: Data("{}".utf8), relativeTo: "/")
/// // The original file on disk is untouched.
/// ```
public final class OverlayFileSystem: @unchecked Sendable {

    /// The absolute path to the real directory that serves as the read-only base.
    public let basePath: String

    /// In-memory overlay keyed by normalized virtual path.
    private var overlay: [String: OverlayEntry] = [:]

    private let fileManager = FileManager.default

    private enum OverlayEntry {
        /// A file or directory that exists only in the overlay.
        case file(Data)
        case directory
        /// A symlink stored in the overlay.
        case symlink(String)
        /// A whiteout — the path has been deleted in the overlay and should not
        /// fall through to the base even if it exists on disk.
        case whiteout

        var isDirectory: Bool {
            if case .directory = self { return true }
            return false
        }

        var isWhiteout: Bool {
            if case .whiteout = self { return true }
            return false
        }
    }

    /// Creates an overlay filesystem rooted at `base`.
    ///
    /// - Parameter base: The absolute path on the real filesystem to use as
    ///   the read-only base layer. Must be a directory.
    public init(base: String) {
        self.basePath = (base as NSString).standardizingPath
    }

    // MARK: - Helpers

    /// Maps a virtual path to the real path on disk.
    private func realPath(for virtualPath: String) -> String {
        let normalized = VirtualPath.normalize(virtualPath, relativeTo: "/")
        if normalized == "/" { return basePath }
        return (basePath as NSString).appendingPathComponent(String(normalized.dropFirst()))
    }

    /// Whether the overlay has a whiteout (deletion marker) at this path or any ancestor.
    private func isWhitedOut(_ path: String) -> Bool {
        let normalized = VirtualPath.normalize(path, relativeTo: "/")
        // Check exact path
        if case .whiteout = overlay[normalized] { return true }
        // Check ancestors
        let components = VirtualPath.components(for: normalized)
        var current = ""
        for component in components {
            current = current.isEmpty ? "/\(component)" : "\(current)/\(component)"
            if case .whiteout = overlay[current] { return true }
        }
        return false
    }

    /// Whether a file or directory exists on the real filesystem at this virtual path.
    private func existsOnDisk(_ virtualPath: String) -> Bool {
        let real = realPath(for: virtualPath)
        return fileManager.fileExists(atPath: real)
    }

    private func isDirectoryOnDisk(_ virtualPath: String) -> Bool {
        let real = realPath(for: virtualPath)
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: real, isDirectory: &isDir) && isDir.boolValue
    }
}

// MARK: - BashFilesystem

extension OverlayFileSystem: BashFilesystem {

    public func readFile(path: String, relativeTo: String) throws -> Data {
        let normalized = VirtualPath.normalize(path, relativeTo: relativeTo)

        // Check whiteout first
        if isWhitedOut(normalized) {
            throw FilesystemError.notFound(normalized)
        }

        // Check overlay
        if let entry = overlay[normalized] {
            switch entry {
            case .file(let data): return data
            case .directory: throw FilesystemError.isDirectory(normalized)
            case .symlink(let target): return try readFile(path: target, relativeTo: VirtualPath.dirname(normalized))
            case .whiteout: throw FilesystemError.notFound(normalized)
            }
        }

        // Fall through to disk
        let real = realPath(for: normalized)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: real, isDirectory: &isDir) else {
            throw FilesystemError.notFound(normalized)
        }
        if isDir.boolValue {
            throw FilesystemError.isDirectory(normalized)
        }
        guard let data = fileManager.contents(atPath: real) else {
            throw FilesystemError.ioError("cannot read \(normalized)")
        }
        return data
    }

    public func writeFile(path: String, content: Data, relativeTo: String) throws {
        let normalized = VirtualPath.normalize(path, relativeTo: relativeTo)

        // Ensure parent exists (either on disk or in overlay)
        let parent = VirtualPath.dirname(normalized)
        if parent != "/" && !isDirectory(path: parent, relativeTo: "/") {
            throw FilesystemError.notFound(parent)
        }

        // Check if target is a directory
        if let entry = overlay[normalized] {
            if case .directory = entry { throw FilesystemError.isDirectory(normalized) }
        } else if !isWhitedOut(normalized) && isDirectoryOnDisk(normalized) {
            throw FilesystemError.isDirectory(normalized)
        }

        overlay[normalized] = .file(content)
    }

    public func deleteFile(path: String, relativeTo: String, recursive: Bool, force: Bool) throws {
        let normalized = VirtualPath.normalize(path, relativeTo: relativeTo)
        if normalized == "/" { throw FilesystemError.invalidPath("/") }

        let existsInOverlay = overlay[normalized] != nil
        let existsReal = !isWhitedOut(normalized) && existsOnDisk(normalized)

        guard existsInOverlay || existsReal else {
            if force { return }
            throw FilesystemError.notFound(normalized)
        }

        if !recursive {
            // Check if it's a non-empty directory
            let isDir: Bool
            if let entry = overlay[normalized] {
                isDir = entry.isDirectory
            } else {
                isDir = isDirectoryOnDisk(normalized)
            }
            if isDir {
                let entries = (try? listDirectory(path: normalized, relativeTo: "/")) ?? []
                if !entries.isEmpty {
                    throw FilesystemError.directoryNotEmpty(normalized)
                }
            }
        }

        // Remove any overlay entries under this path (for recursive)
        if recursive {
            let prefix = normalized == "/" ? "/" : normalized + "/"
            for key in overlay.keys where key.hasPrefix(prefix) {
                overlay[key] = .whiteout
            }
        }

        // Place a whiteout to hide the disk version
        overlay[normalized] = .whiteout
    }

    public func fileExists(path: String, relativeTo: String) -> Bool {
        let normalized = VirtualPath.normalize(path, relativeTo: relativeTo)

        if isWhitedOut(normalized) { return false }

        if let entry = overlay[normalized] {
            return !entry.isWhiteout
        }

        return existsOnDisk(normalized)
    }

    public func isDirectory(path: String, relativeTo: String) -> Bool {
        let normalized = VirtualPath.normalize(path, relativeTo: relativeTo)

        if isWhitedOut(normalized) { return false }

        if let entry = overlay[normalized] {
            return entry.isDirectory
        }

        return isDirectoryOnDisk(normalized)
    }

    public func listDirectory(path: String, relativeTo: String) throws -> [String] {
        let normalized = VirtualPath.normalize(path, relativeTo: relativeTo)

        if isWhitedOut(normalized) {
            throw FilesystemError.notFound(normalized)
        }

        var entries = Set<String>()

        // Collect from disk
        let real = realPath(for: normalized)
        if let diskEntries = try? fileManager.contentsOfDirectory(atPath: real) {
            for name in diskEntries {
                let childPath = normalized == "/" ? "/\(name)" : "\(normalized)/\(name)"
                if !isWhitedOut(childPath) {
                    entries.insert(name)
                }
            }
        }

        // Collect from overlay — add entries that are under this directory
        let prefix = normalized == "/" ? "/" : normalized + "/"
        for (key, entry) in overlay {
            guard !entry.isWhiteout else { continue }
            // Direct child: strip the prefix and check there's no further "/"
            if key.hasPrefix(prefix) {
                let remainder = String(key.dropFirst(prefix.count))
                if !remainder.contains("/") && !remainder.isEmpty {
                    entries.insert(remainder)
                }
            }
        }

        // If nothing found, check that the path actually is a directory
        if entries.isEmpty {
            if let entry = overlay[normalized] {
                guard entry.isDirectory else {
                    throw FilesystemError.notDirectory(normalized)
                }
            } else {
                guard isDirectoryOnDisk(normalized) else {
                    if existsOnDisk(normalized) {
                        throw FilesystemError.notDirectory(normalized)
                    }
                    throw FilesystemError.notFound(normalized)
                }
            }
        }

        return entries.sorted()
    }

    public func createDirectory(path: String, relativeTo: String, recursive: Bool) throws {
        let normalized = VirtualPath.normalize(path, relativeTo: relativeTo)
        if normalized == "/" { return }

        // Already exists as directory
        if isDirectory(path: normalized, relativeTo: "/") { return }

        // Check if exists as file
        if fileExists(path: normalized, relativeTo: "/") {
            throw FilesystemError.notDirectory(normalized)
        }

        if recursive {
            let components = VirtualPath.components(for: normalized)
            var current = ""
            for component in components {
                current = current.isEmpty ? "/\(component)" : "\(current)/\(component)"
                if !isDirectory(path: current, relativeTo: "/") {
                    overlay[current] = .directory
                }
            }
        } else {
            let parent = VirtualPath.dirname(normalized)
            guard isDirectory(path: parent, relativeTo: "/") else {
                throw FilesystemError.notFound(parent)
            }
            overlay[normalized] = .directory
        }
    }

    public func fileInfo(path: String, relativeTo: String) throws -> FileInfo {
        let normalized = VirtualPath.normalize(path, relativeTo: relativeTo)

        if isWhitedOut(normalized) {
            throw FilesystemError.notFound(normalized)
        }

        if let entry = overlay[normalized] {
            switch entry {
            case .file(let data):
                return FileInfo(path: normalized, kind: .file, size: data.count)
            case .directory:
                let count = (try? listDirectory(path: normalized, relativeTo: "/"))?.count ?? 0
                return FileInfo(path: normalized, kind: .directory, size: count)
            case .symlink(let target):
                return FileInfo(path: normalized, kind: .symlink, size: target.utf8.count)
            case .whiteout:
                throw FilesystemError.notFound(normalized)
            }
        }

        // Fall through to disk
        let real = realPath(for: normalized)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: real, isDirectory: &isDir) else {
            throw FilesystemError.notFound(normalized)
        }

        if isDir.boolValue {
            let count = (try? fileManager.contentsOfDirectory(atPath: real))?.count ?? 0
            return FileInfo(path: normalized, kind: .directory, size: count)
        } else {
            let attrs = try? fileManager.attributesOfItem(atPath: real)
            let size = (attrs?[.size] as? Int) ?? 0
            return FileInfo(path: normalized, kind: .file, size: size)
        }
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
        // Delegate to VirtualFileSystem's static glob matching but walk our own tree
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

