import Foundation

/// A JavaScript module that should be discoverable via `require()` inside `js-exec`.
///
/// Hosts can ship app-specific JS libraries by conforming to this protocol and
/// passing instances through `BashJavaScriptOptions.addonModules`. The module's
/// `source` is evaluated as a CommonJS-style IIFE on first import; the value
/// assigned to `module.exports` becomes the require result.
public protocol JavaScriptModule: Sendable {
    /// The name passed to `require()` (e.g. `"my-utils"`, `"@org/helpers"`).
    var name: String { get }
    /// The CommonJS source. Evaluated once per `js-exec` invocation on first import.
    var source: String { get }
}

/// Configuration for the embedded JavaScriptCore-backed `js-exec` runtime.
///
/// Pass through `JavaScriptRuntime(options:)` and into `BashOptions.embeddedRuntimes`
/// to expose `js-exec` inside the bash sandbox.
public struct BashJavaScriptOptions: Sendable {
    /// JS source prepended to every `js-exec` invocation, after the bridges install
    /// but before user code. Use to seed app-wide globals or polyfills.
    public var bootstrap: String?
    /// Modules discoverable via `require(name)` from inside `js-exec`.
    public var addonModules: [any JavaScriptModule]
    /// Wall-clock timeout for a single `js-exec` invocation.
    public var defaultTimeoutMs: Int
    /// Wall-clock timeout when network access is enabled (i.e. allowedURLPrefixes is non-empty).
    public var defaultNetworkTimeoutMs: Int

    public init(
        bootstrap: String? = nil,
        addonModules: [any JavaScriptModule] = [],
        defaultTimeoutMs: Int = 10_000,
        defaultNetworkTimeoutMs: Int = 60_000
    ) {
        self.bootstrap = bootstrap
        self.addonModules = addonModules
        self.defaultTimeoutMs = defaultTimeoutMs
        self.defaultNetworkTimeoutMs = defaultNetworkTimeoutMs
    }
}
