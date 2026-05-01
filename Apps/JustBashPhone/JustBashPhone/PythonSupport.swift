import Foundation

struct PythonExecResult {
    let stdout: String
    let stderr: String
    let exitCode: Int
}

#if canImport(Python)
import Python

enum PythonSupport {
    static var isAvailable: Bool { true }

    private static let interpreterLock = NSLock()

    static func availabilitySummary() -> String {
        "BeeWare Python support is linked."
    }

    static func run(
        code: String,
        workspacePath: String,
        arguments: [String] = [],
        scriptName: String = "<justbash-python>",
        scriptPath: String? = nil
    ) -> PythonExecResult {
        let pythonHome = pythonHomePath()
        let traceDir = workspacePath

        interpreterLock.lock()
        defer {
            interpreterLock.unlock()
        }

        try? FileManager.default.createDirectory(atPath: workspacePath, withIntermediateDirectories: true)
        let previousDirectory = FileManager.default.currentDirectoryPath
        let previousWorkspace = getenv("JUSTBASH_WORKSPACE").map { String(cString: $0) }
        _ = FileManager.default.changeCurrentDirectoryPath(workspacePath)
        setenv("JUSTBASH_WORKSPACE", workspacePath, 1)
        defer {
            _ = FileManager.default.changeCurrentDirectoryPath(previousDirectory)
            if let previousWorkspace {
                setenv("JUSTBASH_WORKSPACE", previousWorkspace, 1)
            } else {
                unsetenv("JUSTBASH_WORKSPACE")
            }
        }

        writeTrace("entered", to: traceDir)
        setenv("LANG", "\(Locale.current.identifier).UTF-8", 1)
        writeTrace("after-lang", to: traceDir)

        if let initializationError = initializeIfNeeded(pythonHome: pythonHome, traceDir: traceDir) {
            return failureResult(error: initializationError)
        }

        let outputDirectory = workspacePath + "/.python-run"
        let outputPaths = OutputFilePaths(baseDirectory: outputDirectory)
        try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

        let scriptGlobals = if let scriptPath {
            "{\"__name__\": \"__main__\", \"__file__\": \(pythonStringLiteral(scriptPath))}"
        } else {
            "{\"__name__\": \"__main__\"}"
        }

        let wrappedCode = """
        import contextlib
        import io
        import sys
        import traceback
        from pathlib import Path

        sys.argv = \(pythonListLiteral([scriptPath ?? scriptName] + arguments))
        _stdout_buffer = io.StringIO()
        _stderr_buffer = io.StringIO()
        _status = 0
        with contextlib.redirect_stdout(_stdout_buffer), contextlib.redirect_stderr(_stderr_buffer):
            try:
                exec(compile(\(pythonStringLiteral(code)), \(pythonStringLiteral(scriptName)), "exec"), \(scriptGlobals))
            except SystemExit as exc:
                value = exc.code
                _status = value if isinstance(value, int) else 1
                if value not in (None, 0):
                    print(f"SystemExit: {value}", file=_stderr_buffer)
            except Exception:
                _status = 1
                traceback.print_exc(file=_stderr_buffer)

        Path(\(pythonStringLiteral(outputPaths.stdout))).write_text(_stdout_buffer.getvalue())
        Path(\(pythonStringLiteral(outputPaths.stderr))).write_text(_stderr_buffer.getvalue())
        Path(\(pythonStringLiteral(outputPaths.exitCode))).write_text(str(_status))
        """

        let runStatus = PyRun_SimpleString(wrappedCode)
        writeTrace("after-code-\(runStatus)", to: traceDir)
        guard runStatus == 0 else {
            return failureResult(error: PythonExecutionError.executionFailed(runStatus))
        }

        return outputPaths.readResult()
    }

    private static func pythonHomePath() -> String {
        Bundle.main.path(forResource: "python", ofType: nil)
            ?? (Bundle.main.resourceURL?.path ?? NSTemporaryDirectory()) + "/python"
    }

