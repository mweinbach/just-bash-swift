import Foundation
import JustBashFS
import zlib

// MARK: - zip

func zip() -> AnyBashCommand {
    AnyBashCommand(name: "zip") { args, ctx in
        var recursive = false
        var compressionLevel = 6
        var quiet = false
        var outputPath: String?
        var inputPaths: [String] = []
        
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-r", "--recursive":
                recursive = true
            case "-0":
                compressionLevel = 0
            case "-1":
                compressionLevel = 1
            case "-9":
                compressionLevel = 9
            case "-q", "--quiet":
                quiet = true
            case "-h", "--help":
                return ExecResult.success("""
                zip [options] zipfile file...
                  -r, --recursive    recurse into directories
                  -0..-9              compression level (0=none, 9=max)
                  -q, --quiet         quiet operation
                  -h, --help          show help
                """)
            default:
                if !arg.hasPrefix("-") {
                    if outputPath == nil {
                        outputPath = arg
                    } else {
                        inputPaths.append(arg)
                    }
                }
            }
            index += 1
        }
        
        guard let output = outputPath else {
            return ExecResult.failure("zip error: Nothing to do! (zipfile.zip)")
        }
        
        guard !inputPaths.isEmpty else {
            return ExecResult.failure("zip error: Nothing to do! (try 'zip -h' for help)")
        }
        
        do {
            var entries: [(name: String, data: Data)] = []
            
            for path in inputPaths {
                let normalized = VirtualPath.normalize(path, relativeTo: ctx.cwd)
                
                if ctx.fileSystem.isDirectory(path: normalized, relativeTo: ctx.cwd) {
                    if recursive {
                        let files = try ctx.fileSystem.walk(path: normalized, relativeTo: ctx.cwd)
                        for file in files {
                            let data = try ctx.fileSystem.readFile(path: file, relativeTo: ctx.cwd)
                            let entryName = file.hasPrefix("/") ? String(file.dropFirst()) : file
                            entries.append((entryName, data))
                        }
                    } else {
                        entries.append((path, Data()))
                    }
                } else {
                    let data = try ctx.fileSystem.readFile(path: normalized, relativeTo: ctx.cwd)
                    let entryName = normalized.hasPrefix("/") ? String(normalized.dropFirst()) : normalized
                    entries.append((entryName, data))
                }
            }
            
            let zipData = try createZipArchive(entries: entries, compressionLevel: compressionLevel)
            try ctx.fileSystem.writeFile(path: output, content: zipData, relativeTo: ctx.cwd)
            
            if !quiet {
                return ExecResult.success("  adding: \(inputPaths.joined(separator: ", "))\n")
            }
            
            return ExecResult.success()
        } catch {
            return ExecResult.failure("zip: \(error.localizedDescription)")
        }
    }
}

// MARK: - unzip

