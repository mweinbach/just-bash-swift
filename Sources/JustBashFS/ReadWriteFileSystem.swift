import Foundation

/// A filesystem that reads and writes directly to a real directory on disk.
///
/// Unlike `OverlayFileSystem`, this backend actually modifies files on the real
/// filesystem. Use this when you want bash scripts to have full read-write access
/// to a directory (e.g., a sandboxed documents directory on iOS).
///
/// ## Security
///
/// All operations are confined to `basePath` — path traversal above the root
/// is prevented by normalization. However, symlinks on the real filesystem
/// could escape the sandbox; consider this when choosing this backend.
///
/// ## Example
///
/// ```swift
/// let fs = ReadWriteFileSystem(base: documentsDirectory)
/// try fs.writeFile(path: "/output.txt", content: Data("hello".utf8), relativeTo: "/")
/// // File is written to \(documentsDirectory)/output.txt on disk.
/// ```
public final class ReadWriteFileSystem: @unchecked Sendable {

    /// The absolute path to the real directory that serves as the root.
    public let basePath: String

    private let fileManager = FileManager.default

    /// Creates a read-write filesystem rooted at `base`.
    ///
    /// - Parameter base: The absolute path on the real filesystem. Must be a directory.
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
}

// MARK: - BashFilesystem

extension ReadWriteFileSystem: BashFilesystem {

    public func readFile(path: String, relativeTo: String) throws -> Data {
        let normalized = VirtualPath.normalize(path, relativeTo: relativeTo)
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
        let real = realPath(for: normalized)

        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: real, isDirectory: &isDir) && isDir.boolValue {
            throw FilesystemError.isDirectory(normalized)
        }

        // Ensure parent directory exists
        let parentReal = (real as NSString).deletingLastPathComponent
        if !fileManager.fileExists(atPath: parentReal) {
            throw FilesystemError.notFound(VirtualPath.dirname(normalized))
        }

        guard fileManager.createFile(atPath: real, contents: content) else {
            throw FilesystemError.ioError("cannot write \(normalized)")
        }
    }

    public func deleteFile(path: String, relativeTo: String, recursive: Bool, force: Bool) throws {
        let normalized = VirtualPath.normalize(path, relativeTo: relativeTo)
        if normalized == "/" { throw FilesystemError.invalidPath("/") }
        let real = realPath(for: normalized)

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: real, isDirectory: &isDir) else {
            if force { return }
            throw FilesystemError.notFound(normalized)
        }

        if isDir.boolValue && !recursive {
            let contents = (try? fileManager.contentsOfDirectory(atPath: real)) ?? []
            if !contents.isEmpty {
                throw FilesystemError.directoryNotEmpty(normalized)
            }
        }

        do {
            try fileManager.removeItem(atPath: real)
        } catch {
            throw FilesystemError.ioError("cannot delete \(normalized): \(error.localizedDescription)")
        }
    }

    public func fileExists(path: String, relativeTo: String) -> Bool {
        let normalized = VirtualPath.normalize(path, relativeTo: relativeTo)
        return fileManager.fileExists(atPath: realPath(for: normalized))
    }

    public func isDirectory(path: String, relativeTo: String) -> Bool {
        let normalized = VirtualPath.normalize(path, relativeTo: relativeTo)
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: realPath(for: normalized), isDirectory: &isDir) && isDir.boolValue
    }

    public func listDirectory(path: String, relativeTo: String) throws -> [String] {
        let normalized = VirtualPath.normalize(path, relativeTo: relativeTo)
        let real = realPath(for: normalized)

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: real, isDirectory: &isDir) else {
            throw FilesystemError.notFound(normalized)
        }
        guard isDir.boolValue else {
            throw FilesystemError.notDirectory(normalized)
        }

        do {
            return try fileManager.contentsOfDirectory(atPath: real).sorted()
        } catch {
            throw FilesystemError.ioError("cannot list \(normalized): \(error.localizedDescription)")
        }
    }

    public func createDirectory(path: String, relativeTo: String, recursive: Bool) throws {
        let normalized = VirtualPath.normalize(path, relativeTo: relativeTo)
        if normalized == "/" { return }
        let real = realPath(for: normalized)

        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: real, isDirectory: &isDir) {
            if isDir.boolValue { return }
            throw FilesystemError.notDirectory(normalized)
        }

        do {
            try fileManager.createDirectory(atPath: real, withIntermediateDirectories: recursive)
        } catch {
            throw FilesystemError.ioError("cannot create directory \(normalized): \(error.localizedDescription)")
        }
    }

    public func fileInfo(path: String, relativeTo: String) throws -> FileInfo {
        let normalized = VirtualPath.normalize(path, relativeTo: relativeTo)
        let real = realPath(for: normalized)

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: real, isDirectory: &isDir) else {
            throw FilesystemError.notFound(normalized)
        }

        if isDir.boolValue {
            let count = (try? fileManager.contentsOfDirectory(atPath: real))?.count ?? 0
            return FileInfo(path: normalized, kind: .directory, size: count)
        }

        let attrs = try? fileManager.attributesOfItem(atPath: real)
        let size = (attrs?[.size] as? Int) ?? 0

        // Check if symlink
        let type = attrs?[.type] as? FileAttributeType
        let kind: FileNodeKind = type == .typeSymbolicLink ? .symlink : .file
        return FileInfo(path: normalized, kind: kind, size: size)
    }

    public func walk(path: String, relativeTo: String) throws -> [String] {
        let normalized = VirtualPath.normalize(path, relativeTo: relativeTo)
        let real = realPath(for: normalized)

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: real, isDirectory: &isDir) else {
            throw FilesystemError.notFound(normalized)
        }

        guard isDir.boolValue else { return [normalized] }

        var results = [normalized]
        let entries = (try? fileManager.contentsOfDirectory(atPath: real))?.sorted() ?? []
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
