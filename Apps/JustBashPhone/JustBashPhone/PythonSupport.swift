import Foundation

#if canImport(Python)
import Python

enum PythonSupport {
    static var isAvailable: Bool { true }

    static func availabilitySummary() -> String {
        "BeeWare Python support is linked."
    }

    static func run(code: String, workspacePath: String) -> Result<String, Error> {
        let pythonHome = pythonHomePath()
        let traceDir = workspacePath

        writeTrace("entered", to: traceDir)
        setenv("LANG", "\(Locale.current.identifier).UTF-8", 1)
        writeTrace("after-lang", to: traceDir)

        var preconfig = PyPreConfig()
        var config = PyConfig()
        PyPreConfig_InitIsolatedConfig(&preconfig)
        PyConfig_InitIsolatedConfig(&config)
        preconfig.utf8_mode = 1
        preconfig.configure_locale = 1
        config.use_system_logger = 1
        config.buffered_stdio = 0
        config.write_bytecode = 0
        config.install_signal_handlers = 1
        writeTrace("after-config-init", to: traceDir)

        var status = Py_PreInitialize(&preconfig)
        guard !statusHasException(status) else {
            PyConfig_Clear(&config)
            return .failure(PythonExecutionError.statusFailure("preinitialize", statusMessage(status)))
        }
        writeTrace("after-preinitialize", to: traceDir)

        guard let homeWide = Py_DecodeLocale(pythonHome, nil) else {
            PyConfig_Clear(&config)
            return .failure(PythonExecutionError.decodeLocale("pythonHome"))
        }
        defer { PyMem_RawFree(homeWide) }

        withUnsafeMutablePointer(to: &config) { configPtr in
            withUnsafeMutablePointer(to: &configPtr.pointee.home) { homePtr in
                status = PyConfig_SetString(configPtr, homePtr, homeWide)
            }
        }
        guard !statusHasException(status) else {
            PyConfig_Clear(&config)
            return .failure(PythonExecutionError.statusFailure("set-home", statusMessage(status)))
        }
        writeTrace("after-set-home", to: traceDir)

        status = PyConfig_Read(&config)
        guard !statusHasException(status) else {
            PyConfig_Clear(&config)
            return .failure(PythonExecutionError.statusFailure("read-config", statusMessage(status)))
        }
        writeConfigSnapshot(config, to: traceDir)
        writeTrace("after-config-read", to: traceDir)

        let argv: [UnsafeMutablePointer<CChar>?] = [
            strdup("JustBashPhone")
        ]
        defer {
            for arg in argv {
                free(arg)
            }
        }

        status = argv.withUnsafeBufferPointer { buffer in
            PyConfig_SetBytesArgv(&config, buffer.count, UnsafeMutablePointer(mutating: buffer.baseAddress))
        }
        guard !statusHasException(status) else {
            PyConfig_Clear(&config)
            return .failure(PythonExecutionError.statusFailure("set-argv", statusMessage(status)))
        }
        writeTrace("after-argv", to: traceDir)

        status = Py_InitializeFromConfig(&config)
        guard !statusHasException(status) else {
            PyConfig_Clear(&config)
            return .failure(PythonExecutionError.statusFailure("initialize", statusMessage(status)))
        }
        writeTrace("after-initialize", to: traceDir)
        defer {
            Py_Finalize()
            PyConfig_Clear(&config)
        }

        let bootstrap = """
        import sys
        sys.path.insert(0, \(pythonStringLiteral(appPath())))
        """
        let bootstrapStatus = PyRun_SimpleString(bootstrap)
        writeTrace("after-bootstrap-\(bootstrapStatus)", to: traceDir)
        guard bootstrapStatus == 0 else {
            return .failure(PythonExecutionError.executionFailed(bootstrapStatus))
        }

        let runStatus = PyRun_SimpleString(code)
        writeTrace("after-code-\(runStatus)", to: traceDir)
        if runStatus == 0 {
            return .success("python finished successfully")
        }
        return .failure(PythonExecutionError.executionFailed(runStatus))
    }

    private static func pythonHomePath() -> String {
        Bundle.main.path(forResource: "python", ofType: nil)
            ?? (Bundle.main.resourceURL?.path ?? NSTemporaryDirectory()) + "/python"
    }

    private static func appPath() -> String {
        Bundle.main.path(forResource: "app", ofType: nil)
            ?? (Bundle.main.resourceURL?.path ?? NSTemporaryDirectory()) + "/app"
    }

    private static func pythonStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
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

    static func run(code: String, workspacePath: String) -> Result<String, Error> {
        .failure(PythonExecutionError.notLinked)
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
