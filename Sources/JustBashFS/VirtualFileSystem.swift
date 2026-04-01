import Foundation

public enum VirtualPath {
    public static func normalize(_ path: String, relativeTo cwd: String = "/") -> String {
        let base: String
        if path.hasPrefix("/") {
            base = path
        } else {
            let normalizedCwd = normalizeAbsolute(cwd)
            base = normalizedCwd == "/" ? "/\(path)" : "\(normalizedCwd)/\(path)"
        }
        return normalizeAbsolute(base)
    }

    public static func basename(_ path: String) -> String {
        let normalized = normalizeAbsolute(path)
        if normalized == "/" { return "/" }
        return normalized.split(separator: "/").last.map(String.init) ?? "/"
    }

    public static func dirname(_ path: String) -> String {
        let normalized = normalizeAbsolute(path)
        if normalized == "/" { return "/" }
        var components = self.components(for: normalized)
        _ = components.popLast()
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    public static func components(for path: String) -> [String] {
        normalizeAbsolute(path).split(separator: "/").map(String.init)
    }

    private static func normalizeAbsolute(_ path: String) -> String {
        var result: [String] = []
        for raw in path.split(separator: "/", omittingEmptySubsequences: false) {
            let part = String(raw)
            if part.isEmpty || part == "." { continue }
            if part == ".." {
                if !result.isEmpty {
                    _ = result.popLast()
                }
                continue
            }
            result.append(part)
        }
        return "/" + result.joined(separator: "/")
    }
}

public struct VirtualProcessInfo: Sendable, Equatable {
    public var pid: Int
    public var ppid: Int
    public var uid: Int
    public var gid: Int

    public init(pid: Int = 1, ppid: Int = 0, uid: Int = 1000, gid: Int = 1000) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.gid = gid
    }
}

public enum VirtualNodeKind: String, Sendable {
    case file
    case directory
    case symlink
}

public struct VirtualDirectoryEntry: Sendable, Equatable {
    public let name: String
    public let path: String
    public let kind: VirtualNodeKind

    public init(name: String, path: String, kind: VirtualNodeKind) {
        self.name = name
        self.path = path
        self.kind = kind
    }

    public var isDirectory: Bool { kind == .directory }
}

public struct VirtualFileInfo: Sendable, Equatable {
    public let path: String
    public let kind: VirtualNodeKind
    public let size: Int

    public init(path: String, kind: VirtualNodeKind, size: Int) {
        self.path = path
        self.kind = kind
        self.size = size
    }
}

public enum VirtualFileSystemError: Error, LocalizedError, Equatable {
    case invalidPath(String)
    case notFound(String)
    case notDirectory(String)
    case isDirectory(String)
    case alreadyExists(String)
    case directoryNotEmpty(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path): return "invalid path: \(path)"
        case .notFound(let path): return "no such file or directory: \(path)"
        case .notDirectory(let path): return "not a directory: \(path)"
        case .isDirectory(let path): return "is a directory: \(path)"
        case .alreadyExists(let path): return "file exists: \(path)"
        case .directoryNotEmpty(let path): return "directory not empty: \(path)"
        }
    }
}

public final class VirtualFileSystem: @unchecked Sendable {
    private final class Node {
        let kind: VirtualNodeKind
        var content: String
        var children: [String: Node]
        var symlinkTarget: String?

        init(kind: VirtualNodeKind, content: String = "", children: [String: Node] = [:], symlinkTarget: String? = nil) {
            self.kind = kind
            self.content = content
            self.children = children
            self.symlinkTarget = symlinkTarget
        }

        func deepCopy() -> Node {
            let copy = Node(kind: kind, content: content, symlinkTarget: symlinkTarget)
            copy.children = children.mapValues { $0.deepCopy() }
            return copy
        }
    }

    private let root = Node(kind: .directory)

    public init(initialFiles: [String: String] = [:], processInfo: VirtualProcessInfo = .init()) {
        seedDefaultLayout(processInfo: processInfo)
        for (path, content) in initialFiles {
            try? writeFile(content, to: path)
        }
    }

    public func exists(_ path: String, relativeTo cwd: String = "/") -> Bool {
        let normalized = VirtualPath.normalize(path, relativeTo: cwd)
        return (try? node(at: normalized)) != nil
    }

    public func isDirectory(_ path: String, relativeTo cwd: String = "/") -> Bool {
        let normalized = VirtualPath.normalize(path, relativeTo: cwd)
        guard let node = try? node(at: normalized) else { return false }
        return node.kind == .directory
    }

    public func fileInfo(_ path: String, relativeTo cwd: String = "/") throws -> VirtualFileInfo {
        let normalized = VirtualPath.normalize(path, relativeTo: cwd)
        let node = try node(at: normalized)
        let size: Int
        switch node.kind {
        case .file: size = node.content.utf8.count
        case .directory: size = node.children.count
        case .symlink: size = node.symlinkTarget?.utf8.count ?? 0
        }
        return VirtualFileInfo(path: normalized, kind: node.kind, size: size)
    }