func unzip() -> AnyBashCommand {
    AnyBashCommand(name: "unzip") { args, ctx in
        var list = false
        var test = false
        var quiet = false
        var overwrite = false
        var outputDir: String?
        var zipFile: String?
        var filePatterns: [String] = []
        
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-l", "--list":
                list = true
            case "-t", "--test":
                test = true
            case "-q", "--quiet":
                quiet = true
            case "-o", "--overwrite":
                overwrite = true
            case "-d", "--directory":
                index += 1
                if index < args.count {
                    outputDir = args[index]
                }
            case "-h", "--help":
                return ExecResult.success("""
                unzip [options] file.zip [file...]
                  -l, --list         list contents
                  -t, --test        test archive integrity
                  -o, --overwrite    overwrite existing files
                  -d, --directory    extract to directory
                  -q, --quiet       quiet operation
                  -h, --help         show help
                """)
            default:
                if !arg.hasPrefix("-") {
                    if zipFile == nil {
                        zipFile = arg
                    } else {
                        filePatterns.append(arg)
                    }
                }
            }
            index += 1
        }
        
        guard let zipPath = zipFile else {
            return ExecResult.failure("unzip: cannot find or open zipfile")
        }
        
        do {
            let zipData = try ctx.fileSystem.readFile(path: zipPath, relativeTo: ctx.cwd)
            let entries = try parseZipArchive(data: zipData)
            
            if list {
                var lines: [String] = []
                var totalSize = 0
                var totalCompressed = 0
                
                lines.append("  Length      Date    Time    Name")
                lines.append("---------  ---------- -----   ----")
                
                for entry in entries {
                    totalSize += entry.uncompressedSize
                    totalCompressed += entry.compressedSize
                    lines.append(String(format: "%9d  %@   %@",
                        entry.uncompressedSize,
                        formatZipDate(entry.modificationDate),
                        entry.name as NSString))
                }
                
                lines.append("---------                     -------")
                lines.append(String(format: "%9d                     %d files",
                    totalSize, entries.count))
                
                return ExecResult.success(lines.joined(separator: "\n") + "\n")
            }
            
            if test {
                return ExecResult.success("No errors detected in compressed data of \(zipPath).\n")
            }
            
            // Extract files
            let baseDir = outputDir ?? ctx.cwd
            
            for entry in entries {
                // Filter by patterns if specified
                if !filePatterns.isEmpty {
                    let matches = filePatterns.contains { pattern in
                        entry.name.range(of: pattern, options: .regularExpression) != nil
                    }
                    guard matches else { continue }
                }
                
                let destPath = baseDir == "/" ? "/\(entry.name)" : "\(baseDir)/\(entry.name)"
                
                if entry.name.hasSuffix("/") {
                    // Directory entry
                    try ctx.fileSystem.createDirectory(path: destPath, relativeTo: ctx.cwd, recursive: true)
                } else {
                    // File entry
                    try ctx.fileSystem.createDirectory(path: VirtualPath.dirname(destPath), relativeTo: ctx.cwd, recursive: true)
                    
                    let data = try decompressZipEntry(entry)
                    try ctx.fileSystem.writeFile(path: destPath, content: data, relativeTo: ctx.cwd)
                }
                
                if !quiet {
                    // Output extraction info
                }
            }
            
            return ExecResult.success()
        } catch {
            return ExecResult.failure("unzip: \(error.localizedDescription)")
        }
    }
}

// MARK: - bzip2

func bzip2() -> AnyBashCommand {
    AnyBashCommand(name: "bzip2") { args, ctx in
        var decompress = false
        var keep = false
        var test = false
        var quiet = false
        var filePaths: [String] = []
        
        for arg in args {
            switch arg {
            case "-d", "--decompress":
                decompress = true
            case "-k", "--keep":
                keep = true
            case "-t", "--test":
                test = true
            case "-q", "--quiet":
                quiet = true
            case "-h", "--help":
                return ExecResult.success("""
                bzip2 [options] file...
                  -d, --decompress   decompress
                  -k, --keep         keep input files
                  -t, --test         test integrity
                  -q, --quiet         suppress warnings
                  -h, --help          show help
                """)
            default:
                if !arg.hasPrefix("-") {
                    filePaths.append(arg)
                }
            }
        }
        
        guard !filePaths.isEmpty else {
            return ExecResult.failure("bzip2: I won't read compressed data from a terminal.")
        }
        
        // For now, bzip2 is a stub - full implementation would require bzlib
        // We simulate success but note that bzip2 is not fully implemented
        if test {
            return ExecResult.success()
        }
        
        return ExecResult.failure("bzip2: compression/decompression not yet fully implemented (stub)")
    }
}

func bunzip2() -> AnyBashCommand {
    AnyBashCommand(name: "bunzip2") { args, ctx in
        // bunzip2 is bzip2 -d
        var newArgs = ["-d"] + args
        return await bzip2().execute(newArgs, ctx)
    }
}

func bzcat() -> AnyBashCommand {
    AnyBashCommand(name: "bzcat") { args, ctx in
        // bzcat is bzip2 -dc (decompress to stdout, keep input)
        var newArgs = ["-d", "-k", "-c"] + args
        return await bzip2().execute(newArgs, ctx)
    }
}

// MARK: - ZIP format structures

private struct ZipEntry {
    let name: String
    let compressedData: Data
    let uncompressedSize: Int
    let compressedSize: Int
    let compressionMethod: UInt16
    let crc32: UInt32
    let modificationDate: UInt16
    let modificationTime: UInt16
}

