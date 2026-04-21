import Foundation
import JustBashFS

// MARK: - which

func which() -> AnyBashCommand {
    AnyBashCommand(name: "which") { args, ctx in
        var allPaths = false
        var skipAliases = false
        var skipFunctions = false
        var skipBuiltins = false
        var showPath = false
        var commandNames: [String] = []
        
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-a", "--all":
                allPaths = true
            case "--skip-alias":
                skipAliases = true
            case "--skip-functions":
                skipFunctions = true
            case "--skip-builtins":
                skipBuiltins = true
            case "--show-path":
                showPath = true
            case "--help":
                return ExecResult.success("""
                which [options] command [...]
                  -a, --all           print all matches, not just the first
                  --skip-alias        skip alias lookup
                  --skip-functions    skip function lookup
                  --skip-builtins     skip builtin lookup
                  --show-path         print paths where lookups happen
                  --help              show help
                """)
            default:
                if !arg.hasPrefix("-") {
                    commandNames.append(arg)
                }
            }
            index += 1
        }
        
        guard !commandNames.isEmpty else {
            return ExecResult.failure("which: no command specified")
        }
        
        if showPath {
            let path = ctx.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
            return ExecResult.success(path.split(separator: ":").map { String($0) }.joined(separator: "\n") + "\n")
        }
        
        var results: [String] = []
        
        for name in commandNames {
            var found = false
            var matches: [String] = []
            
            // Check PATH only - we don't have access to registry or session in CommandContext
            let path = ctx.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
            for dir in path.split(separator: ":") {
                let fullPath = "\(dir)/\(name)"
                if ctx.fileSystem.fileExists(path: fullPath, relativeTo: ctx.cwd) {
                    matches.append(fullPath)
                    if !allPaths {
                        break
                    }
                }
            }
            
            if matches.isEmpty {
                results.append("which: no \(name) in (\(path.split(separator: ":").map { String($0) }.joined(separator: " "))")
            } else {
                results.append(contentsOf: matches)
            }
        }
        
        let exitCode = results.contains(where: { $0.hasPrefix("which: no") }) ? 1 : 0
        return ExecResult(stdout: results.joined(separator: "\n") + "\n", stderr: "", exitCode: exitCode)
    }
}

// MARK: - whereis

func whereis() -> AnyBashCommand {
    AnyBashCommand(name: "whereis") { args, ctx in
        var searchBin = true
        var searchMan = true
        var searchSource = false
        var commandNames: [String] = []
        
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-b":
                searchBin = true
                searchMan = false
                searchSource = false
            case "-m":
                searchBin = false
                searchMan = true
                searchSource = false
            case "-s":
                searchBin = false
                searchMan = false
                searchSource = true
            case "-B":
                // Skip next arg (binary path list)
                index += 1
            case "-M":
                // Skip next arg (man path list)
                index += 1
            case "-S":
                // Skip next arg (source path list)
                index += 1
            case "--help":
                return ExecResult.success("""
                whereis [options] name [...]
                  -b        search only for binaries
                  -m        search only for manuals
                  -s        search only for sources
                  --help    show help
                """)
            default:
                if !arg.hasPrefix("-") {
                    commandNames.append(arg)
                }
            }
            index += 1
        }
        
        guard !commandNames.isEmpty else {
            return ExecResult.failure("whereis: insufficient arguments")
        }
        
        var results: [String] = []
        
        for name in commandNames {
            var paths: [String] = []
            
            if searchBin {
                let binPaths = ["/usr/local/bin", "/usr/bin", "/bin", "/sbin", "/usr/sbin"]
                for dir in binPaths {
                    let fullPath = "\(dir)/\(name)"
                    if ctx.fileSystem.fileExists(path: fullPath, relativeTo: ctx.cwd) {
                        paths.append(fullPath)
                    }
                }
            }
            
            if searchMan {
                let manPaths = ["/usr/local/share/man", "/usr/share/man"]
                for section in [1, 2, 3, 4, 5, 6, 7, 8] {
                    for dir in manPaths {
                        let manPath = "\(dir)/man\(section)/\(name).\(section)"
                        let gzPath = "\(manPath).gz"
                        if ctx.fileSystem.fileExists(path: manPath, relativeTo: ctx.cwd) {
                            paths.append(manPath)
                        } else if ctx.fileSystem.fileExists(path: gzPath, relativeTo: ctx.cwd) {
                            paths.append(gzPath)
                        }
                    }
                }
            }
            
            if paths.isEmpty {
                results.append("\(name):")
            } else {
                results.append("\(name): \(paths.joined(separator: " "))")
            }
        }
        
        return ExecResult.success(results.joined(separator: "\n") + "\n")
    }
}

