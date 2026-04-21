import Foundation
import JustBashFS

// MARK: - shuf (shuffle lines)

func shuf() -> AnyBashCommand {
    AnyBashCommand(name: "shuf") { args, ctx in
        var inputRange: ClosedRange<Int>?
        var headCount: Int?
        var repeatMode = false
        var outputFile: String?
        var inputFile: String?
        var useStdin = true
        
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-i", "--input-range":
                index += 1
                if index < args.count {
                    let parts = args[index].split(separator: "-").compactMap { Int($0) }
                    if parts.count == 2 {
                        inputRange = parts[0]...parts[1]
                    }
                }
            case "-n", "--head-count":
                index += 1
                if index < args.count {
                    headCount = Int(args[index])
                }
            case "-r", "--repeat":
                repeatMode = true
            case "-o", "--output":
                index += 1
                if index < args.count {
                    outputFile = args[index]
                }
            case "--random-source":
                index += 1 // Skip random source file
            case "--help":
                return ExecResult.success("""
                shuf [options] [file]
                  -i, --input-range LO-HI   treat numbers LO through HI as input
                  -n, --head-count COUNT    output at most COUNT lines
                  -r, --repeat             repeat mode (with -n)
                  -o, --output FILE        write to FILE
                  --help                   show help
                """)
            default:
                if !arg.hasPrefix("-") {
                    inputFile = arg
                    useStdin = false
                }
            }
            index += 1
        }
        
        let lines: [String]
        
        if let range = inputRange {
            lines = Array(range).map { String($0) }
        } else {
            let input: String
            do {
                if useStdin {
                    input = ctx.stdin
                } else if let path = inputFile {
                    let data = try ctx.fileSystem.readFile(path: path, relativeTo: ctx.cwd)
                    input = String(decoding: data, as: UTF8.self)
                } else {
                    input = ""
                }
            } catch {
                return ExecResult.failure("shuf: \(error.localizedDescription)")
            }
            lines = input.components(separatedBy: .newlines).filter { !$0.isEmpty }
        }
        
        var outputLines: [String]
        
        if repeatMode && headCount != nil {
            // Repeat random selection
            outputLines = (0..<headCount!).map { _ in lines.randomElement() ?? "" }
        } else {
            // Shuffle all lines
            outputLines = lines.shuffled()
            if let count = headCount {
                outputLines = Array(outputLines.prefix(count))
            }
        }
        
        let result = outputLines.joined(separator: "\n") + "\n"
        
        if let outputPath = outputFile {
            do {
                try ctx.fileSystem.writeFile(path: outputPath, content: Data(result.utf8), relativeTo: ctx.cwd)
                return ExecResult.success()
            } catch {
                return ExecResult.failure("shuf: \(error.localizedDescription)")
            }
        }
        
        return ExecResult.success(result)
    }
}

// MARK: - ts (timestamp input)

func ts() -> AnyBashCommand {
    AnyBashCommand(name: "ts") { args, ctx in
        var format = "%b %d %H:%M:%S"
        var relative = false
        var elapsed = false
        var resetOnEmpty = false
        
        for arg in args {
            switch arg {
            case "-r", "--relative":
                relative = true
            case "-s", "--seconds":
                format = "%s"
            case "-i", "--iso-8601":
                format = "%Y-%m-%dT%H:%M:%S"
            case "-e", "--elapsed":
                elapsed = true
            case "-m", "--milli":
                format += ".%N"
            case "--reset-on-empty":
                resetOnEmpty = true
            case "--help":
                return ExecResult.success("""
                ts [options]
                  -r, --relative         show time relative to start
                  -s, --seconds         show seconds since epoch
                  -i, --iso-8601        ISO 8601 timestamp
                  -e, --elapsed         show elapsed time between lines
                  -m, --milli            include milliseconds
                  --help                 show help
                """)
            default:
                if !arg.hasPrefix("-") {
                    format = arg
                }
            }
        }
        
        let lines = ctx.stdin.components(separatedBy: .newlines)
        var result: [String] = []
        let startTime = Date()
        var lastTime = startTime
        
        let formatter = DateFormatter()
        formatter.dateFormat = format
        
        for line in lines {
            let now = Date()
            let timestamp: String
            
            if relative {
                let diff = now.timeIntervalSince(startTime)
                timestamp = String(format: "%.3f", diff)
            } else if elapsed {
                let diff = now.timeIntervalSince(lastTime)
                timestamp = String(format: "+%.3f", diff)
                lastTime = now
            } else {
                timestamp = formatter.string(from: now)
            }
            
            result.append("\(timestamp) \(line)")
            
            if line.isEmpty && resetOnEmpty {
                lastTime = Date()
            }
        }
        
        return ExecResult.success(result.joined(separator: "\n") + "\n")
    }
}

