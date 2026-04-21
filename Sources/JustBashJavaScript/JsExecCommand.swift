import Foundation
import JustBashCommands

/// Builds the `js-exec` command handler bound to a particular `JSCEngine`.
///
/// CLI parity target: upstream `js-exec.ts:141-211, 587-608`.
/// Supported flags:
/// - `-c CODE` — inline code
/// - `-m`/`--module` — module mode
/// - `-V`/`--version` — print runtime version
/// - `--help` — print usage
/// - file argument — reads the script via `ctx.fileSystem.readFile`
/// - `-` — read script from stdin
/// - no script source given — read script from stdin
/// - Auto-detect module mode for `.mjs`/`.mts`/`.ts` extensions
/// - All non-flag args after the script source become `process.argv` extras
func makeJsExecCommand(engine: JSCEngine) -> AnyBashCommand {
    AnyBashCommand(name: "js-exec") { args, ctx in
        var i = 0
        var inlineCode: String? = nil
        var isModule = false
        var scriptPath: String? = nil
        var scriptArgs: [String] = []
        var readFromStdin = false

        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--help":
                return ExecResult.success("""
                js-exec — run JavaScript inside the bash sandbox

                  js-exec -c 'code'        execute inline code
                  js-exec -m -c 'code'     execute as ES module (allows top-level await)
                  js-exec script.js        execute a script file
                  js-exec - < script.js    read script from stdin
                  js-exec -V               print runtime version

                """)
            case "-V", "--version":
                return ExecResult.success("JavaScriptCore (just-bash JustBashJavaScript)\n")
            case "-c":
                i += 1
                if i < args.count {
                    inlineCode = args[i]
                } else {
                    return ExecResult.failure("js-exec: -c requires an argument", exitCode: 2)
                }
            case "-m", "--module":
                isModule = true
            case "--strip-types":
                // No-op for JSC; TypeScript stripping not implemented in v1.
                break
            case "-":
                readFromStdin = true
            default:
                if arg.hasPrefix("-") {
                    return ExecResult.failure("js-exec: unknown option \(arg)", exitCode: 2)
                }
                if inlineCode == nil && scriptPath == nil && !readFromStdin {
                    scriptPath = arg
                } else {
                    scriptArgs.append(arg)
                }
            }
            i += 1
        }

        // Auto-detect module mode by extension.
        if let path = scriptPath {
            let lower = path.lowercased()
            if lower.hasSuffix(".mjs") || lower.hasSuffix(".mts") {
                isModule = true
            }
        }

        // Resolve script source.
        let source: String
        if let inline = inlineCode {
            source = inline
        } else if let path = scriptPath {
            do {
                let data = try ctx.fileSystem.readFile(path: path, relativeTo: ctx.cwd)
                source = String(decoding: data, as: UTF8.self)
            } catch {
                return ExecResult.failure("js-exec: cannot read \(path): \(error.localizedDescription)", exitCode: 2)
            }
        } else if readFromStdin || !ctx.stdin.isEmpty {
            source = ctx.stdin
        } else {
            return ExecResult.failure("js-exec: no script source provided (use -c, a file path, or pipe via stdin)", exitCode: 2)
        }

        return await engine.runCode(
            source,
            ctx: ctx,
            scriptArgs: scriptArgs,
            scriptPath: scriptPath,
            isModule: isModule
        )
    }
}