    private static func appPath() -> String {
        Bundle.main.path(forResource: "app", ofType: nil)
            ?? (Bundle.main.resourceURL?.path ?? NSTemporaryDirectory()) + "/app"
    }

    private static func initializeIfNeeded(pythonHome: String, traceDir: String) -> Error? {
        guard Py_IsInitialized() == 0 else {
            return nil
        }

        var preconfig = PyPreConfig()
        var config = PyConfig()
        PyPreConfig_InitIsolatedConfig(&preconfig)
        PyConfig_InitIsolatedConfig(&config)
        defer {
            PyConfig_Clear(&config)
        }

        preconfig.utf8_mode = 1
        preconfig.configure_locale = 1
        config.use_system_logger = 1
        config.buffered_stdio = 0
        config.write_bytecode = 0
        config.install_signal_handlers = 1
        writeTrace("after-config-init", to: traceDir)

        var status = Py_PreInitialize(&preconfig)
        guard !statusHasException(status) else {
            return PythonExecutionError.statusFailure("preinitialize", statusMessage(status))
        }
        writeTrace("after-preinitialize", to: traceDir)

        guard let homeWide = Py_DecodeLocale(pythonHome, nil) else {
            return PythonExecutionError.decodeLocale("pythonHome")
        }
        defer { PyMem_RawFree(homeWide) }

        withUnsafeMutablePointer(to: &config) { configPtr in
            withUnsafeMutablePointer(to: &configPtr.pointee.home) { homePtr in
                status = PyConfig_SetString(configPtr, homePtr, homeWide)
            }
        }
        guard !statusHasException(status) else {
            return PythonExecutionError.statusFailure("set-home", statusMessage(status))
        }
        writeTrace("after-set-home", to: traceDir)

        status = PyConfig_Read(&config)
        guard !statusHasException(status) else {
            return PythonExecutionError.statusFailure("read-config", statusMessage(status))
        }
        writeConfigSnapshot(config, to: traceDir)
        writeTrace("after-config-read", to: traceDir)

        let argv = [strdup("JustBashPhone")]
        defer {
            for arg in argv {
                free(arg)
            }
        }

        status = argv.withUnsafeBufferPointer { buffer in
            PyConfig_SetBytesArgv(&config, buffer.count, UnsafeMutablePointer(mutating: buffer.baseAddress))
        }
        guard !statusHasException(status) else {
            return PythonExecutionError.statusFailure("set-argv", statusMessage(status))
        }
        writeTrace("after-argv", to: traceDir)

        status = Py_InitializeFromConfig(&config)
        guard !statusHasException(status) else {
            return PythonExecutionError.statusFailure("initialize", statusMessage(status))
        }
        writeTrace("after-initialize", to: traceDir)

        let bootstrap = """
        import sys
        _justbash_app_path = \(pythonStringLiteral(appPath()))
        _justbash_site_packages = _justbash_app_path + "/site-packages"
        if _justbash_site_packages not in sys.path:
            sys.path.insert(0, _justbash_site_packages)
        if _justbash_app_path not in sys.path:
            sys.path.insert(0, _justbash_app_path)
        """
        let bootstrapStatus = PyRun_SimpleString(bootstrap)
        writeTrace("after-bootstrap-\(bootstrapStatus)", to: traceDir)
        guard bootstrapStatus == 0 else {
            return PythonExecutionError.executionFailed(bootstrapStatus)
        }

        return nil
    }

    private static func pythonListLiteral(_ values: [String]) -> String {
        "[" + values.map(pythonStringLiteral).joined(separator: ", ") + "]"
    }