// MARK: - sponge (soak up input, write to file)

func sponge() -> AnyBashCommand {
    AnyBashCommand(name: "sponge") { args, ctx in
        var append = false
        var outputFile: String?
        
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-a", "--append":
                append = true
            case "--help":
                return ExecResult.success("""
                sponge [options] file
                  Soak up input and write to file atomically
                  -a, --append    append to file
                  --help          show help
                """)
            default:
                if !arg.hasPrefix("-") {
                    outputFile = arg
                }
            }
            index += 1
        }
        
        guard let path = outputFile else {
            return ExecResult.failure("sponge: missing file argument")
        }
        
        let input = Data(ctx.stdin.utf8)
        
        do {
            if append {
                // Read existing and append
                var existing = Data()
                if ctx.fileSystem.fileExists(path: path, relativeTo: ctx.cwd) {
                    existing = try ctx.fileSystem.readFile(path: path, relativeTo: ctx.cwd)
                }
                existing.append(input)
                try ctx.fileSystem.writeFile(path: path, content: existing, relativeTo: ctx.cwd)
            } else {
                try ctx.fileSystem.writeFile(path: path, content: input, relativeTo: ctx.cwd)
            }
            return ExecResult.success()
        } catch {
            return ExecResult.failure("sponge: \(error.localizedDescription)")
        }
    }
}

// MARK: - vidir (edit directory in $EDITOR)

func vidir() -> AnyBashCommand {
    AnyBashCommand(name: "vidir") { args, ctx in
        var filePaths: [String] = []
        
        for arg in args {
            if arg == "--help" {
                return ExecResult.success("""
                vidir [directory|file|-]
                  Edit directory or files in $EDITOR
                """)
            } else if !arg.hasPrefix("-") {
                filePaths.append(arg)
            }
        }
        
        // In sandbox mode, we just list what would be edited
        let target = filePaths.first ?? ctx.cwd
        
        do {
            let allEntries = try ctx.fileSystem.listDirectory(path: target, relativeTo: ctx.cwd)
            let entries = allEntries.filter { !$0.hasPrefix(".") }
            var lines: [String] = []

            for (index, entry) in entries.enumerated() {
                lines.append(String(format: "%5d  %@", index + 1, entry))
            }
            
            // Note: In real implementation, this would open $EDITOR
            // In sandbox, we just show the list
            return ExecResult.success("""
            # Would open in $EDITOR: (vidir simulation in sandbox)
            # Format: <index>  <filename>
            # Rename by editing the filename after the number
            # Remove lines to delete files
            # Save and exit to apply changes
            
            \(lines.joined(separator: "\n"))
            """)
        } catch {
            return ExecResult.failure("vidir: \(error.localizedDescription)")
        }
    }
}

// MARK: - vipe (edit pipe in $EDITOR)

func vipe() -> AnyBashCommand {
    AnyBashCommand(name: "vipe") { args, ctx in
        for arg in args {
            if arg == "--help" {
                return ExecResult.success("""
                vipe
                  Edit stdin in $EDITOR and send to stdout
                """)
            }
        }
        
        // In sandbox mode, we just pass through
        // In real implementation, this would:
        // 1. Read stdin to temp file
        // 2. Open $EDITOR on temp file
        // 3. Read temp file after editor exits
        // 4. Output to stdout
        
        return ExecResult.success(ctx.stdin)
    }
}

// MARK: - pee (tee but for pipes)

func pee() -> AnyBashCommand {
    AnyBashCommand(name: "pee") { args, ctx in
        var ignoreWriteErrors = false
        var commands: [String] = []
        
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--ignore-sigpipe":
                ignoreWriteErrors = true
            case "--help":
                return ExecResult.success("""
                pee [options] command...
                  Like tee but for pipes - send stdin to multiple commands
                """)
            default:
                if !arg.hasPrefix("-") {
                    commands.append(arg)
                }
            }
            index += 1
        }
        
        guard !commands.isEmpty else {
            return ExecResult.failure("pee: missing command argument")
        }
        
        // In sandbox mode, we simulate by showing what would happen
        // In real implementation, this would spawn multiple processes
        // and send stdin to all of them
        
        var output = "# pee simulation:\n"
        output += "# Input would be sent to:\n"
        for (i, cmd) in commands.enumerated() {
            output += "#   [\(i + 1)] \(cmd)\n"
        }
        output += "# First command output:\n"
        
        if let firstCmd = commands.first, let execute = ctx.executeSubshell {
            let result = await execute(firstCmd)
            output += result.stdout
        }
        
        return ExecResult.success(output)
    }
}