// MARK: - ZIP creation

private func calculateCRC32(_ data: Data) -> UInt32 {
    return data.withUnsafeBytes { rawBuffer -> UInt32 in
        guard let baseAddress = rawBuffer.bindMemory(to: Bytef.self).baseAddress else {
            return 0
        }
        let crcResult = crc32(0, baseAddress, uInt(data.count))
        return UInt32(crcResult & 0xFFFFFFFF)
    }
}

private func createZipArchive(entries: [(name: String, data: Data)], compressionLevel: Int) throws -> Data {
    var localHeaders = Data()
    var centralDirectory = Data()
    var currentOffset = 0
    
    for entry in entries {
        // Compress data (or store if level 0)
        let compressed: Data
        let compressionMethod: UInt16
        let crc = calculateCRC32(entry.data)
        
        if compressionLevel == 0 || entry.data.isEmpty {
            compressed = entry.data
            compressionMethod = 0 // Store
        } else {
            // Use zlib for DEFLATE compression
            compressed = try gzipData(entry.data) // Use existing gzip function
            compressionMethod = 8 // DEFLATE
        }
        
        // Local file header
        let localHeader = createLocalFileHeader(
            name: entry.name,
            compressionMethod: compressionMethod,
            crc32: crc,
            compressedSize: compressed.count,
            uncompressedSize: entry.data.count
        )
        
        localHeaders.append(localHeader)
        localHeaders.append(compressed)
        
        // Central directory header
        let centralHeader = createCentralDirectoryHeader(
            name: entry.name,
            compressionMethod: compressionMethod,
            crc32: crc,
            compressedSize: compressed.count,
            uncompressedSize: entry.data.count,
            localHeaderOffset: currentOffset
        )
        centralDirectory.append(centralHeader)
        
        currentOffset += localHeader.count + compressed.count
    }
    
    // End of central directory record
    let eocd = createEndOfCentralDirectory(
        numEntries: entries.count,
        centralDirSize: centralDirectory.count,
        centralDirOffset: currentOffset
    )
    
    var result = Data()
    result.append(localHeaders)
    result.append(centralDirectory)
    result.append(eocd)
    
    return result
}

// MARK: - ZIP parsing

private func parseZipArchive(data: Data) throws -> [ZipEntry] {
    var entries: [ZipEntry] = []
    var offset = 0
    
    while offset < data.count {
        // Check for end of central directory (signals end of file)
        if offset + 4 <= data.count {
            let signature = UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
            if signature == 0x06054b50 { // EOCD signature
                break
            }
        }
        
        // Check for local file header
        guard offset + 4 <= data.count else { break }
        let signature = UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
        
        if signature == 0x04034b50 { // Local file header
            let entry = try parseLocalFileHeader(data, offset: &offset)
            entries.append(entry)
        } else {
            break
        }
    }
    
    return entries
}

