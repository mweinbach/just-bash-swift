import Foundation

/// Accumulates stdout/stderr text emitted by JS code during a single `js-exec`
/// invocation. The engine drains the buffers when execution completes and
/// folds them into the returned `ExecResult`.
///
/// Reference type: shared between the engine actor and `@convention(block)`
/// closures installed into the JS context. Only the engine reads/writes after
/// execution, so internal locking is unnecessary as long as JS code does not
/// move the capture across actor boundaries.
final class JSCStreamCapture: @unchecked Sendable {
    private(set) var stdout = ""
    private(set) var stderr = ""

    func writeStdout(_ text: String) {
        stdout += text
    }

    func writeStderr(_ text: String) {
        stderr += text
    }

    func appendLineToStdout(_ text: String) {
        stdout += text
        if !text.hasSuffix("\n") { stdout += "\n" }
    }

    func appendLineToStderr(_ text: String) {
        stderr += text
        if !text.hasSuffix("\n") { stderr += "\n" }
    }
}