// MARK: - df (disk free)

func df() -> AnyBashCommand {
    AnyBashCommand(name: "df") { args, ctx in
        var humanReadable = false
        var showType = false
        var showAll = false
        
        for arg in args {
            switch arg {
            case "-h", "--human-readable":
                humanReadable = true
            case "-T", "--print-type":
                showType = true
            case "-a", "--all":
                showAll = true
            case "--help":
                return ExecResult.success("""
                df [options] [file...]
                  -h, --human-readable  print sizes in human readable format
                  -T, --print-type       print file system type
                  -a, --all              include dummy file systems
                  --help                 show help
                """)
            default:
                if !arg.hasPrefix("-") {
                    // Check specific path
                    let path = arg.hasPrefix("/") ? arg : "\(ctx.cwd)/\(arg)"
                    if !ctx.fileSystem.fileExists(path: path, relativeTo: ctx.cwd) {
                        return ExecResult.failure("df: \(arg): No such file or directory")
                    }
                }
            }
        }
        
        // Simulated filesystem information
        let filesystems = [
            ("/dev/root", "ext4", "/", 1000000000, 600000000, 400000000),
            ("/dev/sda1", "ext4", "/home", 500000000, 300000000, 200000000),
            ("tmpfs", "tmpfs", "/tmp", 10000000, 5000000, 5000000),
        ]
        
        var lines: [String] = []
        
        // Header
        if showType {
            lines.append("Filesystem     Type     1K-blocks     Used Available Use% Mounted on")
        } else {
            lines.append("Filesystem     1K-blocks     Used Available Use% Mounted on")
        }
        
        for (device, type, mount, total, used, available) in filesystems {
            let percent = Int((Double(used) / Double(total)) * 100)
            
            let sizeStr: String
            let usedStr: String
            let availStr: String
            
            if humanReadable {
                sizeStr = formatBytes(total)
                usedStr = formatBytes(used)
                availStr = formatBytes(available)
            } else {
                sizeStr = String(total / 1024)
                usedStr = String(used / 1024)
                availStr = String(available / 1024)
            }
            
            if showType {
                lines.append(String(format: "%-14s %-8s %10s %8s %9s %3d%% %s",
                    device as NSString, type as NSString, sizeStr as NSString, usedStr as NSString, availStr as NSString, percent, mount as NSString))
            } else {
                lines.append(String(format: "%-14s %10s %8s %9s %3d%% %s",
                    device as NSString, sizeStr as NSString, usedStr as NSString, availStr as NSString, percent, mount as NSString))
            }
        }
        
        return ExecResult.success(lines.joined(separator: "\n") + "\n")
    }
}

// MARK: - free

func free() -> AnyBashCommand {
    AnyBashCommand(name: "free") { args, ctx in
        var humanReadable = false
        var showTotal = false
        
        for arg in args {
            switch arg {
            case "-h", "--human":
                humanReadable = true
            case "-t", "--total":
                showTotal = true
            case "--help":
                return ExecResult.success("""
                free [options]
                  -h, --human    show human-readable output
                  -t, --total    show total line
                  --help         show help
                """)
            default:
                break
            }
        }
        
        // Simulated memory information (in KB)
        let total = 16384000  // ~16GB
        let used = 8192000    // ~8GB used
        let free = total - used
        let shared = 1024000
        let buffCache = 2048000
        let available = free + buffCache
        
        var lines: [String] = []
        lines.append("              total        used        free      shared  buff/cache   available")
        
        let format: (Int) -> String = { bytes in
            humanReadable ? formatBytes(bytes * 1024) : String(bytes)
        }
        
        lines.append(String(format: "%7s %11s %11s %11s %11s %11s %11s",
            "Mem:" as NSString, format(total) as NSString, format(used) as NSString, format(free) as NSString, format(shared) as NSString, format(buffCache) as NSString, format(available) as NSString))
        
        // Swap (simulated)
        let swapTotal = 4194304  // ~4GB
        let swapUsed = 0
        let swapFree = swapTotal
        
        lines.append(String(format: "%7s %11s %11s %11s",
            "Swap:" as NSString, format(swapTotal) as NSString, format(swapUsed) as NSString, format(swapFree) as NSString))
        
        if showTotal {
            lines.append(String(format: "%7s %11s %11s %11s",
                "Total:" as NSString, format(total + swapTotal) as NSString, format(used + swapUsed) as NSString, format(free + swapFree) as NSString))
        }
        
        return ExecResult.success(lines.joined(separator: "\n") + "\n")
    }
}

