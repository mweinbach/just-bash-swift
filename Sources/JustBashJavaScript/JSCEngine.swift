import Foundation
import JavaScriptCore
import JustBashCommands
import JustBashFS

/// Owns the JavaScriptCore lifecycle for the embedded `js-exec` runtime.
///
/// Each `runCode(...)` call constructs a **fresh `JSContext`** inside a shared
/// `JSVirtualMachine`. The fresh-context pattern matches upstream's
/// quickjs-emscripten approach (`worker.ts:65-75`): one context per script,
/// no state leakage between invocations.
///
/// ## Thread / actor model
///
/// `JSContext`/`JSValue` are non-Sendable Objective-C classes. The actor
/// owns them across an `await` boundary. The `@convention(block)` closures
/// installed as host functions (`fs`, `process`, `child_process`, `fetch`, etc.)
/// run synchronously on whichever thread calls into JS — but those calls
/// originate from `JSContext.evaluateScript` which we only invoke from inside
/// the actor's executor, so the closures see actor-isolated state safely.
///
/// ## Re-entrance
///
/// `js-exec` invocations from inside `js-exec` (e.g. via `child_process.execSync`
/// → bash → `js-exec ...`) would deadlock the subprocess semaphore. The engine
/// tracks invocation depth and rejects nested calls with a clear error.
public actor JSCEngine {
    private let options: BashJavaScriptOptions
    private let virtualMachine: JSVirtualMachine
    private var depth: Int = 0
    private let bootstrapResources: BootstrapResources

    init(options: BashJavaScriptOptions) {
        self.options = options
        self.virtualMachine = JSVirtualMachine()
        self.bootstrapResources = BootstrapResources.load()
    }

    /// Execute a JS source string under the supplied bash command context and
    /// return a captured `ExecResult`.
    func runCode(
        _ source: String,
        ctx: CommandContext,
        scriptArgs: [String],
        scriptPath: String?,
        isModule: Bool
    ) async -> ExecResult {
        if depth > 0 {
            return ExecResult.failure("js-exec: nested invocation rejected (re-entrance from inside js-exec is not supported)", exitCode: 2)
        }
        depth += 1
        defer { depth -= 1 }

        guard let context = JSContext(virtualMachine: virtualMachine) else {
            return ExecResult.failure("js-exec: failed to create JSContext", exitCode: 2)
        }
        let capture = JSCStreamCapture()
        var collectedException: String? = nil
        context.exceptionHandler = { _, value in
            if let value = value {
                collectedException = describeJSException(value)
            }
        }

        // Install bridges and bootstrap shims.
        let executionContext = JSCExecutionContext(
            capture: capture,
            cmdCtx: ctx,
            scriptArgs: scriptArgs,
            scriptPath: scriptPath,
            options: options
        )
        installBridges(into: context, execution: executionContext)
        evaluateBootstrapShims(into: context, resources: bootstrapResources)
        if let bootstrap = options.bootstrap, !bootstrap.isEmpty {
            context.evaluateScript(bootstrap)
            if let exc = collectedException {
                return finalize(capture: capture, exception: exc, defaultExit: 1)
            }
        }
        if executionContext.exitRequested {
            return finalize(capture: capture, exception: nil, defaultExit: executionContext.exitCode)
        }

        // Set up wall-clock deadline. JSC's `terminateExecution` is not public
        // API on iOS-shaped surfaces, so the engine enforces the timeout
        // post-hoc by checking the deadline in the polling loop and returning
        // a 124 exit code without forcibly stopping the script.
        let deadlineMs = ctx.allowedURLPrefixes.isEmpty ? options.defaultTimeoutMs : options.defaultNetworkTimeoutMs
        let pollDeadline = Date().addingTimeInterval(Double(deadlineMs) / 1000.0)

        // Run user code.
        let wrappedSource: String
        if isModule {
            wrappedSource = "(async () => { \n\(source)\n })().then(_jb_done, _jb_fail);"
        } else {
            wrappedSource = source
        }
        let moduleState = ModuleAwaitState(initiallyResolved: !isModule)
        if isModule {
            let done: @convention(block) () -> Void = { moduleState.resolve(error: nil) }
            let fail: @convention(block) (JSValue?) -> Void = { value in
                let message: String?
                if let value = value, !value.isUndefined { message = describeJSException(value) } else { message = nil }
                moduleState.resolve(error: message)
            }
            context.setObject(done, forKeyedSubscript: "_jb_done" as NSString)
            context.setObject(fail, forKeyedSubscript: "_jb_fail" as NSString)
        }

        context.evaluateScript(wrappedSource)
        // process.exit takes precedence over the synthetic __jb_exit exception
        // it raises to short-circuit the rest of the script.
        if executionContext.exitRequested {
            return finalize(capture: capture, exception: nil, defaultExit: executionContext.exitCode)
        }
        if let exc = collectedException, moduleState.errorMessage == nil {
            return finalize(capture: capture, exception: exc, defaultExit: 1)
        }

        // Drain microtasks for module mode (or any pending promise like fetch).
        var timedOut = false
        while (!moduleState.resolved || executionContext.pendingTasks > 0) && !timedOut {
            if Date() >= pollDeadline { timedOut = true; break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        if executionContext.exitRequested {
            return finalize(capture: capture, exception: nil, defaultExit: executionContext.exitCode)
        }
        if timedOut {
            return finalize(capture: capture, exception: "js-exec: script exceeded \(deadlineMs)ms timeout", defaultExit: 124)
        }
        if let moduleError = moduleState.errorMessage {
            return finalize(capture: capture, exception: moduleError, defaultExit: 1)
        }
        return finalize(capture: capture, exception: nil, defaultExit: 0)
    }

    private func finalize(capture: JSCStreamCapture, exception: String?, defaultExit: Int) -> ExecResult {
        var stderr = capture.stderr
        var exit = defaultExit
        if let exception = exception {
            if !stderr.isEmpty && !stderr.hasSuffix("\n") { stderr += "\n" }
            stderr += exception
            if !stderr.hasSuffix("\n") { stderr += "\n" }
            if exit == 0 { exit = 1 }
        }
        return ExecResult(stdout: capture.stdout, stderr: stderr, exitCode: exit)
    }
}

/// Per-invocation state shared between the engine actor and host-function
/// closures installed into the `JSContext`.
final class JSCExecutionContext: @unchecked Sendable {
    let capture: JSCStreamCapture
    let cmdCtx: CommandContext
    let scriptArgs: [String]
    let scriptPath: String?
    let options: BashJavaScriptOptions
    var exitRequested: Bool = false
    var exitCode: Int = 0
    var pendingTasks: Int = 0
    var loadedAddons: [String: JSValue] = [:]

    init(
        capture: JSCStreamCapture,
        cmdCtx: CommandContext,
        scriptArgs: [String],
        scriptPath: String?,
        options: BashJavaScriptOptions
    ) {
        self.capture = capture
        self.cmdCtx = cmdCtx
        self.scriptArgs = scriptArgs
        self.scriptPath = scriptPath
        self.options = options
    }
}

final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    func isSet() -> Bool { lock.lock(); let v = flag; lock.unlock(); return v }
}

/// Holds the mutable state read by the engine's polling loop and written by
/// the JS-side `_jb_done`/`_jb_fail` blocks. Reference-typed so the blocks
/// (which can't capture `inout` Swift locals) can flip the flag.
final class ModuleAwaitState: @unchecked Sendable {
    private let lock = NSLock()
    private var _resolved: Bool
    private var _error: String?
    init(initiallyResolved: Bool) { self._resolved = initiallyResolved }
    var resolved: Bool { lock.lock(); let v = _resolved; lock.unlock(); return v }
    var errorMessage: String? { lock.lock(); let v = _error; lock.unlock(); return v }
    func resolve(error: String?) {
        lock.lock(); _resolved = true; if let error = error { _error = error }; lock.unlock()
    }
}

/// Bundle-loaded JS shim sources, evaluated into every fresh JSContext.
struct BootstrapResources {
    let consolePolyfill: String
    let pathPolyfill: String
    let moduleShims: String
    let fetchGlue: String

    static func load() -> BootstrapResources {
        BootstrapResources(
            consolePolyfill: loadResource(named: "console-polyfill"),
            pathPolyfill: loadResource(named: "path-polyfill"),
            moduleShims: loadResource(named: "module-shims"),
            fetchGlue: loadResource(named: "fetch-glue")
        )
    }

    private static func loadResource(named name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "// missing bootstrap resource: \(name).js"
        }
        return text
    }
}

func evaluateBootstrapShims(into context: JSContext, resources: BootstrapResources) {
    context.evaluateScript(resources.consolePolyfill)
    context.evaluateScript(resources.pathPolyfill)
    context.evaluateScript(resources.fetchGlue)
    context.evaluateScript(resources.moduleShims)
}

func describeJSException(_ value: JSValue) -> String {
    if value.isObject, let message = value.objectForKeyedSubscript("message")?.toString(), !message.isEmpty {
        if let stack = value.objectForKeyedSubscript("stack")?.toString(), !stack.isEmpty, stack != "undefined" {
            return "\(message)\n\(stack)"
        }
        return message
    }
    return value.toString() ?? "<JS exception>"
}
