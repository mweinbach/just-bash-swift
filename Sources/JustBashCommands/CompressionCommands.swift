import Foundation
import JustBashFS
import zlib

func gzip() -> AnyBashCommand {
    gzipFamilyCommand(name: "gzip", defaultDecompress: false, alwaysStdout: false)
}

func gunzip() -> AnyBashCommand {
    gzipFamilyCommand(name: "gunzip", defaultDecompress: true, alwaysStdout: false)
}

func zcat() -> AnyBashCommand {
    gzipFamilyCommand(name: "zcat", defaultDecompress: true, alwaysStdout: true)
}

private func gzipFamilyCommand(name: String, defaultDecompress: Bool, alwaysStdout: Bool) -> AnyBashCommand {
    AnyBashCommand(name: name) { args, ctx in
        var writeStdout = alwaysStdout
        var decompress = defaultDecompress
        var keepOriginal = alwaysStdout
        var force = false
        var suffix = ".gz"
        var files: [String] = []
        var index = 0

        while index < args.count {
            switch args[index] {
            case "-c", "--stdout", "--to-stdout":
                writeStdout = true
                index += 1
            case "-d", "--decompress", "--uncompress":
                decompress = true
                index += 1
            case "-k", "--keep":
                keepOriginal = true
                index += 1
            case "-f", "--force":
                force = true
                index += 1
            case "-S", "--suffix":
                if index + 1 < args.count {
                    suffix = args[index + 1]
                    index += 2
                } else {
                    return ExecResult.failure("\(name): option requires an argument -- S")
                }
            case let option where option.hasPrefix("-S") && option.count > 2:
                suffix = String(option.dropFirst(2))
                index += 1
            case "--help":
                return ExecResult.success(gzipHelp(name: name))
            case let option where option.hasPrefix("-"):
                if option == "-" {
                    files.append(option)
                } else {
                    index += 1
                    continue
                }
                index += 1
            default:
                files.append(args[index])
                index += 1
            }
        }

        if files.isEmpty {
            files = ["-"]
            writeStdout = true
        }

        var combined = ExecResult()
        for file in files {
            let isStdin = file == "-"
            let inputData: Data
            let originalLabel = isStdin ? "stdin" : file

            do {
                if isStdin {
                    inputData = dataFromVirtualString(ctx.stdin, treatAsBinary: decompress)
                } else {
                    let content = try ctx.fileSystem.readFile(file, relativeTo: ctx.cwd)
                    inputData = dataFromVirtualString(content, treatAsBinary: decompress || file.hasSuffix(suffix))
                }
            } catch {
                return ExecResult.failure("\(name): \(error.localizedDescription)")
            }

            do {
                if decompress {
                    let outputData = try gunzipData(inputData)
                    let outputString = stringFromVirtualData(outputData, preferUTF8: true)
                    if writeStdout {
                        combined.stdout += outputString
                    } else {
                        guard !isStdin else {
                            combined.stdout += outputString
                            continue
                        }
                        guard file.hasSuffix(suffix) else {
                            return ExecResult.failure("\(name): unknown suffix -- \(file)")
                        }
                        let outputPath = String(file.dropLast(suffix.count))
                        if ctx.fileSystem.exists(outputPath, relativeTo: ctx.cwd) && !force {
                            return ExecResult.failure("\(name): \(outputPath) already exists")
                        }
                        try ctx.fileSystem.writeFile(outputString, to: outputPath, relativeTo: ctx.cwd)
                        if !keepOriginal {
                            try ctx.fileSystem.removeItem(file, relativeTo: ctx.cwd, recursive: false, force: false)
                        }
                    }
                } else {
                    let outputData = try gzipData(inputData)
                    let outputString = stringFromVirtualData(outputData, preferUTF8: false)
                    if writeStdout {
                        combined.stdout += outputString
                    } else {
                        guard !isStdin else {
                            combined.stdout += outputString
                            continue
                        }
                        if file.hasSuffix(suffix) {
                            return ExecResult.failure("\(name): \(file) already has \(suffix) suffix -- unchanged")
                        }
                        let outputPath = file + suffix
                        if ctx.fileSystem.exists(outputPath, relativeTo: ctx.cwd) && !force {
                            return ExecResult.failure("\(name): \(outputPath) already exists")
                        }
                        try ctx.fileSystem.writeFile(outputString, to: outputPath, relativeTo: ctx.cwd)
                        if !keepOriginal {
                            try ctx.fileSystem.removeItem(file, relativeTo: ctx.cwd, recursive: false, force: false)
                        }
                    }
                }
            } catch {
                let errorText = error.localizedDescription
                if errorText.hasPrefix(name + ":") {
                    return ExecResult.failure(errorText)
                }
                if errorText == "invalid gzip data" {
                    return ExecResult.failure("\(name): \(originalLabel): not in gzip format")
                }
                return ExecResult.failure("\(name): \(errorText)")
            }
        }

        return combined
    }
}

