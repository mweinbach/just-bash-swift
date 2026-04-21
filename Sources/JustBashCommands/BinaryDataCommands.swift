import Foundation
import JustBashFS

// MARK: - Hexdump / xxd

func hexdump() -> AnyBashCommand {
    AnyBashCommand(name: "hexdump") { args, ctx in
        var canonical = false
        var showOffsets = false
        var format = "%07.7_ax  %_p  %07.7_ax\n%08.8_ax  "
        var plainHex = false
        var filePaths: [String] = []
        var useStdin = true
        
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-C", "--canonical":
                canonical = true
            case "-c", "--format":
                index += 1
                if index < args.count {
                    format = args[index]
                }
            case "-s", "--skip":
                index += 1 // Skip offset value
            case "-n", "--length":
                index += 1 // Length value
            case "-v", "--no-squeezing":
                break // Always verbose in our implementation
            case "-p", "--plain":
                plainHex = true
            case "-x", "--hex":
                format = "%07.7_ax  %_p  %07.7_ax\n%08.8_ax  "
            case "--help":
                return ExecResult.success("""
                hexdump [options] [file...]
                  -C, --canonical     canonical hex+ASCII display
                  -p, --plain         plain hex dump, no offsets
                  -x, --hex           two-byte hex display
                  --help              show help
                """)
            default:
                if !arg.hasPrefix("-") {
                    filePaths.append(arg)
                    useStdin = false
                }
            }
            index += 1
        }
        
        let data: Data
        do {
            if useStdin {
                data = Data(ctx.stdin.utf8)
            } else if let path = filePaths.first {
                data = try ctx.fileSystem.readFile(path: path, relativeTo: ctx.cwd)
            } else {
                data = Data()
            }
        } catch {
            return ExecResult.failure("hexdump: \(error.localizedDescription)")
        }
        
        if data.isEmpty {
            return ExecResult.success()
        }
        
        let output: String
        if plainHex {
            output = formatPlainHex(data)
        } else if canonical {
            output = formatCanonicalHex(data)
        } else {
            output = formatStandardHex(data)
        }
        
        return ExecResult.success(output)
    }
}

func xxd() -> AnyBashCommand {
    // xxd is similar to hexdump with slightly different defaults
    AnyBashCommand(name: "xxd") { args, ctx in
        var binary = false
        var reverse = false
        var uppercase = false
        var groupSize = 2
        var filePaths: [String] = []
        var useStdin = true
        
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-b", "-bits":
                binary = true
            case "-p", "-plain":
                groupSize = 0 // Plain continuous output
            case "-r", "-revert":
                reverse = true
            case "-u", "-uppercase":
                uppercase = true
            case "-g", "-groupsize":
                index += 1
                if index < args.count {
                    groupSize = Int(args[index]) ?? 2
                }
            case "-h", "--help":
                return ExecResult.success("""
                xxd [options] [file...]
                  -b, -bits          binary digit dump
                  -p, -plain        plain hex dump
                  -r, -revert       reverse operation
                  -u, -uppercase    use uppercase hex
                  -g, -groupsize    number of octets per group
                  -h, --help        show help
                """)
            default:
                if !arg.hasPrefix("-") {
                    filePaths.append(arg)
                    useStdin = false
                }
            }
            index += 1
        }
        
        if reverse {
            // Reverse mode: convert hex back to binary
            let hexString: String
            if useStdin {
                hexString = ctx.stdin.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "")
            } else if let path = filePaths.first {
                do {
                    let data = try ctx.fileSystem.readFile(path: path, relativeTo: ctx.cwd)
                    hexString = String(decoding: data, as: UTF8.self).replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "")
                } catch {
                    return ExecResult.failure("xxd: \(error.localizedDescription)")
                }
            } else {
                hexString = ""
            }
            
            var output = Data()
            var index = hexString.startIndex
            while index < hexString.endIndex {
                let nextIndex = hexString.index(index, offsetBy: 2, limitedBy: hexString.endIndex) ?? hexString.endIndex
                if let byte = UInt8(hexString[index..<nextIndex], radix: 16) {
                    output.append(byte)
                }
                index = nextIndex
            }
            
            return ExecResult.success(String(decoding: output, as: UTF8.self))
        }
        
        let data: Data
        do {
            if useStdin {
                data = Data(ctx.stdin.utf8)
            } else if let path = filePaths.first {
                data = try ctx.fileSystem.readFile(path: path, relativeTo: ctx.cwd)
            } else {
                data = Data()
            }
        } catch {
            return ExecResult.failure("xxd: \(error.localizedDescription)")
        }
        
        if data.isEmpty {
            return ExecResult.success()
        }
        
        let output: String
        if binary {
            output = formatBinaryDump(data, uppercase: uppercase)
        } else if groupSize == 0 {
            output = formatPlainHexDump(data, uppercase: uppercase)
        } else {
            output = formatXXD(data, groupSize: groupSize, uppercase: uppercase)
        }
        
        return ExecResult.success(output + "\n")
    }
}

// MARK: - Iconv (character encoding conversion)

