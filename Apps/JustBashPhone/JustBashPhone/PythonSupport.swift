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
        let pythonPath = [
            pythonHome + "/lib/python3.14",
            pythonHome + "/lib/python3.14/lib-dynload",
        ].joined(separator: ":")

        setenv("PYTHONHOME", pythonHome, 1)
        setenv("PYTHONPATH", pythonPath, 1)

        Py_Initialize()
        defer { Py_Finalize() }

        let bootstrap = """
        import sys
        sys.path[:] = [p for p in "\(pythonPath)".split(":") if p]
        """
        _ = PyRun_SimpleString(bootstrap)
        let status = PyRun_SimpleString(code)
        if status == 0 {
            return .success("python finished successfully")
        } else {
            return .failure(PythonExecutionError.executionFailed(status))
        }
    }

    private static func pythonHomePath() -> String {
        let resources = Bundle.main.resourceURL?.path ?? NSTemporaryDirectory()
        return resources + "/PythonSupport"
    }
}

enum PythonExecutionError: LocalizedError {
    case executionFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .executionFailed(let status):
            return "Python execution failed with status \(status)."
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
