import Foundation
import JustBashFS

func tar() -> AnyBashCommand {
    AnyBashCommand(name: "tar") { args, ctx in
        var mode: Character?
        var archivePath: String?
        var verbose = false
        var gzipMode = false
        var changeDir: String?
        var stripComponents = 0
        var paths: [String] = []
        var index = 0

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--help":
                return ExecResult.success(tarHelpText())
            case "-f":
                index += 1
                if index >= args.count { return ExecResult.failure("tar: option requires an argument -- f", exitCode: 2) }
                archivePath = args[index]
            case "-C":
                index += 1
                if index >= args.count { return ExecResult.failure("tar: option requires an argument -- C", exitCode: 2) }
                changeDir = args[index]
            case let option where option.hasPrefix("--strip-components="):
                stripComponents = Int(option.split(separator: "=").last ?? "") ?? 0
            case let option where option.hasPrefix("--strip="):
                stripComponents = Int(option.split(separator: "=").last ?? "") ?? 0
            case let option where option.hasPrefix("-"):
                let chars = Array(option.dropFirst())
                var shortIndex = 0
                while shortIndex < chars.count {
                    let ch = chars[shortIndex]
                    switch ch {
                    case "c", "t", "x":
                        if mode != nil, mode != ch {
                            return ExecResult.failure("tar: You may not specify more than one operation mode", exitCode: 2)
                        }
                        mode = ch
                    case "v":
                        verbose = true
                    case "z":
                        gzipMode = true
                    case "f":
                        if shortIndex + 1 < chars.count {
                            archivePath = String(chars[(shortIndex + 1)...])
                            shortIndex = chars.count
                            continue
                        }
                        index += 1
                        if index >= args.count {
                            return ExecResult.failure("tar: option requires an argument -- f", exitCode: 2)
                        }
                        archivePath = args[index]
                    default:
                        break
                    }
                    shortIndex += 1
                }
            default:
                paths.append(arg)
            }
            index += 1
        }

        guard let mode else {
            return ExecResult.failure("tar: You must specify one of -c, -r, -u, -x, or -t", exitCode: 2)
        }
        guard let archivePath else {
            return ExecResult.failure("tar: option requires an argument -- f", exitCode: 2)
        }

        do {
            switch mode {
            case "c":
                guard !paths.isEmpty else {
                    return ExecResult.failure("tar: Cowardly refusing to create an empty archive", exitCode: 2)
                }
                let entries = try buildTarEntries(paths: paths, changeDir: changeDir, ctx: ctx)
                var data = buildTarArchive(entries)
                if gzipMode {
                    data = try gzipData(data)
                }
                try ctx.fileSystem.writeFile(stringFromVirtualData(data, preferUTF8: false), to: archivePath, relativeTo: ctx.cwd)
                let stderr = verbose ? entries.map(\.name).joined(separator: "\n") + (entries.isEmpty ? "" : "\n") : ""
                return ExecResult(stdout: "", stderr: stderr, exitCode: 0)
            case "t":
                let data = try loadTarArchiveData(path: archivePath, relativeTo: ctx.cwd, fileSystem: ctx.fileSystem)
                let entries = try parseTarArchive(data)
                let listed = filterTarEntries(entries, paths: paths, stripComponents: 0).map(\.name)
                return ExecResult.success(listed.joined(separator: "\n") + (listed.isEmpty ? "" : "\n"))
            case "x":
                let data = try loadTarArchiveData(path: archivePath, relativeTo: ctx.cwd, fileSystem: ctx.fileSystem)
                let entries = try parseTarArchive(data)
                let filtered = filterTarEntries(entries, paths: paths, stripComponents: stripComponents)
                let targetBase = VirtualPath.normalize(changeDir ?? ctx.cwd, relativeTo: ctx.cwd)
                if !ctx.fileSystem.isDirectory(targetBase) {
                    try ctx.fileSystem.createDirectory(targetBase, recursive: true)
                }
                for entry in filtered {
                    let dest = targetBase == "/" ? "/\(entry.name)" : "\(targetBase)/\(entry.name)"
                    if entry.isDirectory {
                        try ctx.fileSystem.createDirectory(dest, recursive: true)
                    } else {
                        try ctx.fileSystem.createDirectory(VirtualPath.dirname(dest), recursive: true)
                        try ctx.fileSystem.writeFile(stringFromVirtualData(entry.data, preferUTF8: false), to: dest)
                    }
                }
                let stderr = verbose ? filtered.map(\.name).joined(separator: "\n") + (filtered.isEmpty ? "" : "\n") : ""
                return ExecResult(stdout: "", stderr: stderr, exitCode: 0)
            default:
                return ExecResult.failure("tar: unsupported operation", exitCode: 2)
            }
        } catch {
            let message = (error as NSError).localizedDescription
            let exitCode = message.contains("Cannot open") || message.contains("Cowardly") ? 2 : 1
            return ExecResult.failure("tar: \(message)", exitCode: exitCode)
        }
    }
}

