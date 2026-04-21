import Foundation
import JustBashCommands
import JustBashFS

extension ShellInterpreter {

    // MARK: - Shell Builtins

    typealias BuiltinFn = ([String], inout ShellSession, [String: String], String) async throws -> ExecResult

    func shellBuiltin(_ name: String) -> BuiltinFn? {
        switch name {
        case "cd": return builtinCd
        case "pwd": return builtinPwd
        case "echo": return builtinEcho
        case "printf": return builtinPrintf
        case "env": return builtinEnv
        case "printenv": return builtinPrintenv
        case "which", "type": return builtinWhich
        case "true": return { _, _, _, _ in ExecResult.success() }
        case "false": return { _, _, _, _ in ExecResult(stdout: "", stderr: "", exitCode: 1) }
        case "export": return builtinExport
        case "unset": return builtinUnset
        case "local": return builtinLocal
        case "declare", "typeset": return builtinDeclare
        case "read": return builtinRead
        case "set": return builtinSet
        case "shift": return builtinShift
        case "return": return builtinReturn
        case "exit": return builtinExit
        case "break": return builtinBreak
        case "continue": return builtinContinue
        case "test", "[": return builtinTest
        case "eval": return builtinEval
        case "source", ".": return builtinSource
        case "trap": return builtinTrap
        case "alias": return builtinAlias
        case "unalias": return { args, session, _, _ in args.forEach { session.aliases.removeValue(forKey: $0) }; return .success() }
        case ":": return { _, _, _, _ in ExecResult.success() }
        case "command": return builtinCommand
        case "let": return builtinLet
        case "getopts": return builtinGetopts
        case "mapfile", "readarray": return builtinMapfile
        case "pushd": return builtinPushd
        case "popd": return builtinPopd
        case "dirs": return builtinDirs
        case "builtin": return builtinBuiltin
        case "hash": return builtinHash
        case "exec": return builtinExec
        case "readonly": return builtinReadonly
        case "shopt": return builtinShopt
        case "wait": return { _, _, _, _ in ExecResult.success() }
        case "compgen": return builtinCompgen
        case "complete": return builtinComplete
        case "compopt": return { _, _, _, _ in ExecResult.success() } // no-op in non-interactive
        default: return nil
        }
    }

    // MARK: Builtin implementations

    private func builtinCd(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        let dest: String
        if args.isEmpty || args[0] == "~" {
            dest = env["HOME"] ?? session.getVariable("HOME") ?? "/home/user"
        } else if args[0] == "-" {
            dest = session.getVariable("OLDPWD") ?? session.cwd
        } else {
            dest = args[0]
        }
        let target = VirtualPath.normalize(dest, relativeTo: session.cwd)
        guard fileSystem.isDirectory(target) else {
            return ExecResult.failure("cd: no such directory: \(dest)")
        }
        let old = session.cwd
        session.cwd = target
        session.setVariable("OLDPWD", old)
        session.setVariable("PWD", target)
        return ExecResult.success()
    }

    private func builtinPwd(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        ExecResult.success(session.cwd + "\n")
    }

    private func builtinEcho(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        var items = args
        var newline = true
        var interpretEscapes = false
        while let first = items.first {
            if first == "-n" { newline = false; items.removeFirst() }
            else if first == "-e" { interpretEscapes = true; items.removeFirst() }
            else if first == "-E" { interpretEscapes = false; items.removeFirst() }
            else if first == "-en" || first == "-ne" { newline = false; interpretEscapes = true; items.removeFirst() }
            else { break }
        }
        var output = items.joined(separator: " ")
        if interpretEscapes {
            output = interpretEscapeSequences(output)
        }
        if newline { output += "\n" }
        return ExecResult.success(output)
    }

    private func interpretEscapeSequences(_ s: String) -> String {
        var result = ""
        var chars = s.makeIterator()
        while let ch = chars.next() {
            if ch == "\\" {
                guard let next = chars.next() else { result.append("\\"); break }
                switch next {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "\\": result.append("\\")
                case "a": result.append("\u{07}")
                case "b": result.append("\u{08}")
                case "e", "E": result.append("\u{1B}")
                case "0":
                    var oct = ""
                    for _ in 0..<3 { if let c = chars.next(), "01234567".contains(c) { oct.append(c) } }
                    if let val = UInt32(oct.isEmpty ? "0" : oct, radix: 8), let s = Unicode.Scalar(val) { result.append(Character(s)) }
                default: result.append("\\"); result.append(next)
                }
            } else {
                result.append(ch)
            }
        }
        return result
    }