private func gzipHelp(name: String) -> String {
    let summary: String
    switch name {
    case "gunzip":
        summary = "gunzip - decompress files\n"
    case "zcat":
        summary = "zcat - decompress files to stdout\n"
    default:
        summary = "gzip - compress or decompress files\n"
    }
    return summary + "options: -c -d -k -f -S SUF --help\n"
}

// MARK: - Shared helpers (used by TarCommand too)

func dataFromVirtualString(_ text: String, treatAsBinary: Bool) -> Data {
    if treatAsBinary {
        return text.data(using: .isoLatin1) ?? Data(text.utf8)
    }
    return Data(text.utf8)
}

func stringFromVirtualData(_ data: Data, preferUTF8: Bool) -> String {
    if preferUTF8, let utf8 = String(data: data, encoding: .utf8) {
        return utf8
    }
    return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
}

func gzipData(_ data: Data) throws -> Data {
    var stream = z_stream()
    let initStatus = deflateInit2_(
        &stream,
        Z_DEFAULT_COMPRESSION,
        Z_DEFLATED,
        MAX_WBITS + 16,
        MAX_MEM_LEVEL,
        Z_DEFAULT_STRATEGY,
        ZLIB_VERSION,
        Int32(MemoryLayout<z_stream>.size)
    )
    guard initStatus == Z_OK else {
        throw NSError(domain: "gzip", code: Int(initStatus), userInfo: [NSLocalizedDescriptionKey: "failed to initialize compressor"])
    }
    defer { deflateEnd(&stream) }

    return try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.bindMemory(to: Bytef.self).baseAddress else {
            return Data()
        }
        stream.next_in = UnsafeMutablePointer(mutating: baseAddress)
        stream.avail_in = uInt(data.count)

        let bound = Int(deflateBound(&stream, uLong(data.count)))
        var output = Data(count: max(bound, 64))
        let status = output.withUnsafeMutableBytes { rawOutput -> Int32 in
            let outputBuffer = rawOutput.bindMemory(to: Bytef.self)
            stream.next_out = outputBuffer.baseAddress
            stream.avail_out = uInt(outputBuffer.count)
            return deflate(&stream, Z_FINISH)
        }
        guard status == Z_STREAM_END else {
            throw NSError(domain: "gzip", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "compression failed"])
        }
        output.count = Int(stream.total_out)
        return output
    }
}

func gunzipData(_ data: Data) throws -> Data {
    guard !data.isEmpty else { return Data() }
    var stream = z_stream()
    let initStatus = inflateInit2_(
        &stream,
        MAX_WBITS + 32,
        ZLIB_VERSION,
        Int32(MemoryLayout<z_stream>.size)
    )
    guard initStatus == Z_OK else {
        throw NSError(domain: "gzip", code: Int(initStatus), userInfo: [NSLocalizedDescriptionKey: "failed to initialize decompressor"])
    }
    defer { inflateEnd(&stream) }

    return try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.bindMemory(to: Bytef.self).baseAddress else {
            return Data()
        }
        stream.next_in = UnsafeMutablePointer(mutating: baseAddress)
        stream.avail_in = uInt(data.count)

        let chunkSize = 64 * 1024
        var output = Data()
        while true {
            var chunk = Data(count: chunkSize)
            let status: Int32 = chunk.withUnsafeMutableBytes { rawOutput in
                let outputBuffer = rawOutput.bindMemory(to: Bytef.self)
                stream.next_out = outputBuffer.baseAddress
                stream.avail_out = uInt(outputBuffer.count)
                return inflate(&stream, Z_NO_FLUSH)
            }
            let produced = chunkSize - Int(stream.avail_out)
            if produced > 0 {
                output.append(chunk.prefix(produced))
            }
            if status == Z_STREAM_END {
                return output
            }
            guard status == Z_OK else {
                throw NSError(domain: "gzip", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "invalid gzip data"])
            }
        }
    }
}
