import Foundation
import JustBashFS
import zlib

// MARK: - cksum (CRC checksum)

func cksum() -> AnyBashCommand {
    AnyBashCommand(name: "cksum") { args, ctx in
        var filePaths: [String] = []
        var useStdin = true
        
        for arg in args {
            if arg == "--help" {
                return ExecResult.success("""
                cksum [file...]
                  Compute CRC checksum and byte count
                """)
            } else if !arg.hasPrefix("-") {
                filePaths.append(arg)
                useStdin = false
            }
        }
        
        var results: [String] = []
        
        if useStdin {
            let data = Data(ctx.stdin.utf8)
            let crc = calculateCRC32(data)
            let size = data.count
            results.append("\(crc) \(size)")
        } else {
            for path in filePaths {
                do {
                    let data = try ctx.fileSystem.readFile(path: path, relativeTo: ctx.cwd)
                    let crc = calculateCRC32(data)
                    let size = data.count
                    results.append("\(crc) \(size) \(path)")
                } catch {
                    return ExecResult.failure("cksum: \(path): \(error.localizedDescription)")
                }
            }
        }
        
        return ExecResult.success(results.joined(separator: "\n") + "\n")
    }
}

private func calculateCRC32(_ data: Data) -> UInt32 {
    return data.withUnsafeBytes { rawBuffer -> UInt32 in
        guard let baseAddress = rawBuffer.bindMemory(to: Bytef.self).baseAddress else {
            return 0
        }
        let crcResult = crc32(0, baseAddress, uInt(data.count))
        return UInt32(crcResult & 0xFFFFFFFF)
    }
}

// MARK: - sum (traditional checksum)

func sum() -> AnyBashCommand {
    AnyBashCommand(name: "sum") { args, ctx in
        var sysvMode = false
        var filePaths: [String] = []
        var useStdin = true
        
        for arg in args {
            switch arg {
            case "-s", "--sysv":
                sysvMode = true
            case "-r", "--bsd":
                sysvMode = false
            case "--help":
                return ExecResult.success("""
                sum [options] [file...]
                  -s, --sysv    use System V sum algorithm
                  -r, --bsd     use BSD sum algorithm (default)
                  --help        show help
                """)
            default:
                if !arg.hasPrefix("-") {
                    filePaths.append(arg)
                    useStdin = false
                }
            }
        }
        
        var results: [String] = []
        
        func computeSum(_ data: Data) -> (checksum: UInt32, blocks: Int) {
            if sysvMode { return sysvSum(data) }
            let bsd = bsdSum(data)
            return (UInt32(bsd.checksum), bsd.blocks)
        }
        if useStdin {
            let data = Data(ctx.stdin.utf8)
            let (checksum, blocks) = computeSum(data)
            results.append("\(checksum) \(blocks)")
        } else {
            for path in filePaths {
                do {
                    let data = try ctx.fileSystem.readFile(path: path, relativeTo: ctx.cwd)
                    let (checksum, blocks) = computeSum(data)
                    results.append("\(checksum) \(blocks) \(path)")
                } catch {
                    return ExecResult.failure("sum: \(path): \(error.localizedDescription)")
                }
            }
        }
        
        return ExecResult.success(results.joined(separator: "\n") + "\n")
    }
}

private func bsdSum(_ data: Data) -> (checksum: UInt16, blocks: Int) {
    var checksum: UInt32 = 0
    for byte in data {
        checksum = (checksum >> 1) + ((checksum & 1) << 15) + UInt32(byte)
        checksum &= 0xFFFF
    }
    let blocks = (data.count + 1023) / 1024  // 1K blocks
    return (UInt16(checksum), blocks)
}

private func sysvSum(_ data: Data) -> (checksum: UInt32, blocks: Int) {
    var checksum: UInt32 = 0
    for byte in data {
        checksum += UInt32(byte)
    }
    let blocks = (data.count + 511) / 512  // 512-byte blocks
    return (checksum, blocks)
}

// MARK: - fmt (format paragraphs)