// MARK: - combine (combine lines from multiple files)

func combine() -> AnyBashCommand {
    AnyBashCommand(name: "combine") { args, ctx in
        var operation = "and"
        var filePaths: [String] = []
        
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "and", "or", "not", "xor":
                operation = arg
            case "--help":
                return ExecResult.success("""
                combine [operation] file1 file2
                  Perform set operations on lines of files
                  and - intersection
                  or  - union
                  not - difference
                  xor - symmetric difference
                """)
            default:
                if !arg.hasPrefix("-") {
                    filePaths.append(arg)
                }
            }
            index += 1
        }
        
        guard filePaths.count >= 2 else {
            return ExecResult.failure("combine: requires at least 2 files")
        }
        
        do {
            let data1 = try ctx.fileSystem.readFile(path: filePaths[0], relativeTo: ctx.cwd)
            let data2 = try ctx.fileSystem.readFile(path: filePaths[1], relativeTo: ctx.cwd)
            
            let lines1 = Set(String(decoding: data1, as: UTF8.self).components(separatedBy: .newlines).filter { !$0.isEmpty })
            let lines2 = Set(String(decoding: data2, as: UTF8.self).components(separatedBy: .newlines).filter { !$0.isEmpty })
            
            let result: Set<String>
            switch operation {
            case "and":
                result = lines1.intersection(lines2)
            case "or":
                result = lines1.union(lines2)
            case "not":
                result = lines1.subtracting(lines2)
            case "xor":
                result = lines1.symmetricDifference(lines2)
            default:
                result = lines1.intersection(lines2)
            }
            
            return ExecResult.success(result.sorted().joined(separator: "\n") + "\n")
        } catch {
            return ExecResult.failure("combine: \(error.localizedDescription)")
        }
    }
}

// MARK: - ifdata (check interface data availability)

func ifdata() -> AnyBashCommand {
    AnyBashCommand(name: "ifdata") { args, ctx in
        var queries: [String] = []
        var interfaceName: String?
        
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-pa":
                queries.append("exists")
            case "-pN":
                queries.append("ip")
            case "-pn":
                queries.append("netmask")
            case "-pM":
                queries.append("broadcast")
            case "-pP":
                queries.append("prefix")
            case "--help":
                return ExecResult.success("""
                ifdata [options] iface
                  Check network interface data availability
                  -pa  interface exists
                  -pN  IP address
                  -pn  netmask
                  -pM  broadcast
                  -pP  prefix length
                """)
            default:
                if !arg.hasPrefix("-") {
                    interfaceName = arg
                }
            }
            index += 1
        }
        
        guard let iface = interfaceName else {
            return ExecResult.failure("ifdata: missing interface name")
        }
        
        // Simulated interface data
        let interfaces = [
            "lo0": (ip: "127.0.0.1", netmask: "255.0.0.0", broadcast: "127.255.255.255", prefix: 8),
            "en0": (ip: "192.168.1.100", netmask: "255.255.255.0", broadcast: "192.168.1.255", prefix: 24),
        ]
        
        guard let data = interfaces[iface] else {
            return ExecResult(stderr: "", exitCode: 1)
        }
        
        if queries.isEmpty {
            queries = ["exists"]
        }
        
        var results: [String] = []
        for query in queries {
            switch query {
            case "exists":
                results.append("1")
            case "ip":
                results.append(data.ip)
            case "netmask":
                results.append(data.netmask)
            case "broadcast":
                results.append(data.broadcast)
            case "prefix":
                results.append(String(data.prefix))
            default:
                break
            }
        }
        
        return ExecResult.success(results.joined(separator: "\n") + "\n")
    }
}

// MARK: - chronic (only output on error)