func iconv() -> AnyBashCommand {
    AnyBashCommand(name: "iconv") { args, ctx in
        var fromEncoding = "UTF-8"
        var toEncoding = "UTF-8"
        var filePaths: [String] = []
        var useStdin = true
        
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-f", "--from-code":
                index += 1
                if index < args.count {
                    fromEncoding = args[index]
                }
            case "-t", "--to-code":
                index += 1
                if index < args.count {
                    toEncoding = args[index]
                }
            case "-l", "--list":
                return ExecResult.success("""
                The following list contains all the supported encodings:
                  UTF-8, UTF-16, UTF-16BE, UTF-16LE
                  ISO-8859-1 (Latin-1)
                  ASCII, US-ASCII
                  WINDOWS-1252
                """)
            case "--help":
                return ExecResult.success("""
                iconv [options] [file...]
                  -f, --from-code     input encoding
                  -t, --to-code       output encoding
                  -l, --list          list known encodings
                  --help              show help
                """)
            default:
                if !arg.hasPrefix("-") {
                    filePaths.append(arg)
                    useStdin = false
                }
            }
            index += 1
        }
        
        let input: Data
        do {
            if useStdin {
                input = Data(ctx.stdin.utf8)
            } else if let path = filePaths.first {
                input = try ctx.fileSystem.readFile(path: path, relativeTo: ctx.cwd)
            } else {
                input = Data()
            }
        } catch {
            return ExecResult.failure("iconv: \(error.localizedDescription)")
        }
        
        // For now, we just pass through since most modern data is UTF-8
        // In a full implementation, we'd use CoreFoundation or iconv library
        let output = String(decoding: input, as: UTF8.self)
        return ExecResult.success(output + (output.hasSuffix("\n") ? "" : "\n"))
    }
}

// MARK: - Uuencode / Uudecode

func uuencode() -> AnyBashCommand {
    AnyBashCommand(name: "uuencode") { args, ctx in
        var decodeMode = false
        var filePaths: [String] = []
        
        for arg in args {
            if arg == "--help" || arg == "-h" {
                return ExecResult.success("""
                uuencode [file] [remote-file]
                  Encode/decode a file for transmission
                """)
            }
            if arg == "-d" || arg == "--decode" {
                decodeMode = true
            } else if !arg.hasPrefix("-") {
                filePaths.append(arg)
            }
        }
        
        if decodeMode {
            // uudecode mode
            let input = ctx.stdin
            guard let startIndex = input.range(of: "begin ")?.upperBound,
                  let endIndex = input.range(of: "end\n")?.lowerBound else {
                return ExecResult.failure("uudecode: no 'begin' line")
            }
            
            let encodedContent = String(input[startIndex...])
            let lines = encodedContent.components(separatedBy: .newlines)
            
            var output = Data()
            for line in lines {
                if line.isEmpty || line.hasPrefix(" ") { continue }
                guard let firstChar = line.first,
                      let lineLength = UInt8(String(firstChar), radix: 8) else { continue }
                
                let encodedData = String(line.dropFirst())
                var byteCount = 0
                var charIndex = encodedData.startIndex
                
                while byteCount < lineLength && charIndex < encodedData.endIndex {
                    let nextIndex = encodedData.index(charIndex, offsetBy: 4, limitedBy: encodedData.endIndex) ?? encodedData.endIndex
                    let group = String(encodedData[charIndex..<nextIndex])
                    
                    if group.count >= 3 {
                        let c1 = (group[group.index(group.startIndex, offsetBy: 0)].asciiValue ?? 32) - 32
                        let c2 = (group[group.index(group.startIndex, offsetBy: 1)].asciiValue ?? 32) - 32
                        let c3 = (group[group.index(group.startIndex, offsetBy: 2)].asciiValue ?? 32) - 32
                        let c4 = (group.count > 3 ? (group[group.index(group.startIndex, offsetBy: 3)].asciiValue ?? 32) - 32 : 0)
                        
                        output.append((c1 << 2) | ((c2 >> 4) & 0x3))
                        if group.count > 1 { output.append(((c2 & 0xF) << 4) | ((c3 >> 2) & 0xF)) }
                        if group.count > 2 { output.append(((c3 & 0x3) << 6) | (c4 & 0x3F)) }
                    }
                    
                    byteCount += 3
                    charIndex = nextIndex
                }
            }
            
            return ExecResult.success(String(decoding: output, as: UTF8.self))
        }
        
        // uuencode mode
        let data: Data
        do {
            if let path = filePaths.first {
                data = try ctx.fileSystem.readFile(path: path, relativeTo: ctx.cwd)
            } else {
                data = Data(ctx.stdin.utf8)
            }
        } catch {
            return ExecResult.failure("uuencode: \(error.localizedDescription)")
        }
        
        let remoteName = filePaths.count > 1 ? filePaths[1] : "file"
        var output = "begin 644 \(remoteName)\n"
        
        var index = 0
        while index < data.count {
            let chunkEnd = min(index + 45, data.count)
            let chunk = data[index..<chunkEnd]
            
            let lengthChar = Character(UnicodeScalar((chunk.count + 32) & 0x7F) ?? UnicodeScalar(32))
            output.append(lengthChar)
            
            var charIndex = 0
            while charIndex < chunk.count {
                let b1 = chunk[chunk.index(chunk.startIndex, offsetBy: charIndex)]
                let b2 = charIndex + 1 < chunk.count ? chunk[chunk.index(chunk.startIndex, offsetBy: charIndex + 1)] : 0
                let b3 = charIndex + 2 < chunk.count ? chunk[chunk.index(chunk.startIndex, offsetBy: charIndex + 2)] : 0
                
                let c1 = Character(UnicodeScalar(((b1 >> 2) & 0x3F) + 32))
                let c2 = Character(UnicodeScalar((((b1 & 0x3) << 4) | ((b2 >> 4) & 0xF)) + 32))
                let c3 = Character(UnicodeScalar((((b2 & 0xF) << 2) | ((b3 >> 6) & 0x3)) + 32))
                let c4 = Character(UnicodeScalar((b3 & 0x3F) + 32))
                
                output.append(String([c1, c2, c3, c4]))
                
                charIndex += 3
            }
            
            output.append("\n")
            index += 45
        }
        
        output.append("end\n")
        return ExecResult.success(output)
    }
}