    public func createDirectory(_ path: String, relativeTo cwd: String = "/", recursive: Bool = false) throws {
        let normalized = VirtualPath.normalize(path, relativeTo: cwd)
        if normalized == "/" { return }
        var current = root
        let components = VirtualPath.components(for: normalized)
        for (index, component) in components.enumerated() {
            if let existing = current.children[component] {
                guard existing.kind == .directory else {
                    throw VirtualFileSystemError.notDirectory(normalized)
                }
                current = existing
                continue
            }
            if !recursive && index != components.count - 1 {
                throw VirtualFileSystemError.notFound(VirtualPath.dirname(normalized))
            }
            let next = Node(kind: .directory)
            current.children[component] = next
            current = next
        }
    }

    public func listDirectory(_ path: String, relativeTo cwd: String = "/", includeHidden: Bool = false) throws -> [VirtualDirectoryEntry] {
        let normalized = VirtualPath.normalize(path, relativeTo: cwd)
        let directory = try node(at: normalized)
        guard directory.kind == .directory else {
            throw VirtualFileSystemError.notDirectory(normalized)
        }
        return directory.children.keys.sorted().compactMap { name in
            guard includeHidden || !name.hasPrefix(".") else { return nil }
            let childPath = normalized == "/" ? "/\(name)" : "\(normalized)/\(name)"
            let kind = directory.children[name]?.kind ?? .file
            return VirtualDirectoryEntry(name: name, path: childPath, kind: kind)
        }
    }

    public func readFile(_ path: String, relativeTo cwd: String = "/") throws -> String {
        let normalized = VirtualPath.normalize(path, relativeTo: cwd)
        let node = try node(at: normalized)
        switch node.kind {
        case .file:
            return node.content
        case .directory:
            throw VirtualFileSystemError.isDirectory(normalized)
        case .symlink:
            if let target = node.symlinkTarget {
                return try readFile(target, relativeTo: "/")
            }
            throw VirtualFileSystemError.notFound(normalized)
        }
    }

    public func writeFile(_ content: String, to path: String, relativeTo cwd: String = "/", append: Bool = false) throws {
        let normalized = VirtualPath.normalize(path, relativeTo: cwd)
        let (parent, name) = try parentNodeAndName(for: normalized)
        if let existing = parent.children[name] {
            guard existing.kind == .file else {
                throw VirtualFileSystemError.isDirectory(normalized)
            }
            existing.content = append ? existing.content + content : content
            return
        }
        parent.children[name] = Node(kind: .file, content: content)
    }

    public func removeItem(_ path: String, relativeTo cwd: String = "/", recursive: Bool = false, force: Bool = false) throws {
        let normalized = VirtualPath.normalize(path, relativeTo: cwd)
        if normalized == "/" { throw VirtualFileSystemError.invalidPath(normalized) }
        let (parent, name) = try parentNodeAndName(for: normalized)
        guard let node = parent.children[name] else {
            if force { return }
            throw VirtualFileSystemError.notFound(normalized)
        }
        if node.kind == .directory && !recursive && !node.children.isEmpty {
            throw VirtualFileSystemError.directoryNotEmpty(normalized)
        }
        parent.children.removeValue(forKey: name)
    }

    public func copyItem(from source: String, to destination: String, relativeTo cwd: String = "/") throws {
        let sourcePath = VirtualPath.normalize(source, relativeTo: cwd)
        let destinationPath = VirtualPath.normalize(destination, relativeTo: cwd)
        let sourceNode = try node(at: sourcePath)
        let (parent, name) = try parentNodeAndName(for: destinationPath)
        parent.children[name] = sourceNode.deepCopy()
    }

    public func moveItem(from source: String, to destination: String, relativeTo cwd: String = "/") throws {
        try copyItem(from: source, to: destination, relativeTo: cwd)
        try removeItem(source, relativeTo: cwd, recursive: true)
    }

    public func createSymlink(_ target: String, at path: String, relativeTo cwd: String = "/") throws {
        let normalized = VirtualPath.normalize(path, relativeTo: cwd)
        let (parent, name) = try parentNodeAndName(for: normalized)
        parent.children[name] = Node(kind: .symlink, symlinkTarget: target)
    }

    public func readlink(_ path: String, relativeTo cwd: String = "/") throws -> String {
        let normalized = VirtualPath.normalize(path, relativeTo: cwd)
        let node = try node(at: normalized)
        guard node.kind == .symlink, let target = node.symlinkTarget else {
            throw VirtualFileSystemError.invalidPath(normalized)
        }
        return target
    }

    public func walk(_ path: String = "/", relativeTo cwd: String = "/") throws -> [String] {
        let normalized = VirtualPath.normalize(path, relativeTo: cwd)
        let start = try node(at: normalized)
        var results = [normalized]
        if start.kind == .directory {
            for name in start.children.keys.sorted() {
                let childPath = normalized == "/" ? "/\(name)" : "\(normalized)/\(name)"
                results.append(contentsOf: try walk(childPath, relativeTo: "/"))
            }
        }
        return results
    }