// MARK: - uptime

func uptime() -> AnyBashCommand {
    AnyBashCommand(name: "uptime") { args, ctx in
        for arg in args {
            if arg == "--help" {
                return ExecResult.success("uptime - show system uptime")
            }
        }
        
        let now = Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: now)
        let timeStr = String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
        
        // Simulated uptime
        let uptimeStr = "5 days, 3:42"
        let userCount = 1
        let loadAvg = "0.52, 0.58, 0.59"
        
        let output = " \(timeStr) up \(uptimeStr), \(userCount) user,  load average: \(loadAvg)\n"
        
        return ExecResult.success(output)
    }
}

// MARK: - ps

func ps() -> AnyBashCommand {
    AnyBashCommand(name: "ps") { args, ctx in
        var showAll = false
        var showAux = false
        var formatUserDefined = false
        var selectUser: String?
        
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-e", "-A":
                showAll = true
            case "a":
                showAll = true
            case "u":
                formatUserDefined = true
            case "x":
                break // Include processes without controlling terminal
            case "-au", "-aux", "aux":
                showAux = true
            case "-U", "--User":
                index += 1
                if index < args.count {
                    selectUser = args[index]
                }
            case "--help":
                return ExecResult.success("""
                ps [options]
                  -e, -A          select all processes
                  a               show processes for all users
                  u               display user-oriented format
                  x               include processes without TTY
                  aux             BSD-style full list
                  --help          show help
                """)
            default:
                break
            }
            index += 1
        }
        
        // Simulated process list
        let processes = [
            (1, "root", "0.0", "0.1", "1234", "2345", "Ss", "?", "00:00:01", "init"),
            (100, "user", "0.5", "1.2", "5678", "6789", "Ss", "pts/0", "00:00:05", "bash"),
            (101, "user", "0.0", "0.5", "7890", "8901", "R+", "pts/0", "00:00:00", "ps aux"),
            (500, "root", "0.1", "0.8", "3456", "4567", "Ss", "?", "00:00:02", "sshd"),
        ]
        
        var lines: [String] = []
        
        if formatUserDefined || showAux {
            lines.append("USER       PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND")
            for (pid, user, cpu, mem, vsz, rss, stat, tty, time, cmd) in processes {
                if selectUser == nil || user == selectUser {
                    lines.append(String(format: "%-10s %4d %4s %4s %5s %5s %-8s %4s 00:00 %4s %s",
                        user, pid, cpu, mem, String(vsz), String(rss), tty, stat, time, cmd as NSString))
                }
            }
        } else {
            lines.append("  PID TTY          TIME CMD")
            for (pid, _, _, _, _, _, _, tty, time, cmd) in processes {
                lines.append(String(format: "%5d %-8s %4s %s",
                    pid, tty, time, cmd as NSString))
            }
        }
        
        return ExecResult.success(lines.joined(separator: "\n") + "\n")
    }
}

// MARK: - uname

// uname is already defined in MiscCommands.swift, but let's extend it
// Actually, let's create kill and killall instead

// MARK: - kill