func fmt() -> AnyBashCommand {
    AnyBashCommand(name: "fmt") { args, ctx in
        var width = 75
        var goalWidth = 70
        var uniformSpacing = false
        var filePaths: [String] = []
        var useStdin = true
        
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-w", "--width":
                index += 1
                if index < args.count {
                    width = Int(args[index]) ?? 75
                    goalWidth = width - 5
                }
            case "-g", "--goal":
                index += 1
                if index < args.count {
                    goalWidth = Int(args[index]) ?? 70
                }
            case "-u", "--uniform-spacing":
                uniformSpacing = true
            case "--help":
                return ExecResult.success("""
                fmt [options] [file...]
                  -w, --width WIDTH       maximum line width (default 75)
                  -g, --goal WIDTH        goal line width (default 70)
                  -u, --uniform-spacing    uniform word spacing
                  --help                   show help
                """)
            default:
                if !arg.hasPrefix("-") {
                    filePaths.append(arg)
                    useStdin = false
                }
            }
            index += 1
        }
        
        let input: String
        do {
            if useStdin {
                input = ctx.stdin
            } else if let path = filePaths.first {
                let data = try ctx.fileSystem.readFile(path: path, relativeTo: ctx.cwd)
                input = String(decoding: data, as: UTF8.self)
            } else {
                input = ""
            }
        } catch {
            return ExecResult.failure("fmt: \(error.localizedDescription)")
        }
        
        let formatted = formatText(input, width: width, uniformSpacing: uniformSpacing)
        return ExecResult.success(formatted)
    }
}

private func formatText(_ text: String, width: Int, uniformSpacing: Bool) -> String {
    let paragraphs = text.components(separatedBy: "\n\n")
    var result: [String] = []
    
    for paragraph in paragraphs {
        let words = paragraph.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard !words.isEmpty else {
            result.append("")
            continue
        }
        
        var lines: [String] = []
        var currentLine = words[0]
        
        for word in words.dropFirst() {
            if currentLine.count + 1 + word.count <= width {
                currentLine += " \(word)"
            } else {
                lines.append(currentLine)
                currentLine = word
            }
        }
        lines.append(currentLine)
        
        result.append(lines.joined(separator: "\n"))
    }
    
    return result.joined(separator: "\n\n") + "\n"
}

// MARK: - pr (print files)

func pr() -> AnyBashCommand {
    AnyBashCommand(name: "pr") { args, ctx in
        var numColumns = 1
        var doubleSpace = false
        var linesPerPage = 66
        var pageWidth = 72
        var omitHeader = false
        var filePaths: [String] = []
        
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-1", "-2", "-3", "-4", "-5", "-6", "-7", "-8", "-9":
                numColumns = Int(String(arg.dropFirst())) ?? 1
            case "-a", "--across":
                // Print columns across (not implemented fully)
                break
            case "-d", "--double-space":
                doubleSpace = true
            case "-l", "--length":
                index += 1
                if index < args.count {
                    linesPerPage = Int(args[index]) ?? 66
                }
            case "-w", "--width":
                index += 1
                if index < args.count {
                    pageWidth = Int(args[index]) ?? 72
                }
            case "-t", "--omit-header":
                omitHeader = true
            case "--help":
                return ExecResult.success("""
                pr [options] [file...]
                  -1..-9                number of columns
                  -d, --double-space   double space
                  -l, --length LINES    lines per page
                  -w, --width WIDTH     page width
                  -t, --omit-header     omit page headers
                  --help                show help
                """)
            default:
                if !arg.hasPrefix("-") {
                    filePaths.append(arg)
                }
            }
            index += 1
        }
        
        // Simplified pr - just output with optional double spacing
        let input: String
        do {
            if filePaths.isEmpty {
                input = ctx.stdin
            } else if let path = filePaths.first {
                let data = try ctx.fileSystem.readFile(path: path, relativeTo: ctx.cwd)
                input = String(decoding: data, as: UTF8.self)
            } else {
                input = ""
            }
        } catch {
            return ExecResult.failure("pr: \(error.localizedDescription)")
        }
        
        let lines = input.components(separatedBy: .newlines)
        var output: [String] = []
        
        if !omitHeader {
            let date = Date()
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            let header = String(format: "%@ Page 1", formatter.string(from: date))
            output.append(header)
            output.append("")
        }
        
        for line in lines {
            output.append(line)
            if doubleSpace {
                output.append("")
            }
        }
        
        // Add footer/page break for multiple pages (simplified)
        output.append("")
        output.append("")
        
        return ExecResult.success(output.joined(separator: "\n"))
    }
}