    public func glob(_ pattern: String, relativeTo cwd: String = "/") -> [String] {
        let isAbsolute = pattern.hasPrefix("/")
        let baseComponents = isAbsolute ? [] : VirtualPath.components(for: cwd)
        let patternComponents = pattern.split(separator: "/").map(String.init)
        let searchComponents = baseComponents + patternComponents
        var results: [String] = []

        func descend(node: Node, remaining: ArraySlice<String>, built: [String]) {
            guard let segment = remaining.first else {
                let path = built.isEmpty ? "/" : "/" + built.joined(separator: "/")
                results.append(path)
                return
            }
            if segment.isEmpty || segment == "." {
                descend(node: node, remaining: remaining.dropFirst(), built: built)
                return
            }
            if segment == ".." {
                descend(node: root, remaining: remaining.dropFirst(), built: [])
                return
            }
            if !segment.contains("*") && !segment.contains("?") && !segment.contains("[") {
                guard let child = node.children[segment] else { return }
                descend(node: child, remaining: remaining.dropFirst(), built: built + [segment])
                return
            }
            for name in node.children.keys.sorted() {
                if !segment.hasPrefix(".") && name.hasPrefix(".") { continue }
                if Self.globMatch(name: name, pattern: segment), let child = node.children[name] {
                    descend(node: child, remaining: remaining.dropFirst(), built: built + [name])
                }
            }
        }

        descend(node: root, remaining: ArraySlice(searchComponents), built: [])
        return Array(Set(results)).sorted()
    }

    public func seedCommandStub(named name: String) {
        let stub = "#!/virtual/bin/bash\n# built-in command: \(name)\n"
        try? writeFile(stub, to: "/bin/\(name)")
        try? writeFile(stub, to: "/usr/bin/\(name)")
    }

    public static func globMatch(name: String, pattern: String) -> Bool {
        let chars = Array(pattern)
        var regex = "^"
        var index = 0

        while index < chars.count {
            let character = chars[index]
            switch character {
            case "*":
                regex += ".*"
                index += 1
            case "?":
                regex += "."
                index += 1
            case "[":
                if let endIndex = chars[index...].firstIndex(of: "]") {
                    regex += String(chars[index...endIndex])
                    index = endIndex + 1
                } else {
                    regex += "\\["
                    index += 1
                }
            default:
                regex += escapeRegex(character)
                index += 1
            }
        }

        regex += "$"

        guard let expression = try? NSRegularExpression(pattern: regex) else {
            return false
        }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        return expression.firstMatch(in: name, options: [], range: range) != nil
    }

    private static func escapeRegex(_ character: Character) -> String {
        let regexMeta = "\\.^$+(){}|"
        if regexMeta.contains(character) {
            return "\\\(character)"
        }
        return String(character)
    }

    private func seedDefaultLayout(processInfo: VirtualProcessInfo) {
        ["/bin", "/usr", "/usr/bin", "/tmp", "/home", "/home/user", "/dev", "/proc", "/proc/self", "/proc/self/fd"].forEach {
            try? createDirectory($0, recursive: true)
        }
        try? writeFile("", to: "/dev/null")
        try? writeFile("", to: "/dev/stdin")
        try? writeFile("", to: "/dev/stdout")
        try? writeFile("", to: "/dev/stderr")
        try? writeFile("Swift Virtual Kernel 1.0\n", to: "/proc/version")
        try? writeFile("/bin/bash\n", to: "/proc/self/exe")
        try? writeFile("bash\0", to: "/proc/self/cmdline")
        try? writeFile("bash\n", to: "/proc/self/comm")
        let status = [
            "Name:\tbash",
            "Pid:\t\(processInfo.pid)",
            "PPid:\t\(processInfo.ppid)",
            "Uid:\t\(processInfo.uid)\t\(processInfo.uid)\t\(processInfo.uid)\t\(processInfo.uid)",
            "Gid:\t\(processInfo.gid)\t\(processInfo.gid)\t\(processInfo.gid)\t\(processInfo.gid)",
        ].joined(separator: "\n") + "\n"
        try? writeFile(status, to: "/proc/self/status")
        try? writeFile("/dev/stdin\n", to: "/proc/self/fd/0")
        try? writeFile("/dev/stdout\n", to: "/proc/self/fd/1")
        try? writeFile("/dev/stderr\n", to: "/proc/self/fd/2")
    }

    private func node(at path: String) throws -> Node {
        if path == "/" { return root }
        var current = root
        for component in VirtualPath.components(for: path) {
            guard let child = current.children[component] else {
                throw VirtualFileSystemError.notFound(path)
            }
            current = child
        }
        return current
    }

    private func parentNodeAndName(for path: String) throws -> (Node, String) {
        let parentPath = VirtualPath.dirname(path)
        let name = VirtualPath.basename(path)
        let parent = try node(at: parentPath)
        guard parent.kind == .directory else {
            throw VirtualFileSystemError.notDirectory(parentPath)
        }
        return (parent, name)
    }
}
