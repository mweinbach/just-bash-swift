import Foundation
import JustBashFS

func git() -> AnyBashCommand {
    AnyBashCommand(name: "git") { args, ctx in
#if os(macOS) || targetEnvironment(macCatalyst)
        return runHostGit(args: args, ctx: ctx)
#else
        return ExecResult.failure("git: unavailable on this platform; use a host-backed macOS or Mac Catalyst runtime")
#endif
    }
}

#if os(macOS) || targetEnvironment(macCatalyst)
private func runHostGit(args: [String], ctx: CommandContext) -> ExecResult {
    guard let hostFS = ctx.fileSystem as? any HostPathFileSystem,
          let hostCwd = hostFS.hostPath(for: ctx.cwd, relativeTo: "/")
    else {
        return ExecResult.failure(
            "git: requires a host-backed writable filesystem (for example ReadWriteFileSystem or a mounted host-backed path)"
        )
    }

    let rewrittenArgs = rewriteGitArguments(args, hostFS: hostFS, cwd: ctx.cwd)
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let stdinPipe = Pipe()

    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + rewrittenArgs
    process.currentDirectoryURL = URL(fileURLWithPath: hostCwd, isDirectory: true)
    process.environment = buildGitEnvironment(shellEnv: ctx.environment, hostFS: hostFS, cwd: ctx.cwd, hostCwd: hostCwd)
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.standardInput = stdinPipe

    do {
        try process.run()
    } catch {
        return ExecResult.failure("git: failed to launch host git: \(error.localizedDescription)")
    }

    if !ctx.stdin.isEmpty, let data = ctx.stdin.data(using: .utf8) {
        stdinPipe.fileHandleForWriting.write(data)
    }
    try? stdinPipe.fileHandleForWriting.close()

    process.waitUntilExit()

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    let stdout = String(data: stdoutData, encoding: .utf8) ?? String(decoding: stdoutData, as: UTF8.self)
    let stderr = String(data: stderrData, encoding: .utf8) ?? String(decoding: stderrData, as: UTF8.self)

    return ExecResult(stdout: stdout, stderr: stderr, exitCode: Int(process.terminationStatus))
}

private func rewriteGitArguments(_ args: [String], hostFS: any HostPathFileSystem, cwd: String) -> [String] {
    var rewritten: [String] = []
    var expectsPathValueForOption = false

    for arg in args {
        if expectsPathValueForOption {
            rewritten.append(rewriteVirtualPathIfNeeded(arg, hostFS: hostFS, cwd: cwd))
            expectsPathValueForOption = false
            continue
        }

        switch arg {
        case "-C", "--git-dir", "--work-tree":
            expectsPathValueForOption = true
            rewritten.append(arg)
        default:
            if let prefix = ["--git-dir=", "--work-tree="].first(where: { arg.hasPrefix($0) }) {
                let value = String(arg.dropFirst(prefix.count))
                let rewrittenValue = rewriteVirtualPathIfNeeded(value, hostFS: hostFS, cwd: cwd)
                rewritten.append(prefix + rewrittenValue)
            } else {
                rewritten.append(rewriteVirtualPathIfNeeded(arg, hostFS: hostFS, cwd: cwd))
            }
        }
    }

    return rewritten
}

private func rewriteVirtualPathIfNeeded(_ value: String, hostFS: any HostPathFileSystem, cwd: String) -> String {
    guard value.hasPrefix("/") else { return value }
    guard !value.contains("://") else { return value }
    return hostFS.hostPath(for: value, relativeTo: cwd) ?? value
}

private func buildGitEnvironment(
    shellEnv: [String: String],
    hostFS: any HostPathFileSystem,
    cwd: String,
    hostCwd: String
) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    let skippedSyntheticDefaults: [String: String] = [
        "HOME": "/home/user",
        "PATH": "/usr/bin:/bin",
        "HOSTNAME": "localhost",
        "SHELL": "/bin/bash",
        "TERM": "xterm-256color",
        "LANG": "en_US.UTF-8",
        "BASH_VERSION": "5.2.0(1)-release",
        "SHLVL": "1",
        "LINENO": "1",
        "SECONDS": "0",
        "OPTIND": "1",
    ]
    let skippedKeys = Set([
        "OLDPWD", "IFS", "BASH_VERSINFO", "RANDOM"
    ])
    let singlePathKeys = Set([
        "HOME", "GIT_DIR", "GIT_WORK_TREE", "XDG_CONFIG_HOME", "GIT_TEMPLATE_DIR", "GIT_OBJECT_DIRECTORY"
    ])

    for (key, value) in shellEnv {
        if skippedKeys.contains(key) {
            continue
        }
        if let synthetic = skippedSyntheticDefaults[key], synthetic == value, environment[key] != nil {
            continue
        }
        if singlePathKeys.contains(key) {
            environment[key] = rewriteVirtualPathIfNeeded(value, hostFS: hostFS, cwd: cwd)
        } else {
            environment[key] = value
        }
    }

    environment["PWD"] = hostCwd
    return environment
}
#endif