// MARK: - look (dictionary search)

func look() -> AnyBashCommand {
    AnyBashCommand(name: "look") { args, ctx in
        var dictionaryFile = "/usr/share/dict/words"
        var ignoreCase = false
        var searchTerm: String?
        
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-d", "--alphanumeric":
                // Ignore non-alphanumeric (simplified)
                break
            case "-f", "--ignore-case":
                ignoreCase = true
            case "-t", "--terminate":
                index += 1
                // Skip terminate character
            case "--help":
                return ExecResult.success("""
                look [options] string [file]
                  -d, --alphanumeric    ignore non-alphanumeric
                  -f, --ignore-case      ignore case
                  --help                 show help
                """)
            default:
                if !arg.hasPrefix("-") {
                    if searchTerm == nil {
                        searchTerm = arg
                    } else {
                        dictionaryFile = arg
                    }
                }
            }
            index += 1
        }
        
        guard let term = searchTerm else {
            return ExecResult.failure("look: missing search term")
        }
        
        do {
            let dictData = try ctx.fileSystem.readFile(path: dictionaryFile, relativeTo: ctx.cwd)
            let dictText = String(decoding: dictData, as: UTF8.self)
            let words = dictText.components(separatedBy: .newlines)
            
            let matches = words.filter { word in
                let compareTerm = ignoreCase ? term.lowercased() : term
                let compareWord = ignoreCase ? word.lowercased() : word
                return compareWord.hasPrefix(compareTerm)
            }
            
            return ExecResult.success(matches.joined(separator: "\n") + (matches.isEmpty ? "" : "\n"))
        } catch {
            // Return empty if dictionary not found
            return ExecResult.success("")
        }
    }
}

// MARK: - tsort (topological sort)

func tsort() -> AnyBashCommand {
    AnyBashCommand(name: "tsort") { args, ctx in
        var filePath: String?
        var useStdin = true
        
        for arg in args {
            if arg == "--help" {
                return ExecResult.success("""
                tsort [file]
                  Topological sort of a directed graph
                """)
            } else if !arg.hasPrefix("-") {
                filePath = arg
                useStdin = false
            }
        }
        
        let input: String
        do {
            if useStdin {
                input = ctx.stdin
            } else if let path = filePath {
                let data = try ctx.fileSystem.readFile(path: path, relativeTo: ctx.cwd)
                input = String(decoding: data, as: UTF8.self)
            } else {
                input = ""
            }
        } catch {
            return ExecResult.failure("tsort: \(error.localizedDescription)")
        }
        
        // Parse edges
        let tokens = input.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        var edges: [(String, String)] = []
        var i = 0
        while i + 1 < tokens.count {
            edges.append((tokens[i], tokens[i + 1]))
            i += 2
        }
        
        // Topological sort (Kahn's algorithm)
        var inDegree: [String: Int] = [:]
        var adjacency: [String: [String]] = [:]
        var nodes = Set<String>()
        
        for (from, to) in edges {
            nodes.insert(from)
            nodes.insert(to)
            adjacency[from, default: []].append(to)
            inDegree[to, default: 0] += 1
            if inDegree[from] == nil {
                inDegree[from] = 0
            }
        }
        
        var queue = nodes.filter { inDegree[$0] == 0 }.sorted()
        var result: [String] = []
        
        while !queue.isEmpty {
            let node = queue.removeFirst()
            result.append(node)
            
            for neighbor in adjacency[node, default: []] {
                inDegree[neighbor]! -= 1
                if inDegree[neighbor] == 0 {
                    queue.append(neighbor)
                    queue.sort()
                }
            }
        }
        
        if result.count != nodes.count {
            return ExecResult.failure("tsort: input contains a loop")
        }
        
        return ExecResult.success(result.joined(separator: "\n") + "\n")
    }
}

// MARK: - tty (print terminal name)

func tty() -> AnyBashCommand {
    AnyBashCommand(name: "tty") { args, ctx in
        var silent = false
        
        for arg in args {
            switch arg {
            case "-s", "--silent", "--quiet":
                silent = true
            case "--help":
                return ExecResult.success("""
                tty [options]
                  Print file name of terminal stdin
                  -s, --silent, --quiet   print nothing, only return exit status
                  --help                  show help
                """)
            default:
                break
            }
        }
        
        // In sandbox, always return /dev/ttys000 (typical macOS terminal)
        if !silent {
            return ExecResult.success("/dev/ttys000\n")
        }
        
        return ExecResult.success()
    }
}