    private func builtinPrintf(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        var effectiveArgs = args
        var storeVar: String?
        if effectiveArgs.count >= 2, effectiveArgs[0] == "-v" {
            storeVar = effectiveArgs[1]
            effectiveArgs = Array(effectiveArgs.dropFirst(2))
        }
        guard let format = effectiveArgs.first else { return ExecResult.success() }
        var remaining = Array(effectiveArgs.dropFirst())
        var output = ""

        // Repeat format string while arguments remain
        repeat {
            var iter = format.makeIterator()
            var usedArg = false
            while let ch = iter.next() {
                if ch == "%" {
                    // Collect full format spec: %[flags][width][.precision]type
                    var spec = ""
                    var specType: Character = "%"

                    // Parse flags
                    flagLoop: while let next = iter.next() {
                        if "-+ 0#".contains(next) {
                            spec.append(next)
                        } else {
                            // Not a flag – handle width / precision / type
                            if next == "%" {
                                output.append("%")
                                specType = "%"
                                break flagLoop
                            }
                            if next == "*" {
                                let widthArg = remaining.isEmpty ? "0" : remaining.removeFirst()
                                spec.append(widthArg); usedArg = true
                                // After width-from-arg, continue to look for '.' or type
                                if let afterWidth = iter.next() {
                                    if afterWidth == "." {
                                        spec.append(".")
                                        if let p = iter.next() {
                                            if p == "*" {
                                                let precArg = remaining.isEmpty ? "0" : remaining.removeFirst()
                                                spec.append(precArg); usedArg = true
                                                if let t = iter.next() { specType = t }
                                            } else if p.isNumber {
                                                spec.append(p)
                                                while let pd = iter.next() {
                                                    if pd.isNumber { spec.append(pd) }
                                                    else { specType = pd; break }
                                                }
                                            } else {
                                                specType = p
                                            }
                                        }
                                    } else {
                                        specType = afterWidth
                                    }
                                }
                                break flagLoop
                            }
                            if next.isNumber {
                                spec.append(next)
                                // Read remaining width digits
                                while let d = iter.next() {
                                    if d.isNumber { spec.append(d) }
                                    else {
                                        if d == "." {
                                            spec.append(".")
                                            if let p = iter.next() {
                                                if p == "*" {
                                                    let precArg = remaining.isEmpty ? "0" : remaining.removeFirst()
                                                    spec.append(precArg); usedArg = true
                                                    if let t = iter.next() { specType = t }
                                                } else if p.isNumber {
                                                    spec.append(p)
                                                    while let pd = iter.next() {
                                                        if pd.isNumber { spec.append(pd) }
                                                        else { specType = pd; break }
                                                    }
                                                } else {
                                                    specType = p
                                                }
                                            }
                                        } else {
                                            specType = d
                                        }
                                        break
                                    }
                                }
                                break flagLoop
                            }
                            if next == "." {
                                spec.append(".")
                                if let p = iter.next() {
                                    if p == "*" {
                                        let precArg = remaining.isEmpty ? "0" : remaining.removeFirst()
                                        spec.append(precArg); usedArg = true
                                        if let t = iter.next() { specType = t }
                                    } else if p.isNumber {
                                        spec.append(p)
                                        while let pd = iter.next() {
                                            if pd.isNumber { spec.append(pd) }
                                            else { specType = pd; break }
                                        }
                                    } else {
                                        specType = p
                                    }
                                }
                                break flagLoop
                            }
                            // It's the type character directly
                            specType = next
                            break flagLoop
                        }
                    }

                    if specType == "%" { continue }

                    let arg = remaining.isEmpty ? "" : remaining.removeFirst()
                    usedArg = true

                    switch specType {
                    case "s":
                        if spec.isEmpty {
                            output += arg
                        } else {
                            // Manual string padding (Swift String(format:) doesn't work with %s)
                            let leftAlign = spec.hasPrefix("-")
                            let cleanSpec = spec.replacingOccurrences(of: "-", with: "")
                            let parts = cleanSpec.split(separator: ".", maxSplits: 1)
                            let width = parts.first.flatMap { Int($0) } ?? 0
                            let maxLen = parts.count > 1 ? Int(parts[1]) : nil
                            var s = arg
                            if let maxLen { s = String(s.prefix(maxLen)) }
                            if s.count < width {
                                let pad = String(repeating: " ", count: width - s.count)
                                s = leftAlign ? s + pad : pad + s
                            }
                            output += s
                        }
                    case "d", "i":
                        let val = Int(arg) ?? 0
                        output += String(format: "%\(spec)d", val)
                    case "f":
                        let val = Double(arg) ?? 0.0
                        output += String(format: "%\(spec)f", val)
                    case "g":
                        let val = Double(arg) ?? 0.0
                        output += String(format: "%\(spec)g", val)
                    case "e":
                        let val = Double(arg) ?? 0.0
                        output += String(format: "%\(spec)e", val)
                    case "x":
                        let val = Int(arg) ?? 0
                        output += String(format: "%\(spec)x", val)
                    case "X":
                        let val = Int(arg) ?? 0
                        output += String(format: "%\(spec)X", val)
                    case "o":
                        let val = Int(arg) ?? 0
                        output += String(format: "%\(spec)o", val)
                    case "c":
                        output += String(arg.prefix(1))
                    case "b":
                        output += interpretEscapeSequences(arg)
                    case "q":
                        // Shell-quote the argument
                        if arg.isEmpty {
                            output += "''"
                        } else {
                            output += "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
                        }
                    default:
                        output.append("%")
                        output.append(contentsOf: spec)
                        output.append(specType)
                    }
                } else if ch == "\\" {
                    guard let esc = iter.next() else { output.append("\\"); break }
                    switch esc {
                    case "n": output.append("\n")
                    case "t": output.append("\t")
                    case "r": output.append("\r")
                    case "\\": output.append("\\")
                    default: output.append("\\"); output.append(esc)
                    }
                } else {
                    output.append(ch)
                }
            }
            if !usedArg { break }
        } while !remaining.isEmpty

        if let storeVar {
            session.setVariable(storeVar, output)
            return ExecResult.success()
        }
        return ExecResult.success(output)
    }

    private func builtinEnv(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        var cleanEnv = false
        var envOverrides: [(String, String)] = []
        var unsetVars: [String] = []
        var commandArgs: [String] = []
        var i = 0
        while i < args.count {
            if args[i] == "-i" || args[i] == "--ignore-environment" {
                cleanEnv = true
                i += 1
            } else if args[i] == "-u" || args[i] == "--unset" {
                if i + 1 < args.count { unsetVars.append(args[i + 1]); i += 2 }
                else { i += 1 }
            } else if args[i].contains("=") && commandArgs.isEmpty {
                let parts = args[i].split(separator: "=", maxSplits: 1)
                envOverrides.append((String(parts[0]), parts.count > 1 ? String(parts[1]) : ""))
                i += 1
            } else {
                commandArgs = Array(args[i...])
                break
            }
        }

        var effectiveEnv = cleanEnv ? [String: String]() : env
        for v in unsetVars { effectiveEnv.removeValue(forKey: v) }
        for (k, v) in envOverrides { effectiveEnv[k] = v }

        // If no command, print environment
        if commandArgs.isEmpty {
            let rendered = effectiveEnv.keys.sorted().map { "\($0)=\(effectiveEnv[$0] ?? "")" }.joined(separator: "\n")
            return ExecResult.success(rendered + (rendered.isEmpty ? "" : "\n"))
        }

        // Execute command with modified environment
        let cmdName = commandArgs[0]
        let cmdRest = Array(commandArgs.dropFirst())

        // Try external commands first
        if let cmd = registry.command(named: cmdName) {
            let ctx = CommandContext(fileSystem: fileSystem, cwd: session.cwd, environment: effectiveEnv, stdin: stdin)
            return await cmd.execute(cmdRest, ctx)
        }
        // Try builtins
        if let builtin = shellBuiltin(cmdName) {
            return try await builtin(cmdRest, &session, effectiveEnv, stdin)
        }
        return ExecResult.failure("\(cmdName): command not found", exitCode: 127)
    }

