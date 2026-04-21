import Foundation
import JavaScriptCore
import JustBashCommands

/// Installs `child_process.execSync` / `spawnSync`. Both call back into the
/// bash interpreter via `ctx.executeSubshell`, mirroring upstream's
/// `worker.ts:259-278`.
///
/// JS `execSync` is *synchronous* in Node. JSC has no SharedArrayBuffer story
/// we want to use; we bridge sync-from-async with a `DispatchSemaphore`. The
/// `executeSubshell` closure routes back to the `Bash` actor, a different
/// actor from `JSCEngine`, so there is no reentrance risk.
func installChildProcessBridge(into context: JSContext, execution: JSCExecutionContext) {
    let execSync: @convention(block) (String, JSValue?) -> JSValue? = { command, opts in
        guard let executor = execution.cmdCtx.executeSubshell else {
            context.exception = JSValue(newErrorFromMessage: "child_process.execSync: subshell execution unavailable", in: context)
            return nil
        }
        let timeoutMs = readTimeout(opts: opts, fallback: execution.options.defaultTimeoutMs)
        let result = runSubshellSync(command: command, timeoutMs: timeoutMs, executor: executor)
        switch result {
        case .timeout:
            context.exception = JSValue(newErrorFromMessage: "child_process.execSync: timed out after \(timeoutMs)ms", in: context)
            return nil
        case .completed(let exec):
            if exec.exitCode != 0 {
                let err = JSValue(newErrorFromMessage: "Command failed: \(command)\n\(exec.stderr)", in: context)
                err?.setObject(exec.exitCode, forKeyedSubscript: "status" as NSString)
                err?.setObject(exec.stdout, forKeyedSubscript: "stdout" as NSString)
                err?.setObject(exec.stderr, forKeyedSubscript: "stderr" as NSString)
                context.exception = err
                return nil
            }
            return JSValue(object: exec.stdout, in: context)
        }
    }

    let spawnSync: @convention(block) (String, JSValue?, JSValue?) -> JSValue = { cmd, args, opts in
        guard let executor = execution.cmdCtx.executeSubshell else {
            return JSValue(object: ["status": -1, "stdout": "", "stderr": "subshell execution unavailable", "signal": NSNull(), "pid": 0], in: context)!
        }
        var argv: [String] = [cmd]
        if let args = args, !args.isUndefined, !args.isNull {
            let lenValue = args.objectForKeyedSubscript("length")
            let len = (lenValue != nil && !(lenValue!.isUndefined)) ? Int(lenValue!.toInt32()) : 0
            for i in 0..<len {
                if let s = args.objectAtIndexedSubscript(i)?.toString() { argv.append(s) }
            }
        }
        let line = argv.map { quoteShellArg($0) }.joined(separator: " ")
        let timeoutMs = readTimeout(opts: opts, fallback: execution.options.defaultTimeoutMs)
        let result = runSubshellSync(command: line, timeoutMs: timeoutMs, executor: executor)
        switch result {
        case .timeout:
            return JSValue(object: ["status": NSNull(), "stdout": "", "stderr": "ETIMEDOUT", "signal": "SIGTERM", "pid": 0, "error": ["code": "ETIMEDOUT"]], in: context)!
        case .completed(let exec):
            return JSValue(object: ["status": exec.exitCode, "stdout": exec.stdout, "stderr": exec.stderr, "signal": NSNull(), "pid": 0], in: context)!
        }
    }

    // Bind via temporary globals so `globalThis.child_process` is set
    // explicitly, avoiding any name-resolution surprises with key-based set.
    context.setObject(execSync, forKeyedSubscript: "__jb_child_execSync" as NSString)
    context.setObject(spawnSync, forKeyedSubscript: "__jb_child_spawnSync" as NSString)
    context.evaluateScript("globalThis.child_process = { execSync: __jb_child_execSync, spawnSync: __jb_child_spawnSync };")
}

private func readTimeout(opts: JSValue?, fallback: Int) -> Int {
    guard let opts = opts, !opts.isUndefined, !opts.isNull else { return fallback }
    guard let t = opts.objectForKeyedSubscript("timeout"), !t.isUndefined, !t.isNull else { return fallback }
    let value = t.toInt32()
    return value > 0 ? Int(value) : fallback
}

private enum SubshellSyncResult {
    case completed(ExecResult)
    case timeout
}

/// Bridges the async `executeSubshell` to a synchronous-on-call-site result by
/// blocking on a DispatchSemaphore. Safe because `executeSubshell` runs on a
/// different actor (`Bash`) than the one calling us (`JSCEngine`).
private func runSubshellSync(command: String, timeoutMs: Int, executor: @escaping SubshellExecutor) -> SubshellSyncResult {
    let semaphore = DispatchSemaphore(value: 0)
    let resultBox = ResultBox()
    Task.detached(priority: .userInitiated) {
        let result = await executor(command)
        resultBox.store(result)
        semaphore.signal()
    }
    let timeout: DispatchTime = .now() + .milliseconds(timeoutMs)
    if semaphore.wait(timeout: timeout) == .timedOut {
        return .timeout
    }
    return .completed(resultBox.read() ?? ExecResult(stdout: "", stderr: "subshell returned no result", exitCode: 1))
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ExecResult?
    func store(_ v: ExecResult) { lock.lock(); value = v; lock.unlock() }
    func read() -> ExecResult? { lock.lock(); let v = value; lock.unlock(); return v }
}

private func quoteShellArg(_ s: String) -> String {
    if s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "/" || $0 == "." || $0 == "-" || $0 == "@" || $0 == ":" }) {
        return s
    }
    let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
    return "'\(escaped)'"
}