// MARK: - pathchk (check path portability)

func pathchk() -> AnyBashCommand {
    AnyBashCommand(name: "pathchk") { args, ctx in
        var checkPOSIX = false
        var checkPortable = false
        var paths: [String] = []
        
        for arg in args {
            switch arg {
            case "-p":
                checkPOSIX = true
            case "-P":
                checkPortable = true
            case "--help":
                return ExecResult.success("""
                pathchk [options] path...
                  -p      check for POSIX portability
                  -P      check for portability to all POSIX systems
                  --help  show help
                """)
            default:
                if !arg.hasPrefix("-") {
                    paths.append(arg)
                }
            }
        }
        
        guard !paths.isEmpty else {
            return ExecResult.failure("pathchk: missing operand")
        }
        
        for path in paths {
            // Check for empty path
            if path.isEmpty {
                return ExecResult.failure("pathchk: empty path")
            }
            
            // Check for leading hyphen
            if path.hasPrefix("-") {
                return ExecResult.failure("pathchk: path '\(path)' starts with '-'")
            }
            
            // Check length (typical max 255 for filename, 4096 for path)
            if path.count > 4096 {
                return ExecResult.failure("pathchk: path '\(path)' exceeds maximum length")
            }
            
            // Check for non-portable characters
            if checkPOSIX || checkPortable {
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "./_-"))
                if !path.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
                    return ExecResult.failure("pathchk: path '\(path)' contains non-portable character")
                }
            }
        }
        
        return ExecResult.success()
    }
}

// MARK: - jot (sequential data generator - BSD/macOS)

func jot() -> AnyBashCommand {
    AnyBashCommand(name: "jot") { args, ctx in
        var reps: Int?
        var begin: Double?
        var end: Double?
        var step: Double?
        var format = "%g"
        var random = false
        var wordList: [String]?
        var separator = "\n"
        
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-r", "--random":
                random = true
            case "-c":
                separator = ""
            case "-s":
                index += 1
                if index < args.count {
                    separator = args[index].replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t")
                }
            case "-b":
                index += 1
                if index < args.count {
                    wordList = args[index].components(separatedBy: " ")
                }
            case "-w":
                index += 1
                if index < args.count {
                    format = args[index]
                }
            case "--help":
                return ExecResult.success("""
                jot [options] [reps [begin [end [s]]]]
                  Print sequential or random data
                  -r, --random   random data
                  -c             no separator
                  -s string      separator string
                  -b wordlist    word list
                  -w format      format string
                  --help         show help
                """)
            default:
                if !arg.hasPrefix("-") {
                    // Parse positional arguments
                    if reps == nil {
                        reps = Int(arg)
                    } else if begin == nil {
                        begin = Double(arg)
                    } else if end == nil {
                        end = Double(arg)
                    } else if step == nil {
                        step = Double(arg)
                    }
                }
            }
            index += 1
        }
        
        // Set defaults
        let actualReps = reps ?? 100
        let actualBegin = begin ?? 1
        let actualEnd = end ?? actualBegin + Double(actualReps) - 1
        let actualStep = step ?? ((actualEnd - actualBegin) / Double(actualReps - 1))
        
        var results: [String] = []
        
        if let words = wordList {
            // Word list mode
            if random {
                for _ in 0..<actualReps {
                    if let word = words.randomElement() {
                        results.append(word)
                    }
                }
            } else {
                for i in 0..<actualReps {
                    results.append(words[i % words.count])
                }
            }
        } else {
            // Number mode
            if random {
                for _ in 0..<actualReps {
                    let value = Double.random(in: min(actualBegin, actualEnd)...max(actualBegin, actualEnd))
                    results.append(String(format: format, value))
                }
            } else {
                var current = actualBegin
                for _ in 0..<actualReps {
                    results.append(String(format: format, current))
                    current += actualStep
                }
            }
        }
        
        return ExecResult.success(results.joined(separator: separator) + (separator == "\n" ? "" : "\n"))
    }
}