// MARK: - Tar internals

private struct TarEntry {
    let name: String
    let data: Data
    let isDirectory: Bool
}

private func tarHelpText() -> String {
    """
    tar - manipulate tape archives
      -c, --create
      -t, --list
      -x, --extract
      -f FILE
      -C DIR
      -z
      --strip-components=N
    """
}

private func buildTarEntries(paths: [String], changeDir: String?, ctx: CommandContext) throws -> [TarEntry] {
    let baseDir = changeDir.map { VirtualPath.normalize($0, relativeTo: ctx.cwd) } ?? ctx.cwd
    var entries: [TarEntry] = []

    for requested in paths {
        let source = VirtualPath.normalize(requested, relativeTo: baseDir)
        guard ctx.fileSystem.exists(source) else {
            throw NSError(domain: "tar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot stat: \(requested)"])
        }
        let archiveRoot = requested.hasPrefix("/") ? String(source.drop(while: { $0 == "/" })) : requested

        if ctx.fileSystem.isDirectory(source) {
            entries.append(TarEntry(name: archiveRoot.hasSuffix("/") ? archiveRoot : archiveRoot + "/", data: Data(), isDirectory: true))
            let walked = try ctx.fileSystem.walk(source)
            for path in walked where path != source {
                let relative = String(path.dropFirst(source.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !relative.isEmpty else { continue }
                let name = archiveRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + relative
                if ctx.fileSystem.isDirectory(path) {
                    entries.append(TarEntry(name: name.hasSuffix("/") ? name : name + "/", data: Data(), isDirectory: true))
                } else {
                    let content = try ctx.fileSystem.readFile(path)
                    entries.append(TarEntry(name: name, data: dataFromVirtualString(content, treatAsBinary: true), isDirectory: false))
                }
            }
        } else {
            let content = try ctx.fileSystem.readFile(source)
            entries.append(TarEntry(name: archiveRoot, data: dataFromVirtualString(content, treatAsBinary: true), isDirectory: false))
        }
    }

    return entries
}

private func buildTarArchive(_ entries: [TarEntry]) -> Data {
    var archive = Data()
    for entry in entries {
        archive.append(makeTarHeader(for: entry))
        if !entry.isDirectory {
            archive.append(entry.data)
            let remainder = entry.data.count % 512
            if remainder != 0 {
                archive.append(Data(repeating: 0, count: 512 - remainder))
            }
        }
    }
    archive.append(Data(repeating: 0, count: 1024))
    return archive
}

private func makeTarHeader(for entry: TarEntry) -> Data {
    var header = Data(repeating: 0, count: 512)
    let normalizedName = entry.isDirectory && !entry.name.hasSuffix("/") ? entry.name + "/" : entry.name
    writeTarField(normalizedName, into: &header, offset: 0, length: 100)
    writeTarOctal(entry.isDirectory ? 0o755 : 0o644, into: &header, offset: 100, length: 8)
    writeTarOctal(0, into: &header, offset: 108, length: 8)
    writeTarOctal(0, into: &header, offset: 116, length: 8)
    writeTarOctal(entry.isDirectory ? 0 : entry.data.count, into: &header, offset: 124, length: 12)
    writeTarOctal(Int(Date().timeIntervalSince1970), into: &header, offset: 136, length: 12)
    for index in 148..<156 { header[index] = 32 }
    header[156] = entry.isDirectory ? UInt8(ascii: "5") : UInt8(ascii: "0")
    writeTarField("ustar", into: &header, offset: 257, length: 6)
    writeTarField("00", into: &header, offset: 263, length: 2)
    writeTarField("user", into: &header, offset: 265, length: 32)
    writeTarField("group", into: &header, offset: 297, length: 32)
    let checksum = header.reduce(0) { $0 + Int($1) }
    writeTarChecksum(checksum, into: &header, offset: 148)
    return header
}

private func writeTarField(_ value: String, into header: inout Data, offset: Int, length: Int) {
    let bytes = Array(value.utf8.prefix(length))
    for (index, byte) in bytes.enumerated() {
        header[offset + index] = byte
    }
}

private func writeTarOctal(_ value: Int, into header: inout Data, offset: Int, length: Int) {
    let string = String(format: "%0*o", max(length - 1, 1), value)
    writeTarField(string, into: &header, offset: offset, length: length - 1)
    header[offset + length - 1] = 0
}

private func writeTarChecksum(_ value: Int, into header: inout Data, offset: Int) {
    let string = String(format: "%06o", value)
    writeTarField(string, into: &header, offset: offset, length: 6)
    header[offset + 6] = 0
    header[offset + 7] = 32
}

private func loadTarArchiveData(path: String, relativeTo cwd: String, fileSystem: VirtualFileSystem) throws -> Data {
    let content = try fileSystem.readFile(path, relativeTo: cwd)
    var data = dataFromVirtualString(content, treatAsBinary: true)
    if data.count >= 2 && data[0] == 0x1f && data[1] == 0x8b {
        data = try gunzipData(data)
    }
    return data
}

private func parseTarArchive(_ data: Data) throws -> [TarEntry] {
    var entries: [TarEntry] = []
    var offset = 0
    while offset + 512 <= data.count {
        let header = data[offset..<(offset + 512)]
        if header.allSatisfy({ $0 == 0 }) { break }

        let name = tarString(from: header, offset: 0, length: 100)
        let size = tarOctal(from: header, offset: 124, length: 12)
        let typeFlag = header[header.index(header.startIndex, offsetBy: 156)]
        let isDirectory = typeFlag == UInt8(ascii: "5") || name.hasSuffix("/")
        offset += 512

        let fileData: Data
        if isDirectory {
            fileData = Data()
        } else {
            guard offset + size <= data.count else {
                throw NSError(domain: "tar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Corrupt archive"])
            }
            fileData = data[offset..<(offset + size)]
            let padded = ((size + 511) / 512) * 512
            offset += padded
        }

        entries.append(TarEntry(name: name, data: Data(fileData), isDirectory: isDirectory))
    }
    return entries
}