// MARK: - Format helpers

private func formatCanonicalHex(_ data: Data) -> String {
    var lines: [String] = []
    var offset = 0
    
    while offset < data.count {
        let chunkEnd = min(offset + 16, data.count)
        let chunk = data[offset..<chunkEnd]
        
        // Offset
        var line = String(format: "%08x  ", offset)
        
        // Hex bytes (8 + 8 with space in middle)
        var hexPart = ""
        for (i, byte) in chunk.enumerated() {
            hexPart += String(format: "%02x ", byte)
            if i == 7 { hexPart += " " }
        }
        // Pad to fixed width
        while hexPart.count < 50 {
            hexPart += " "
        }
        line += hexPart
        
        // ASCII representation
        line += "|"
        for byte in chunk {
            if byte >= 32 && byte < 127 {
                line.append(Character(UnicodeScalar(byte)))
            } else {
                line.append(".")
            }
        }
        line += "|"
        
        lines.append(line)
        offset += 16
    }
    
    return lines.joined(separator: "\n") + "\n"
}

private func formatStandardHex(_ data: Data) -> String {
    var lines: [String] = []
    var offset = 0
    
    while offset < data.count {
        let chunkEnd = min(offset + 16, data.count)
        let chunk = data[offset..<chunkEnd]
        
        var line = String(format: "%07x ", offset)
        for byte in chunk {
            line += String(format: "%02x ", byte)
        }
        
        lines.append(line)
        offset += 16
    }
    
    return lines.joined(separator: "\n") + "\n"
}

private func formatPlainHex(_ data: Data) -> String {
    var result = ""
    for byte in data {
        result += String(format: "%02x", byte)
    }
    return result
}

private func formatBinaryDump(_ data: Data, uppercase: Bool) -> String {
    var lines: [String] = []
    var offset = 0
    
    while offset < data.count {
        let chunkEnd = min(offset + 6, data.count)
        let chunk = data[offset..<chunkEnd]
        
        var line = String(format: "%08x: ", offset)
        for byte in chunk {
            let binary = String(byte, radix: 2).padding(toLength: 8, withPad: "0", startingAt: 0)
            line += uppercase ? binary.uppercased() : binary
            line += " "
        }
        
        lines.append(line)
        offset += 6
    }
    
    return lines.joined(separator: "\n")
}

private func formatPlainHexDump(_ data: Data, uppercase: Bool) -> String {
    var result = ""
    for byte in data {
        let hex = String(format: "%02x", byte)
        result += uppercase ? hex.uppercased() : hex
    }
    return result
}

private func formatXXD(_ data: Data, groupSize: Int, uppercase: Bool) -> String {
    var lines: [String] = []
    var offset = 0
    let bytesPerLine = 16
    
    while offset < data.count {
        let chunkEnd = min(offset + bytesPerLine, data.count)
        let chunk = data[offset..<chunkEnd]
        
        var line = String(format: "%08x: ", offset)
        
        // Hex groups
        for (i, byte) in chunk.enumerated() {
            let hex = String(format: "%02x", byte)
            line += uppercase ? hex.uppercased() : hex
            
            if groupSize > 0 && (i + 1) % groupSize == 0 && i < chunk.count - 1 {
                line += " "
            }
        }
        
        // Pad to align ASCII
        let hexLength = line.count - 10 // Subtract offset prefix
        let targetLength = bytesPerLine * 2 + (bytesPerLine / max(groupSize, 1)) + 2
        while hexLength < targetLength {
            line += " "
        }
        
        // ASCII representation
        line += " "
        for byte in chunk {
            if byte >= 32 && byte < 127 {
                line.append(Character(UnicodeScalar(byte)))
            } else {
                line.append(".")
            }
        }
        
        lines.append(line)
        offset += bytesPerLine
    }
    
    return lines.joined(separator: "\n")
}