    private static func pythonStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    private static func writeTrace(_ marker: String, to directory: String) {
        guard traceEnabled else {
            return
        }
        let path = directory + "/python-trace-\(marker).txt"
        try? marker.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func writeConfigSnapshot(_ config: PyConfig, to directory: String) {
        guard traceEnabled else {
            return
        }
        var lines: [String] = []
        lines.append("home=\(wideString(config.home))")
        lines.append("program_name=\(wideString(config.program_name))")
        lines.append("executable=\(wideString(config.executable))")
        lines.append("prefix=\(wideString(config.prefix))")
        lines.append("exec_prefix=\(wideString(config.exec_prefix))")
        lines.append("base_prefix=\(wideString(config.base_prefix))")
        lines.append("base_exec_prefix=\(wideString(config.base_exec_prefix))")
        lines.append("stdlib_dir=\(wideString(config.stdlib_dir))")
        lines.append("module_search_paths_set=\(config.module_search_paths_set)")
        lines.append("module_search_paths_count=\(config.module_search_paths.length)")
        if config.module_search_paths.length > 0, let items = config.module_search_paths.items {
            for index in 0..<Int(config.module_search_paths.length) {
                lines.append("module_search_paths[\(index)]=\(wideString(items[index]))")
            }
        }

        let path = directory + "/python-config-snapshot.txt"
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static var traceEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["JUSTBASH_TRACE_PYTHON"] == "1"
            || environment["JUSTBASH_SMOKE_PYTHON"] == "1"
    }

    private static func statusHasException(_ status: PyStatus) -> Bool {
        PyStatus_Exception(status) != 0
    }

    private static func statusMessage(_ status: PyStatus) -> String {
        let errorText = if let err = status.err_msg {
            String(cString: err)
        } else {
            "unknown Python status error"
        }
        if let function = status.func {
            return "\(String(cString: function)): \(errorText)"
        }
        return errorText
    }

    private static func wideString(_ pointer: UnsafeMutablePointer<wchar_t>?) -> String {
        guard let pointer else {
            return "<nil>"
        }
        let count = Int(wcslen(pointer))
        return pointer.withMemoryRebound(to: UInt32.self, capacity: count) { utf32Pointer in
            String(decoding: UnsafeBufferPointer(start: utf32Pointer, count: count), as: UTF32.self)
        }
    }

    private static func failureResult(error: Error) -> PythonExecResult {
        PythonExecResult(stdout: "", stderr: error.localizedDescription + "\n", exitCode: 1)
    }
}

private struct OutputFilePaths {
    let stdout: String
    let stderr: String
    let exitCode: String

    init(baseDirectory: String) {
        stdout = baseDirectory + "/stdout.txt"
        stderr = baseDirectory + "/stderr.txt"
        exitCode = baseDirectory + "/exit-code.txt"
    }

    func readResult() -> PythonExecResult {
        let stdoutText = (try? String(contentsOfFile: stdout, encoding: .utf8)) ?? ""
        let stderrText = (try? String(contentsOfFile: stderr, encoding: .utf8)) ?? ""
        let exitCodeText = (try? String(contentsOfFile: exitCode, encoding: .utf8)) ?? "1"
        let parsedExitCode = Int(exitCodeText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
        return PythonExecResult(stdout: stdoutText, stderr: stderrText, exitCode: parsedExitCode)
    }
}

enum PythonExecutionError: LocalizedError {
    case executionFailed(Int32)
    case decodeLocale(String)
    case statusFailure(String, String)

    var errorDescription: String? {
        switch self {
        case .executionFailed(let status):
            return "Python execution failed with status \(status)."
        case .decodeLocale(let value):
            return "Unable to decode locale string for \(value)."
        case .statusFailure(let stage, let message):
            return "Python \(stage) failed: \(message)"
        }
    }
}
#else
enum PythonSupport {
    static var isAvailable: Bool { false }

    static func availabilitySummary() -> String {
        "BeeWare Python support is not linked yet."
    }

    static func run(
        code: String,
        workspacePath: String,
        arguments: [String] = [],
        scriptName: String = "<justbash-python>",
        scriptPath: String? = nil
    ) -> PythonExecResult {
        PythonExecResult(stdout: "", stderr: PythonExecutionError.notLinked.localizedDescription + "\n", exitCode: 1)
    }
}

enum PythonExecutionError: LocalizedError {
    case notLinked

    var errorDescription: String? {
        switch self {
        case .notLinked:
            return "Python support is not linked into this build yet."
        }
    }
}
#endif