private func tarString(from header: Data.SubSequence, offset: Int, length: Int) -> String {
    let start = header.index(header.startIndex, offsetBy: offset)
    let end = header.index(start, offsetBy: length)
    let bytes = header[start..<end].prefix { $0 != 0 }
    return String(decoding: bytes, as: UTF8.self)
}

private func tarOctal(from header: Data.SubSequence, offset: Int, length: Int) -> Int {
    let string = tarString(from: header, offset: offset, length: length).trimmingCharacters(in: .whitespacesAndNewlines)
    return Int(string, radix: 8) ?? 0
}

private func filterTarEntries(_ entries: [TarEntry], paths: [String], stripComponents: Int) -> [TarEntry] {
    entries.compactMap { entry in
        if !paths.isEmpty {
            let matches = paths.contains { path in
                let requested = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return entry.name == requested || entry.name.hasPrefix(requested + "/")
            }
            if !matches { return nil }
        }
        let components = entry.name.split(separator: "/").map(String.init)
        guard stripComponents < components.count || (entry.isDirectory && stripComponents == components.count) else { return nil }
        let strippedComponents = Array(components.dropFirst(stripComponents))
        let strippedName = strippedComponents.joined(separator: "/") + (entry.isDirectory && !strippedComponents.isEmpty ? "/" : "")
        guard !strippedName.contains("..") else { return nil }
        guard !strippedName.isEmpty else { return nil }
        return TarEntry(name: strippedName, data: entry.data, isDirectory: entry.isDirectory)
    }
}