func kill() -> AnyBashCommand {
    AnyBashCommand(name: "kill") { args, ctx in
        var signal: Int32 = 15 // SIGTERM
        var listSignals = false
        var pids: [Int] = []
        
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "-l" || arg == "--list" {
                listSignals = true
            } else if arg == "-h" || arg == "--help" {
                return ExecResult.success("""
                kill [options] <pid> [...]
                  -l, --list       list signal names
                  -s <signal>       specify signal
                  -<signal>          specify signal by number or name
                  --help            show help
                """)
            } else if arg.hasPrefix("-") {
                // Signal specification
                let sigSpec = String(arg.dropFirst())
                if let sigNum = Int32(sigSpec) {
                    signal = sigNum
                } else {
                    // Try signal name
                    switch sigSpec.uppercased() {
                    case "HUP", "1": signal = 1
                    case "INT", "2": signal = 2
                    case "QUIT", "3": signal = 3
                    case "ILL", "4": signal = 4
                    case "TRAP", "5": signal = 5
                    case "ABRT", "6": signal = 6
                    case "BUS", "7": signal = 7
                    case "FPE", "8": signal = 8
                    case "KILL", "9": signal = 9
                    case "USR1", "10": signal = 10
                    case "SEGV", "11": signal = 11
                    case "USR2", "12": signal = 12
                    case "PIPE", "13": signal = 13
                    case "ALRM", "14": signal = 14
                    case "TERM", "15": signal = 15
                    case "CHLD", "17": signal = 17
                    case "CONT", "18": signal = 18
                    case "STOP", "19": signal = 19
                    case "TSTP", "20": signal = 20
                    case "TTIN", "21": signal = 21
                    case "TTOU", "22": signal = 22
                    default: break
                    }
                }
            } else if let pid = Int(arg) {
                pids.append(pid)
            }
            index += 1
        }
        
        if listSignals {
            let signals = [
                "1) SIGHUP       2) SIGINT       3) SIGQUIT      4) SIGILL",
                "5) SIGTRAP      6) SIGABRT      7) SIGBUS       8) SIGFPE",
                "9) SIGKILL     10) SIGUSR1    11) SIGSEGV     12) SIGUSR2",
                "13) SIGPIPE    14) SIGALRM    15) SIGTERM     16) SIGSTKFLT",
                "17) SIGCHLD    18) SIGCONT    19) SIGSTOP     20) SIGTSTP",
                "21) SIGTTIN    22) SIGTTOU    23) SIGURG      24) SIGXCPU",
                "25) SIGXFSZ    26) SIGVTALRM  27) SIGPROF     28) SIGWINCH",
                "29) SIGIO      30) SIGPWR     31) SIGSYS",
            ]
            return ExecResult.success(signals.joined(separator: "\n") + "\n")
        }
        
        guard !pids.isEmpty else {
            return ExecResult.failure("kill: usage: kill [-s sigspec | -n signum | -sigspec] pid | jobspec ... or kill -l [sigspec]")
        }
        
        // In sandbox, we simulate kill
        // Real implementation would send signals to processes
        for pid in pids {
            // Simulate kill - in real implementation this would send the signal
            // For now, we just succeed for common PIDs and fail for non-existent ones
            if pid <= 0 {
                return ExecResult.failure("kill: (\(pid)) - No such process")
            }
        }
        
        return ExecResult.success()
    }
}

// MARK: - killall

func killall() -> AnyBashCommand {
    AnyBashCommand(name: "killall") { args, ctx in
        var signal: Int32 = 15 // SIGTERM
        var interactive = false
        var quiet = false
        var exactMatch = false
        var processNames: [String] = []
        
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-h", "--help":
                return ExecResult.success("""
                killall [options] <name> [...]
                  -<signal>        send specific signal
                  -i, --interactive  ask for confirmation
                  -q, --quiet       don't print warnings
                  -e, --exact       require exact match
                  --help            show help
                """)
            case "-i", "--interactive":
                interactive = true
            case "-q", "--quiet":
                quiet = true
            case "-e", "--exact":
                exactMatch = true
            default:
                if arg.hasPrefix("-") {
                    // Signal specification
                    let sigSpec = String(arg.dropFirst())
                    if let sigNum = Int32(sigSpec) {
                        signal = sigNum
                    } else {
                        // Map signal names to numbers
                        switch sigSpec.uppercased() {
                        case "HUP": signal = 1
                        case "INT": signal = 2
                        case "KILL": signal = 9
                        case "TERM": signal = 15
                        default: break
                        }
                    }
                } else {
                    processNames.append(arg)
                }
            }
            index += 1
        }
        
        guard !processNames.isEmpty else {
            return ExecResult.failure("killall: missing process name")
        }
        
        // In sandbox, simulate killall
        // Check if any processes match (from our simulated ps list)
        let knownProcesses = ["init", "bash", "ps", "sshd"]
        var killed = 0
        var notFound: [String] = []
        
        for name in processNames {
            let matched = exactMatch
                ? knownProcesses.contains(name)
                : knownProcesses.contains(where: { $0.contains(name) || name.contains($0) })
            
            if matched {
                killed += 1
            } else {
                notFound.append(name)
            }
        }
        
        if !notFound.isEmpty && !quiet {
            return ExecResult(stderr: "killall: no process found for: \(notFound.joined(separator: ", "))", exitCode: killed > 0 ? 0 : 1)
        }
        
        return ExecResult.success()
    }
}

// MARK: - Helper functions

private func formatBytes(_ bytes: Int) -> String {
    let units = ["B", "K", "M", "G", "T", "P"]
    var size = Double(bytes)
    var unitIndex = 0
    
    while size >= 1024.0 && unitIndex < units.count - 1 {
        size /= 1024.0
        unitIndex += 1
    }
    
    if unitIndex == 0 {
        return String(format: "%d%@", Int(size), units[unitIndex] as NSString)
    } else {
        return String(format: "%.1f%@", size, units[unitIndex] as NSString)
    }
}