func chronic() -> AnyBashCommand {
    AnyBashCommand(name: "chronic") { args, ctx in
        var verbose = false
        var command: String?
        
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-v", "--verbose":
                verbose = true
            case "--help":
                return ExecResult.success("""
                chronic [options] command...
                  Run command, hide output unless it fails
                  -v, --verbose    always show output
                  --help           show help
                """)
            default:
                if !arg.hasPrefix("-") && command == nil {
                    command = arg
                }
            }
            index += 1
        }
        
        guard let cmd = command, let execute = ctx.executeSubshell else {
            return ExecResult.failure("chronic: missing command")
        }
        
        let result = await execute(cmd)
        
        if result.exitCode != 0 || verbose {
            return result
        }
        
        return ExecResult.success()
    }
}

// MARK: - errno (lookup error codes)

func errno() -> AnyBashCommand {
    AnyBashCommand(name: "errno") { args, ctx in
        var listAll = false
        var searchTerms: [String] = []
        
        let errorCodes: [(code: Int, name: String, desc: String)] = [
            (1, "EPERM", "Operation not permitted"),
            (2, "ENOENT", "No such file or directory"),
            (3, "ESRCH", "No such process"),
            (4, "EINTR", "Interrupted system call"),
            (5, "EIO", "I/O error"),
            (6, "ENXIO", "No such device or address"),
            (7, "E2BIG", "Argument list too long"),
            (8, "ENOEXEC", "Exec format error"),
            (9, "EBADF", "Bad file number"),
            (10, "ECHILD", "No child processes"),
            (11, "EAGAIN", "Try again"),
            (12, "ENOMEM", "Out of memory"),
            (13, "EACCES", "Permission denied"),
            (14, "EFAULT", "Bad address"),
            (15, "ENOTBLK", "Block device required"),
            (16, "EBUSY", "Device or resource busy"),
            (17, "EEXIST", "File exists"),
            (18, "EXDEV", "Cross-device link"),
            (19, "ENODEV", "No such device"),
            (20, "ENOTDIR", "Not a directory"),
            (21, "EISDIR", "Is a directory"),
            (22, "EINVAL", "Invalid argument"),
            (23, "ENFILE", "File table overflow"),
            (24, "EMFILE", "Too many open files"),
            (25, "ENOTTY", "Not a typewriter"),
            (26, "ETXTBSY", "Text file busy"),
            (27, "EFBIG", "File too large"),
            (28, "ENOSPC", "No space left on device"),
            (29, "ESPIPE", "Illegal seek"),
            (30, "EROFS", "Read-only file system"),
            (31, "EMLINK", "Too many links"),
            (32, "EPIPE", "Broken pipe"),
        ]
        
        for arg in args {
            switch arg {
            case "-l", "--list":
                listAll = true
            case "--help":
                return ExecResult.success("""
                errno [options] name_or_code...
                  Look up errno name or code
                  -l, --list    list all errno values
                  --help        show help
                """)
            default:
                if !arg.hasPrefix("-") {
                    searchTerms.append(arg)
                }
            }
        }
        
        if listAll {
            let lines = errorCodes.map { code, name, desc in
                "\(code) \(name) \(desc)"
            }
            return ExecResult.success(lines.joined(separator: "\n") + "\n")
        }
        
        guard !searchTerms.isEmpty else {
            return ExecResult.failure("errno: missing operand")
        }
        
        var results: [String] = []
        
        for term in searchTerms {
            if let code = Int(term) {
                // Search by code
                if let match = errorCodes.first(where: { $0.code == code }) {
                    results.append("\(match.code) \(match.name) \(match.desc)")
                } else {
                    results.append("errno: unknown error code \(code)")
                }
            } else {
                // Search by name
                let upperTerm = term.uppercased()
                if let match = errorCodes.first(where: { $0.name == upperTerm }) {
                    results.append("\(match.code) \(match.name) \(match.desc)")
                } else {
                    // Try partial match
                    let matches = errorCodes.filter { $0.name.contains(upperTerm) || $0.desc.lowercased().contains(term.lowercased()) }
                    if matches.count == 1 {
                        results.append("\(matches[0].code) \(matches[0].name) \(matches[0].desc)")
                    } else if matches.count > 1 {
                        for match in matches {
                            results.append("\(match.code) \(match.name) \(match.desc)")
                        }
                    } else {
                        results.append("errno: unknown error name \(term)")
                    }
                }
            }
        }
        
        return ExecResult.success(results.joined(separator: "\n") + "\n")
    }
}
