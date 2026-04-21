import Foundation
import JavaScriptCore

/// Composes all bridges into a single boot step. The order matters:
/// process+console first (so other bridges can observe the capture streams),
/// then FS, then network, then child_process, finally the require resolver
/// (it inspects the globals the others install).
func installBridges(into context: JSContext, execution: JSCExecutionContext) {
    installProcessBridge(into: context, execution: execution)
    installFSBridge(into: context, execution: execution)
    installFetchBridge(into: context, execution: execution)
    installChildProcessBridge(into: context, execution: execution)
    installRequireResolver(into: context, execution: execution)
}