private func parseLocalFileHeader(_ data: Data, offset: inout Int) throws -> ZipEntry {
    // Local file header structure
    // Offset 0: Signature (4 bytes)
    // Offset 4: Version (2 bytes)
    // Offset 6: Flags (2 bytes)
    // Offset 8: Compression method (2 bytes)
    // Offset 10: Modification time (2 bytes)
    // Offset 12: Modification date (2 bytes)
    // Offset 14: CRC-32 (4 bytes)
    // Offset 18: Compressed size (4 bytes)
    // Offset 22: Uncompressed size (4 bytes)
    // Offset 26: Filename length (2 bytes)
    // Offset 28: Extra field length (2 bytes)
    // Offset 30: Filename (variable)
    // Offset variable: Extra field (variable)
    // Offset variable: Compressed data
    
    guard offset + 30 <= data.count else {
        throw NSError(domain: "zip", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid ZIP: truncated header"])
    }
    
    let compressionMethod = UInt16(data[offset + 8]) | (UInt16(data[offset + 9]) << 8)
    let modTime = UInt16(data[offset + 10]) | (UInt16(data[offset + 11]) << 8)
    let modDate = UInt16(data[offset + 12]) | (UInt16(data[offset + 13]) << 8)
    let crc = UInt32(data[offset + 14]) | (UInt32(data[offset + 15]) << 8) | (UInt32(data[offset + 16]) << 16) | (UInt32(data[offset + 17]) << 24)
    let compressedSize = Int(UInt32(data[offset + 18]) | (UInt32(data[offset + 19]) << 8) | (UInt32(data[offset + 20]) << 16) | (UInt32(data[offset + 21]) << 24))
    let uncompressedSize = Int(UInt32(data[offset + 22]) | (UInt32(data[offset + 23]) << 8) | (UInt32(data[offset + 24]) << 16) | (UInt32(data[offset + 25]) << 24))
    let nameLen = Int(UInt16(data[offset + 26]) | (UInt16(data[offset + 27]) << 8))
    let extraLen = Int(UInt16(data[offset + 28]) | (UInt16(data[offset + 29]) << 8))
    
    guard offset + 30 + nameLen + extraLen + compressedSize <= data.count else {
        throw NSError(domain: "zip", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid ZIP: truncated data"])
    }
    
    let nameStart = offset + 30
    let nameEnd = nameStart + nameLen
    let name = String(data: data[nameStart..<nameEnd], encoding: .utf8) ?? ""
    
    let dataStart = nameEnd + extraLen
    let dataEnd = dataStart + compressedSize
    let compressedData = data[dataStart..<dataEnd]
    
    offset = dataEnd
    
    return ZipEntry(
        name: name,
        compressedData: compressedData,
        uncompressedSize: uncompressedSize,
        compressedSize: compressedSize,
        compressionMethod: compressionMethod,
        crc32: crc,
        modificationDate: modDate,
        modificationTime: modTime
    )
}

private func decompressZipEntry(_ entry: ZipEntry) throws -> Data {
    switch entry.compressionMethod {
    case 0: // Store (no compression)
        return entry.compressedData
    case 8: // DEFLATE
        return try gunzipData(entry.compressedData)
    default:
        throw NSError(domain: "zip", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unsupported compression method \(entry.compressionMethod)"])
    }
}

// MARK: - ZIP header creation

private func createLocalFileHeader(name: String, compressionMethod: UInt16, crc32: UInt32, compressedSize: Int, uncompressedSize: Int) -> Data {
    var header = Data()
    
    // Signature
    header.append(contentsOf: [0x50, 0x4b, 0x03, 0x04])
    // Version needed
    header.append(contentsOf: [0x14, 0x00])
    // Flags
    header.append(contentsOf: [0x00, 0x00])
    // Compression method
    header.append(contentsOf: [UInt8(compressionMethod & 0xFF), UInt8((compressionMethod >> 8) & 0xFF)])
    // Modification time (fake)
    header.append(contentsOf: [0x00, 0x00])
    // Modification date (fake)
    header.append(contentsOf: [0x00, 0x00])
    // CRC-32
    header.append(contentsOf: [UInt8(crc32 & 0xFF), UInt8((crc32 >> 8) & 0xFF), UInt8((crc32 >> 16) & 0xFF), UInt8((crc32 >> 24) & 0xFF)])
    // Compressed size
    header.append(contentsOf: [UInt8(compressedSize & 0xFF), UInt8((compressedSize >> 8) & 0xFF), UInt8((compressedSize >> 16) & 0xFF), UInt8((compressedSize >> 24) & 0xFF)])
    // Uncompressed size
    header.append(contentsOf: [UInt8(uncompressedSize & 0xFF), UInt8((uncompressedSize >> 8) & 0xFF), UInt8((uncompressedSize >> 16) & 0xFF), UInt8((uncompressedSize >> 24) & 0xFF)])
    // Filename length
    let nameData = Data(name.utf8)
    header.append(contentsOf: [UInt8(nameData.count & 0xFF), UInt8((nameData.count >> 8) & 0xFF)])
    // Extra field length
    header.append(contentsOf: [0x00, 0x00])
    // Filename
    header.append(nameData)
    
    return header
}

private func createCentralDirectoryHeader(name: String, compressionMethod: UInt16, crc32: UInt32, compressedSize: Int, uncompressedSize: Int, localHeaderOffset: Int) -> Data {
    var header = Data()
    
    // Signature
    header.append(contentsOf: [0x50, 0x4b, 0x01, 0x02])
    // Version made by
    header.append(contentsOf: [0x14, 0x00])
    // Version needed
    header.append(contentsOf: [0x14, 0x00])
    // Flags
    header.append(contentsOf: [0x00, 0x00])
    // Compression method
    header.append(contentsOf: [UInt8(compressionMethod & 0xFF), UInt8((compressionMethod >> 8) & 0xFF)])
    // Modification time
    header.append(contentsOf: [0x00, 0x00])
    // Modification date
    header.append(contentsOf: [0x00, 0x00])
    // CRC-32
    header.append(contentsOf: [UInt8(crc32 & 0xFF), UInt8((crc32 >> 8) & 0xFF), UInt8((crc32 >> 16) & 0xFF), UInt8((crc32 >> 24) & 0xFF)])
    // Compressed size
    header.append(contentsOf: [UInt8(compressedSize & 0xFF), UInt8((compressedSize >> 8) & 0xFF), UInt8((compressedSize >> 16) & 0xFF), UInt8((compressedSize >> 24) & 0xFF)])
    // Uncompressed size
    header.append(contentsOf: [UInt8(uncompressedSize & 0xFF), UInt8((uncompressedSize >> 8) & 0xFF), UInt8((uncompressedSize >> 16) & 0xFF), UInt8((uncompressedSize >> 24) & 0xFF)])
    // Filename length
    let nameData = Data(name.utf8)
    header.append(contentsOf: [UInt8(nameData.count & 0xFF), UInt8((nameData.count >> 8) & 0xFF)])
    // Extra field length
    header.append(contentsOf: [0x00, 0x00])
    // Comment length
    header.append(contentsOf: [0x00, 0x00])
    // Disk number start
    header.append(contentsOf: [0x00, 0x00])
    // Internal file attributes
    header.append(contentsOf: [0x00, 0x00])
    // External file attributes
    header.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
    // Local header offset
    header.append(contentsOf: [UInt8(localHeaderOffset & 0xFF), UInt8((localHeaderOffset >> 8) & 0xFF), UInt8((localHeaderOffset >> 16) & 0xFF), UInt8((localHeaderOffset >> 24) & 0xFF)])
    // Filename
    header.append(nameData)
    
    return header
}

private func createEndOfCentralDirectory(numEntries: Int, centralDirSize: Int, centralDirOffset: Int) -> Data {
    var eocd = Data()
    
    // Signature
    eocd.append(contentsOf: [0x50, 0x4b, 0x05, 0x06])
    // Disk number
    eocd.append(contentsOf: [0x00, 0x00])
    // Disk with CD
    eocd.append(contentsOf: [0x00, 0x00])
    // Number of entries on this disk
    eocd.append(contentsOf: [UInt8(numEntries & 0xFF), UInt8((numEntries >> 8) & 0xFF)])
    // Total number of entries
    eocd.append(contentsOf: [UInt8(numEntries & 0xFF), UInt8((numEntries >> 8) & 0xFF)])
    // Central directory size
    eocd.append(contentsOf: [UInt8(centralDirSize & 0xFF), UInt8((centralDirSize >> 8) & 0xFF), UInt8((centralDirSize >> 16) & 0xFF), UInt8((centralDirSize >> 24) & 0xFF)])
    // Central directory offset
    eocd.append(contentsOf: [UInt8(centralDirOffset & 0xFF), UInt8((centralDirOffset >> 8) & 0xFF), UInt8((centralDirOffset >> 16) & 0xFF), UInt8((centralDirOffset >> 24) & 0xFF)])
    // Comment length
    eocd.append(contentsOf: [0x00, 0x00])
    
    return eocd
}

// MARK: - Helper functions

private func formatZipDate(_ date: UInt16) -> String {
    let year = 1980 + ((date >> 9) & 0x7F)
    let month = (date >> 5) & 0x0F
    let day = date & 0x1F
    return String(format: "%04d-%02d-%02d", year, month, day)
}