    private func builtinPrintenv(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        if args.isEmpty {
            return try await builtinEnv(args, &session, env, stdin)
        }
        let values = args.compactMap { env[$0] }
        if values.isEmpty { return ExecResult(stdout: "", stderr: "", exitCode: 1) }
        return ExecResult.success(values.joined(separator: "\n") + "\n")
    }

    private func builtinWhich(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        var typeFlag = false
        var pathFlag = false
        var names: [String] = []
        for arg in args {
            if arg == "-t" { typeFlag = true }
            else if arg == "-p" || arg == "-P" { pathFlag = true }
            else { names.append(arg) }
        }
        var lines: [String] = []
        var allFound = true
        for name in names {
            if pathFlag {
                // -p / -P: only print path for external commands, skip builtins/functions
                if registry.contains(name) {
                    lines.append("/bin/\(name)")
                } else {
                    allFound = false
                }
            } else if shellBuiltin(name) != nil {
                lines.append(typeFlag ? "builtin" : "\(name) is a shell builtin")
            } else if session.functions[name] != nil {
                lines.append(typeFlag ? "function" : "\(name) is a function")
            } else if registry.contains(name) {
                lines.append(typeFlag ? "file" : "\(name) is /bin/\(name)")
            } else {
                if !typeFlag {
                    lines.append("bash: type: \(name): not found")
                }
                allFound = false
            }
        }
        return ExecResult(stdout: lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"), stderr: "", exitCode: allFound ? 0 : 1)
    }

    private func builtinExport(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        if args.isEmpty {
            // Print all exported variables
            let lines = session.environment.keys.sorted().map { "declare -x \($0)=\"\(session.environment[$0] ?? "")\"" }
            return ExecResult.success(lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
        }
        var unexportMode = false
        for arg in args {
            if arg == "-n" {
                unexportMode = true
                continue
            }
            if unexportMode {
                session.environment.removeValue(forKey: arg)
                continue
            }
            if let eq = arg.firstIndex(of: "=") {
                let name = String(arg[..<eq])
                let value = String(arg[arg.index(after: eq)...])
                if session.readonlyVariables.contains(name) {
                    return ExecResult.failure("bash: \(name): readonly variable")
                }
                session.setVariable(name, value)
                session.environment[name] = value
            } else if let val = session.getVariable(arg) {
                session.environment[arg] = val
            } else {
                session.environment[arg] = ""
            }
        }
        return ExecResult.success()
    }

    private func builtinUnset(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        var names = args
        if names.first == "-v" || names.first == "-f" || names.first == "-n" {
            let flag = names.removeFirst()
            if flag == "-f" {
                for name in names { session.functions.removeValue(forKey: name) }
                return ExecResult.success()
            }
            if flag == "-n" {
                for name in names { session.namerefs.removeValue(forKey: name) }
                return ExecResult.success()
            }
        }
        for name in names {
            if session.readonlyVariables.contains(name) || parseArrayElementAssignmentTarget(name).map({ session.readonlyVariables.contains($0.0) }) == true {
                return ExecResult.failure("bash: \(name.replacingOccurrences(of: "\\[.*\\]$", with: "", options: .regularExpression)): readonly variable")
            }
            if let (arrayName, key) = parseArrayElementAssignmentTarget(name) {
                if let index = Int(key) {
                    session.unsetArrayElement(arrayName, index: index)
                } else {
                    session.unsetAssociativeElement(arrayName, key: key)
                }
            } else {
                session.namerefs.removeValue(forKey: name)
                session.unsetVariable(name)
            }
        }
        return ExecResult.success()
    }

    private func builtinLocal(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        var isNameref = false
        for arg in args {
            if arg == "-n" { isNameref = true; continue }
            if arg.hasPrefix("-") && !arg.contains("=") { continue } // skip other flags
            if isNameref {
                if let eq = arg.firstIndex(of: "=") {
                    let name = String(arg[..<eq])
                    let target = String(arg[arg.index(after: eq)...])
                    session.namerefs[name] = target
                    session.declareLocal(name)
                } else {
                    session.declareLocal(arg)
                }
                continue
            }
            if let (name, values) = parseInlineArrayArgument(arg) {
                if session.readonlyVariables.contains(name) {
                    return ExecResult.failure("bash: \(name): readonly variable")
                }
                session.declareLocalArray(name, values: values)
            } else if let eq = arg.firstIndex(of: "=") {
                let name = String(arg[..<eq])
                let value = String(arg[arg.index(after: eq)...])
                if session.readonlyVariables.contains(name) {
                    return ExecResult.failure("bash: \(name): readonly variable")
                }
                session.declareLocal(name, value: value)
            } else {
                session.declareLocal(arg)
            }
        }
        return ExecResult.success()
    }

    private func builtinDeclare(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        // Simplified declare - just handle variable assignment
        var isLocal = false
        var isExport = false
        var isArray = false
        var isAssociativeArray = false
        var isPrint = false
        var isNameref = false
        var isInteger = false
        var filtered: [String] = []
        for arg in args {
            if arg.hasPrefix("-") {
                if arg.contains("p") { isPrint = true }
                if arg.contains("x") { isExport = true }
                if arg.contains("a") { isArray = true }
                if arg.contains("A") { isAssociativeArray = true }
                if arg.contains("n") { isNameref = true }
                if arg.contains("i") { isInteger = true }
                // -g means global (opposite of local)
                if !arg.contains("g") && !isPrint { isLocal = true }
            } else {
                filtered.append(arg)
            }
        }

        if isPrint {
            return declarePrint(filtered, &session)
        }
        for arg in filtered {
            if isNameref {
                if let eq = arg.firstIndex(of: "=") {
                    let name = String(arg[..<eq])
                    let target = String(arg[arg.index(after: eq)...])
                    session.namerefs[name] = target
                }
                continue
            }
            if isAssociativeArray {
                if let name = arg.components(separatedBy: "=").first {
                    if isLocal {
                        session.declareAssociativeArray(name)
                    } else {
                        session.declareAssociativeArray(name)
                    }
                }
            } else if isArray, let (name, values) = parseInlineArrayArgument(arg) {
                if session.readonlyVariables.contains(name) {
                    return ExecResult.failure("bash: \(name): readonly variable")
                }
                if isLocal {
                    session.declareLocalArray(name, values: values)
                } else {
                    session.setArray(name, values)
                }
            } else if let eq = arg.firstIndex(of: "=") {
                let name = String(arg[..<eq])
                var value = String(arg[arg.index(after: eq)...])
                if session.readonlyVariables.contains(name) {
                    return ExecResult.failure("bash: \(name): readonly variable")
                }
                if isInteger {
                    value = String(evaluateArithmetic(value, session: &session))
                    session.integerVariables.insert(name)
                }
                if isLocal {
                    session.declareLocal(name, value: value)
                } else {
                    session.setVariable(name, value)
                }
                if isExport { session.environment[name] = value }
            } else {
                if isInteger { session.integerVariables.insert(arg) }
                if isLocal { session.declareLocal(arg) }
            }
        }
        return ExecResult.success()
    }

    private func declarePrint(_ names: [String], _ session: inout ShellSession) -> ExecResult {
        if names.isEmpty {
            // Print all variables
            var lines: [String] = []
            for key in session.environment.keys.sorted() {
                lines.append("declare -- \(key)=\"\(session.environment[key] ?? "")\"")
            }
            for key in session.arrayEnvironment.keys.sorted() {
                let values = session.getArray(key) ?? []
                let elements = values.enumerated().map { "[\($0.offset)]=\"\($0.element)\"" }.joined(separator: " ")
                lines.append("declare -a \(key)=(\(elements))")
            }
            for key in session.associativeArrayEnvironment.keys.sorted() {
                let values = session.associativeArrayEnvironment[key] ?? [:]
                let elements = values.keys.sorted().map { "[\($0)]=\"\(values[$0] ?? "")\"" }.joined(separator: " ")
                lines.append("declare -A \(key)=(\(elements))")
            }
            return ExecResult.success(lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
        }
        var lines: [String] = []
        for name in names {
            if let values = session.getArray(name) {
                let elements = values.enumerated().map { "[\($0.offset)]=\"\($0.element)\"" }.joined(separator: " ")
                lines.append("declare -a \(name)=(\(elements))")
            } else if let values = session.getAssociativeArray(name) {
                let elements = values.keys.sorted().map { "[\($0)]=\"\(values[$0] ?? "")\"" }.joined(separator: " ")
                lines.append("declare -A \(name)=(\(elements))")
            } else if let value = session.getVariable(name) {
                lines.append("declare -- \(name)=\"\(value)\"")
            } else {
                return ExecResult.failure("bash: declare: \(name): not found")
            }
        }
        return ExecResult.success(lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
    }

    private func builtinRead(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        var delimiter = "\n"
        var varNames: [String] = []
        var arrayName: String?
        var nchars: Int? = nil
        var prompt = ""
        var i = 0
        while i < args.count {
            switch args[i] {
            case "-r": i += 1 // raw mode (no backslash processing)
            case "-s": i += 1 // silent mode (no terminal to suppress echo on)
            case "-p":
                i += 1; if i < args.count { prompt = args[i]; i += 1 }
            case "-d":
                i += 1; if i < args.count { delimiter = args[i]; i += 1 }
            case "-a":
                i += 1; if i < args.count { arrayName = args[i]; i += 1 }
            case "-n", "-N":
                i += 1; if i < args.count { nchars = Int(args[i]); i += 1 }
            case "-t":
                i += 2 // timeout is a no-op in sandbox
            case "-u":
                i += 2 // skip option and its argument
            default:
                varNames.append(args[i]); i += 1
            }
        }
        if arrayName == nil && varNames.isEmpty { varNames = ["REPLY"] }

        let input: String
        if let nchars {
            // Read only N characters from stdin
            input = String(stdin.prefix(nchars))
        } else if let delimChar = delimiter.first {
            if let idx = stdin.firstIndex(of: delimChar) {
                input = String(stdin[..<idx])
            } else {
                input = stdin.trimmingCharacters(in: .newlines)
            }
        } else {
            input = stdin.trimmingCharacters(in: .newlines)
        }

        let ifs = session.getVariable("IFS") ?? " \t\n"
        let fields = splitByIFS(input, ifs: ifs)

        if let arrayName {
            session.setArray(arrayName, fields)
        } else {
            for (idx, name) in varNames.enumerated() {
                if idx == varNames.count - 1 {
                    // Last variable gets remaining fields
                    let remaining = fields.dropFirst(idx)
                    session.setVariable(name, remaining.joined(separator: " "))
                } else if idx < fields.count {
                    session.setVariable(name, fields[idx])
                } else {
                    session.setVariable(name, "")
                }
            }
        }

        let exitCode = stdin.isEmpty ? 1 : 0
        return ExecResult(stdout: "", stderr: prompt, exitCode: exitCode)
    }

    func parseAliasWords(_ aliasValue: String) throws -> [ShellWord] {
        let parsed = try ShellParser(limits: limits).parse(aliasValue)
        guard parsed.entries.count == 1,
              parsed.entries[0].andOr.rest.isEmpty else {
            return [ShellWord(literal: aliasValue)]
        }
        let pipeline = parsed.entries[0].andOr.first
        guard pipeline.commands.count == 1,
              case .simple(let simple) = pipeline.commands[0],
              simple.assignments.isEmpty,
              simple.redirections.isEmpty,
              !simple.words.isEmpty else {
            return [ShellWord(literal: aliasValue)]
        }
        return simple.words
    }

    private func builtinSet(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        if args.isEmpty {
            // Print all variables
            let lines = session.environment.keys.sorted().map { "\($0)='\(session.environment[$0] ?? "")'" }
            return ExecResult.success(lines.joined(separator: "\n") + "\n")
        }
        if args[0] == "--" {
            session.positionalParams = Array(args.dropFirst())
            return ExecResult.success()
        }
        for arg in args {
            if arg.hasPrefix("-") {
                for ch in arg.dropFirst() {
                    switch ch {
                    case "e": session.options.errexit = true
                    case "u": session.options.nounset = true
                    case "x": session.options.xtrace = true
                    case "v": session.options.verbose = true
                    case "a": session.options.allexport = true
                    case "f": session.options.noglob = true
                    case "C": session.options.noclobber = true
                    case "o":
                        // Handled below
                        break
                    default: break
                    }
                }
            } else if arg.hasPrefix("+") {
                for ch in arg.dropFirst() {
                    switch ch {
                    case "e": session.options.errexit = false
                    case "u": session.options.nounset = false
                    case "x": session.options.xtrace = false
                    case "v": session.options.verbose = false
                    case "a": session.options.allexport = false
                    case "f": session.options.noglob = false
                    case "C": session.options.noclobber = false
                    default: break
                    }
                }
            }
        }
        // Handle set -o pipefail etc.
        var i = 0
        while i < args.count {
            if args[i] == "-o" && i + 1 >= args.count {
                // `set -o` with no option name: list all options
                let opts: [(String, Bool)] = [
                    ("allexport", session.options.allexport),
                    ("errexit", session.options.errexit),
                    ("noclobber", session.options.noclobber),
                    ("noglob", session.options.noglob),
                    ("nounset", session.options.nounset),
                    ("pipefail", session.options.pipefail),
                    ("verbose", session.options.verbose),
                    ("xtrace", session.options.xtrace),
                ]
                let lines = opts.map { name, on in
                    let pad = String(repeating: " ", count: max(1, 16 - name.count))
                    return "\(name)\(pad)\(on ? "on" : "off")"
                }
                return ExecResult.success(lines.joined(separator: "\n") + "\n")
            }
            if args[i] == "-o" && i + 1 < args.count {
                switch args[i + 1] {
                case "allexport": session.options.allexport = true
                case "errexit": session.options.errexit = true
                case "noclobber": session.options.noclobber = true
                case "noglob": session.options.noglob = true
                case "nounset": session.options.nounset = true
                case "pipefail": session.options.pipefail = true
                case "verbose": session.options.verbose = true
                case "xtrace": session.options.xtrace = true
                default: break
                }
                i += 2
            } else if args[i] == "+o" && i + 1 < args.count {
                switch args[i + 1] {
                case "allexport": session.options.allexport = false
                case "errexit": session.options.errexit = false
                case "noclobber": session.options.noclobber = false
                case "noglob": session.options.noglob = false
                case "nounset": session.options.nounset = false
                case "pipefail": session.options.pipefail = false
                case "verbose": session.options.verbose = false
                case "xtrace": session.options.xtrace = false
                default: break
                }
                i += 2
            } else {
                i += 1
            }
        }
        return ExecResult.success()
    }

    private func builtinShift(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        let n = args.first.flatMap(Int.init) ?? 1
        if n > session.positionalParams.count {
            return ExecResult.failure("shift: shift count out of range")
        }
        session.positionalParams = Array(session.positionalParams.dropFirst(n))
        return ExecResult.success()
    }

    private func builtinReturn(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        let code = args.first.flatMap(Int.init) ?? session.lastExitCode
        throw ControlFlow.return(code)
    }

    private func builtinExit(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        let code = args.first.flatMap(Int.init) ?? session.lastExitCode
        throw ControlFlow.exit(code)
    }

    private func builtinBreak(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        let n = args.first.flatMap(Int.init) ?? 1
        throw ControlFlow.break(max(1, n))
    }

    private func builtinContinue(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        let n = args.first.flatMap(Int.init) ?? 1
        throw ControlFlow.continue(max(1, n))
    }

    private func builtinTest(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        var testArgs = args
        // Remove trailing ] if present (for [ command)
        if testArgs.last == "]" { testArgs.removeLast() }
        let result = evaluateTestExpr(&testArgs, session: session)
        return ExecResult(stdout: "", stderr: "", exitCode: result ? 0 : 1)
    }

    private func evaluateTestExpr(_ args: inout [String], session: ShellSession) -> Bool {
        var result = evaluateTestPrimary(&args, session: session)

        // Check for -a/-o chaining
        while !args.isEmpty {
            let connector = args[0]
            if connector == "-a" {
                args.removeFirst()
                let right = evaluateTestPrimary(&args, session: session)
                result = result && right
            } else if connector == "-o" {
                args.removeFirst()
                let right = evaluateTestPrimary(&args, session: session)
                result = result || right
            } else {
                break
            }
        }

        return result
    }

    private func evaluateTestPrimary(_ args: inout [String], session: ShellSession) -> Bool {
        if args.isEmpty { return false }
        if args.count == 1 { return !args[0].isEmpty }

        // Unary operators
        if args.count >= 2 && args[0].hasPrefix("-") {
            let op = args[0]
            // Make sure this is a known unary operator and not a value
            let unaryOps = ["-z", "-n", "-e", "-f", "-d", "-s", "-r", "-w", "-x", "-L", "-h"]
            if unaryOps.contains(op) {
                let val = args[1]
                args = Array(args.dropFirst(2))
                let path = VirtualPath.normalize(val, relativeTo: session.cwd)
                switch op {
                case "-z": return val.isEmpty
                case "-n": return !val.isEmpty
                case "-e": return fileSystem.exists(path)
                case "-f": return fileSystem.exists(path) && !fileSystem.isDirectory(path)
                case "-d": return fileSystem.isDirectory(path)
                case "-s":
                    guard let info = try? fileSystem.fileInfo(path) else { return false }
                    return info.size > 0
                case "-r", "-w", "-x": return fileSystem.exists(path)
                case "-L", "-h": return (try? fileSystem.readlink(path)) != nil
                default: return false
                }
            }
        }

        // Binary operators
        if args.count >= 3 {
            let left = args[0], op = args[1], right = args[2]
            args = Array(args.dropFirst(3))
            return evaluateBinaryTest(left, op, right, session: session)
        }

        return !args.removeFirst().isEmpty
    }

    private func builtinEval(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        let script = args.joined(separator: " ")
        if script.isEmpty { return ExecResult.success() }
        do {
            let parsed = try ShellParser(limits: limits).parse(script)
            return try await executeScript(parsed, session: &session, stdin: stdin)
        } catch {
            return ExecResult(stdout: "", stderr: "eval: \(error.localizedDescription)\n", exitCode: 1)
        }
    }

    private func builtinSource(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        guard let path = args.first else {
            return ExecResult.failure("source: filename argument required")
        }
        do {
            let content = try fileSystem.readFile(path, relativeTo: session.cwd)
            let parsed = try ShellParser(limits: limits).parse(content)
            return try await executeScript(parsed, session: &session, stdin: stdin)
        } catch {
            return ExecResult(stdout: "", stderr: "source: \(error.localizedDescription)\n", exitCode: 1)
        }
    }

    private func builtinAlias(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        if args.isEmpty {
            let lines = session.aliases.keys.sorted().map { "alias \($0)='\(session.aliases[$0]!)'" }
            return ExecResult.success(lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
        }
        for arg in args {
            if let eq = arg.firstIndex(of: "=") {
                let name = String(arg[..<eq])
                let rawValue = String(arg[arg.index(after: eq)...])
                let value = stripMatchingQuotes(rawValue)
                session.aliases[name] = value
            } else {
                if let val = session.aliases[arg] {
                    return ExecResult.success("alias \(arg)='\(val)'\n")
                }
                return ExecResult.failure("alias: \(arg): not found")
            }
        }
        return ExecResult.success()
    }

    private func stripMatchingQuotes(_ text: String) -> String {
        var result = text
        if result.count >= 2,
           ((result.hasPrefix("'") && result.hasSuffix("'")) || (result.hasPrefix("\"") && result.hasSuffix("\""))) {
            return String(result.dropFirst().dropLast())
        }
        if let first = result.first, first == "'" || first == "\"" {
            result.removeFirst()
        }
        if let last = result.last, last == "'" || last == "\"" {
            result.removeLast()
        }
        return result
    }

    private func parseInlineArrayArgument(_ arg: String) -> (String, [String])? {
        guard let eq = arg.firstIndex(of: "="),
              arg[arg.index(after: eq)] == "(",
              arg.hasSuffix(")") else {
            return nil
        }
        let name = String(arg[..<eq])
        let start = arg.index(arg.index(after: eq), offsetBy: 1)
        let inner = String(arg[start..<arg.index(before: arg.endIndex)])
        guard !name.isEmpty else { return nil }
        do {
            let parsed = try ShellParser(limits: limits).parse("echo \(inner)")
            guard let entry = parsed.entries.first,
                  case .simple(let command) = entry.andOr.first.commands.first else {
                return nil
            }
            let values = command.words.dropFirst().map(\.rawText)
            return (name, values)
        } catch {
            return nil
        }
    }

    private func builtinCommand(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        var filteredArgs = args
        // Handle -v flag: concise output (just name or path)
        if filteredArgs.first == "-v" {
            filteredArgs.removeFirst()
            var lines: [String] = []
            var allFound = true
            for name in filteredArgs {
                if shellBuiltin(name) != nil {
                    lines.append(name)
                } else if session.functions[name] != nil {
                    lines.append(name)
                } else if session.aliases[name] != nil {
                    lines.append("alias \(name)='\(session.aliases[name]!)'")
                } else if registry.contains(name) {
                    lines.append("/bin/\(name)")
                } else {
                    allFound = false
                }
            }
            return ExecResult(stdout: lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"), stderr: "", exitCode: allFound ? 0 : 1)
        }
        // Handle -V flag: verbose output (same as type)
        if filteredArgs.first == "-V" {
            filteredArgs.removeFirst()
            return try await builtinWhich(filteredArgs, &session, env, stdin)
        }
        guard let name = filteredArgs.first else { return ExecResult.success() }
        let cmdArgs = Array(filteredArgs.dropFirst())
        // Execute command, bypassing functions
        if let cmd = registry.command(named: name) {
            let ctx = CommandContext(fileSystem: fileSystem, cwd: session.cwd, environment: env, stdin: stdin)
            return await cmd.execute(cmdArgs, ctx)
        }
        if let builtin = shellBuiltin(name) {
            return try await builtin(cmdArgs, &session, env, stdin)
        }
        return ExecResult.failure("\(name): command not found", exitCode: 127)
    }

    private func builtinLet(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        var lastVal = 0
        for arg in args {
            lastVal = evaluateArithmetic(arg, session: &session)
        }
        return ExecResult(stdout: "", stderr: "", exitCode: lastVal != 0 ? 0 : 1)
    }

    private func builtinGetopts(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        guard args.count >= 2 else { return ExecResult(stdout: "", stderr: "", exitCode: 1) }
        let optstring = args[0]
        let varName = args[1]
        let optArgs = args.count > 2 ? Array(args.dropFirst(2)) : session.positionalParams
        let optind = Int(session.getVariable("OPTIND") ?? "1") ?? 1

        if optind > optArgs.count {
            session.setVariable(varName, "?")
            return ExecResult(stdout: "", stderr: "", exitCode: 1)
        }

        let arg = optArgs[optind - 1]
        guard arg.hasPrefix("-") && arg != "-" && arg != "--" else {
            session.setVariable(varName, "?")
            return ExecResult(stdout: "", stderr: "", exitCode: 1)
        }

        let opt = arg.dropFirst().first!
        session.setVariable(varName, String(opt))

        if let idx = optstring.firstIndex(of: opt) {
            let nextIdx = optstring.index(after: idx)
            if nextIdx < optstring.endIndex && optstring[nextIdx] == ":" {
                // Requires argument
                if arg.count > 2 {
                    session.setVariable("OPTARG", String(arg.dropFirst(2)))
                    session.setVariable("OPTIND", String(optind + 1))
                } else if optind < optArgs.count {
                    session.setVariable("OPTARG", optArgs[optind])
                    session.setVariable("OPTIND", String(optind + 2))
                } else {
                    session.setVariable(varName, ":")
                    session.setVariable("OPTIND", String(optind + 1))
                }
            } else {
                session.setVariable("OPTIND", String(optind + 1))
            }
        } else {
            session.setVariable(varName, "?")
            session.setVariable("OPTIND", String(optind + 1))
        }

        return ExecResult.success()
    }

    private func builtinMapfile(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        var stripTerminators = false
        var variableName = "MAPFILE"
        var customDelimiter: Character?
        var index = 0
        while index < args.count {
            switch args[index] {
            case "-t":
                stripTerminators = true
                index += 1
            case "-d":
                if index + 1 < args.count {
                    let delimArg = args[index + 1]
                    customDelimiter = delimArg.isEmpty ? "\0" : delimArg.first
                    index += 2
                } else {
                    index += 1
                }
            default:
                variableName = args[index]
                index += 1
            }
        }

        let delimiter: Character = customDelimiter ?? "\n"
        var lines = stdin.split(separator: delimiter, omittingEmptySubsequences: false).map(String.init)
        if stripTerminators {
            if lines.last == "" && (customDelimiter != nil ? stdin.last == delimiter : stdin.hasSuffix("\n")) {
                lines.removeLast()
            }
        } else if !stdin.isEmpty {
            let delimStr = String(delimiter)
            lines = lines.map { $0 + delimStr }
            if stdin.last == delimiter, !lines.isEmpty {
                _ = lines.removeLast()
            }
        }
        session.setArray(variableName, lines)
        return ExecResult.success()
    }

    private func builtinPushd(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        guard let targetArg = args.first else {
            return ExecResult.failure("pushd: no other directory")
        }
        let target = VirtualPath.normalize(targetArg, relativeTo: session.cwd)
        guard fileSystem.isDirectory(target) else {
            return ExecResult.failure("pushd: no such directory: \(targetArg)")
        }
        session.directoryStack.insert(session.cwd, at: 0)
        session.cwd = target
        session.setVariable("PWD", target)
        return ExecResult.success(formatDirectoryStack(session) + "\n")
    }

    private func builtinPopd(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        guard !session.directoryStack.isEmpty else {
            return ExecResult.failure("popd: directory stack empty")
        }
        let target = session.directoryStack.removeFirst()
        session.cwd = target
        session.setVariable("PWD", target)
        return ExecResult.success(formatDirectoryStack(session) + "\n")
    }

    private func builtinDirs(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        if args.contains("-p") {
            return ExecResult.success(([session.cwd] + session.directoryStack).joined(separator: "\n") + "\n")
        }
        return ExecResult.success(formatDirectoryStack(session) + "\n")
    }

    private func builtinBuiltin(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        guard let builtinName = args.first else { return ExecResult.success() }
        guard let builtin = shellBuiltin(builtinName) else {
            return ExecResult.failure("builtin: \(builtinName): not a shell builtin")
        }
        return try await builtin(Array(args.dropFirst()), &session, env, stdin)
    }

    private func builtinHash(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        if args.contains("-r") {
            return ExecResult.success()
        }
        if args.isEmpty {
            return ExecResult.success()
        }
        var hashType = false
        var names: [String] = []
        for arg in args {
            if arg == "-t" { hashType = true }
            else if !arg.hasPrefix("-") { names.append(arg) }
        }
        if names.isEmpty { return ExecResult.success() }
        var lines: [String] = []
        var allFound = true
        for name in names {
            if shellBuiltin(name) != nil || registry.contains(name) || session.functions[name] != nil {
                lines.append(hashType ? "/bin/\(name)" : "\(name)=/bin/\(name)")
            } else {
                allFound = false
            }
        }
        let output = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        return ExecResult(stdout: output, stderr: "", exitCode: allFound ? 0 : 1)
    }

    private func builtinExec(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        guard !args.isEmpty else { return ExecResult.success() }
        let script = args.joined(separator: " ")
        let parsed = try ShellParser(limits: limits).parse(script)
        return try await executeScript(parsed, session: &session, stdin: stdin)
    }

    private func builtinReadonly(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        if args.isEmpty {
            let lines = session.readonlyVariables.sorted().map { "readonly \($0)" }
            return ExecResult.success(lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
        }
        for arg in args {
            if let (name, values) = parseInlineArrayArgument(arg) {
                if !session.readonlyVariables.contains(name) {
                    session.setArray(name, values)
                }
                session.readonlyVariables.insert(name)
            } else if let eq = arg.firstIndex(of: "=") {
                let name = String(arg[..<eq])
                let value = String(arg[arg.index(after: eq)...])
                if !session.readonlyVariables.contains(name) {
                    session.setVariable(name, value)
                }
                session.readonlyVariables.insert(name)
            } else {
                session.readonlyVariables.insert(arg)
            }
        }
        return ExecResult.success()
    }

    private func builtinShopt(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        let allOptions: [(String, WritableKeyPath<ShellOptions, Bool>)] = [
            ("expand_aliases", \.expandAliases),
            ("extglob", \.extglob),
            ("nullglob", \.nullglob),
            ("failglob", \.failglob),
            ("globstar", \.globstar),
            ("dotglob", \.dotglob),
            ("nocaseglob", \.nocaseglob),
            ("nocasematch", \.nocasematch),
            ("lastpipe", \.lastpipe),
        ]

        if args.isEmpty {
            let lines = allOptions.map { name, path in
                session.options[keyPath: path] ? "shopt -s \(name)" : "shopt -u \(name)"
            }
            return ExecResult.success(lines.joined(separator: "\n") + "\n")
        }

        if args.count >= 2 && (args[0] == "-s" || args[0] == "-u") {
            let enable = args[0] == "-s"
            for optName in args.dropFirst() {
                if let (_, path) = allOptions.first(where: { $0.0 == optName }) {
                    session.options[keyPath: path] = enable
                }
                // silently ignore unknown options
            }
            return ExecResult.success()
        }

        // Query specific options
        let lines = args.compactMap { optName -> String? in
            guard let (name, path) = allOptions.first(where: { $0.0 == optName }) else { return nil }
            return session.options[keyPath: path] ? "shopt -s \(name)" : "shopt -u \(name)"
        }
        return ExecResult.success(lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
    }

    private func builtinTrap(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        // No args: list all registered traps
        if args.isEmpty {
            if session.traps.isEmpty {
                return ExecResult.success()
            }
            var output = ""
            for (signal, command) in session.traps.sorted(by: { $0.key < $1.key }) {
                output += "trap -- '\(command)' \(signal)\n"
            }
            return ExecResult.success(output)
        }

        // Single arg "-l": list signal names (simplified)
        if args.count == 1 && args[0] == "-l" {
            return ExecResult.success("EXIT HUP INT QUIT TERM ERR DEBUG RETURN\n")
        }

        // Single arg "-p" with optional signals: print traps for those signals
        if args[0] == "-p" {
            let signals = args.dropFirst()
            if signals.isEmpty {
                // Same as no args
                var output = ""
                for (signal, command) in session.traps.sorted(by: { $0.key < $1.key }) {
                    output += "trap -- '\(command)' \(signal)\n"
                }
                return ExecResult.success(output)
            }
            var output = ""
            for sig in signals {
                let normalized = sig.uppercased()
                if let command = session.traps[normalized] {
                    output += "trap -- '\(command)' \(normalized)\n"
                }
            }
            return ExecResult.success(output)
        }

        // Two or more args: trap 'command' SIGNAL [SIGNAL...]
        guard args.count >= 2 else {
            return ExecResult.failure("trap: usage: trap [-lp] [[arg] signal_spec ...]")
        }

        let command = args[0]
        let signals = args.dropFirst()

        for sig in signals {
            let normalized = sig.uppercased()
            if command == "-" {
                // Remove the trap
                session.traps.removeValue(forKey: normalized)
            } else {
                session.traps[normalized] = command
            }
        }
        return ExecResult.success()
    }

    private func formatDirectoryStack(_ session: ShellSession) -> String {
        ([session.cwd] + session.directoryStack).joined(separator: " ")
    }

    // MARK: - Completion builtins

    private func builtinCompgen(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        var actions: Set<Character> = []
        var wordList: [String] = []
        var prefix = ""
        var index = 0

        while index < args.count {
            let arg = args[index]
            if arg == "-W" {
                index += 1
                if index < args.count {
                    wordList = args[index].split(separator: " ").map(String.init)
                }
            } else if arg == "-P" {
                index += 1
                if index < args.count { prefix = args[index] }
            } else if arg.hasPrefix("-") && arg.count > 1 {
                for ch in arg.dropFirst() {
                    actions.insert(ch)
                }
            } else {
                // The word being completed
                prefix = arg
            }
            index += 1
        }

        // Resolve the last positional arg as the completion prefix if set after flags
        let completionPrefix = args.last.flatMap { $0.hasPrefix("-") ? nil : $0 } ?? ""

        var candidates: [String] = []

        // -W wordlist
        if !wordList.isEmpty {
            candidates.append(contentsOf: wordList)
        }

        // -f: filenames
        if actions.contains("f") {
            let dir = VirtualPath.dirname(completionPrefix.isEmpty ? "/" : completionPrefix)
            if let entries = try? fileSystem.listDirectory(dir, relativeTo: session.cwd, includeHidden: true) as? [String] {
                candidates.append(contentsOf: entries)
            } else if let entries = try? fileSystem.listDirectory(session.cwd, includeHidden: true) as? [String] {
                candidates.append(contentsOf: entries)
            }
        }

        // -d: directories
        if actions.contains("d") {
            if let entries = try? fileSystem.walk(session.cwd, relativeTo: "/") as? [String] {
                for entry in entries {
                    if fileSystem.isDirectory(entry) {
                        candidates.append(VirtualPath.basename(entry))
                    }
                }
            }
        }

        // -c: commands (builtins + registered commands)
        if actions.contains("c") {
            let builtinNames = ["cd", "pwd", "echo", "printf", "env", "printenv", "which", "type",
                                "true", "false", "export", "unset", "local", "declare", "typeset",
                                "read", "set", "shift", "return", "exit", "break", "continue",
                                "test", "eval", "source", "trap", "alias", "unalias", "command",
                                "let", "getopts", "mapfile", "readarray", "pushd", "popd", "dirs",
                                "builtin", "hash", "exec", "readonly", "shopt", "compgen", "complete"]
            candidates.append(contentsOf: builtinNames)
            candidates.append(contentsOf: registry.names)
        }

        // -b: builtins only
        if actions.contains("b") {
            let builtinNames = ["cd", "pwd", "echo", "printf", "env", "printenv", "which",
                                "true", "false", "export", "unset", "local", "declare",
                                "read", "set", "shift", "return", "exit", "break", "continue",
                                "test", "eval", "source", "trap", "alias", "unalias", "command",
                                "let", "getopts", "mapfile", "readarray", "pushd", "popd", "dirs",
                                "builtin", "hash", "exec", "readonly", "shopt", "compgen", "complete"]
            candidates.append(contentsOf: builtinNames)
        }

        // -v: variables
        if actions.contains("v") {
            candidates.append(contentsOf: session.environment.keys)
        }

        // -A function: functions
        if actions.contains("A") {
            candidates.append(contentsOf: session.functions.keys)
        }

        // Filter by prefix
        let filtered: [String]
        if !completionPrefix.isEmpty {
            filtered = candidates.filter { $0.hasPrefix(completionPrefix) }
        } else {
            filtered = candidates
        }

        let unique = Array(Set(filtered)).sorted()
        if unique.isEmpty { return ExecResult.success() }
        return ExecResult.success(unique.joined(separator: "\n") + "\n")
    }

    private func builtinComplete(_ args: [String], _ session: inout ShellSession, _ env: [String: String], _ stdin: String) async throws -> ExecResult {
        // In a non-interactive sandbox, `complete` stores completion specs but they
        // won't fire. We accept the command silently for script compatibility.
        return ExecResult.success()
    }
}
