import Foundation

func bash() -> AnyBashCommand {
    shellRunnerCommand(named: "bash")
}

func sh() -> AnyBashCommand {
    shellRunnerCommand(named: "sh")
}

func time() -> AnyBashCommand {
    AnyBashCommand(name: "time") { args, ctx in
        guard !args.isEmpty else { return ExecResult.failure("time: missing command") }
        guard let executor = ctx.executeSubshell else {
            return ExecResult.failure("time: shell execution unavailable")
        }
        let result = await executor(args.joined(separator: " "))
        return ExecResult(stdout: result.stdout, stderr: result.stderr + "real 0.000\nuser 0.000\nsys 0.000\n", exitCode: result.exitCode)
    }
}

func timeout() -> AnyBashCommand {
    AnyBashCommand(name: "timeout") { args, ctx in
        guard args.count >= 2 else { return ExecResult.failure("timeout: missing command") }
        guard let executor = ctx.executeSubshell else {
            return ExecResult.failure("timeout: shell execution unavailable")
        }
        return await executor(args.dropFirst().joined(separator: " "))
    }
}

private func shellRunnerCommand(named name: String) -> AnyBashCommand {
    AnyBashCommand(name: name) { args, ctx in
        guard let executor = ctx.executeSubshell else {
            return ExecResult.failure("\(name): shell execution unavailable")
        }
        if args.isEmpty {
            return ExecResult.success()
        }
        return await executor(args.joined(separator: " "))
    }
}
