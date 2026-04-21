import Foundation
import JustBashCommands

/// Embeds the JavaScriptCore-backed `js-exec` command in a bash sandbox.
///
/// Construct one of these with the desired `BashJavaScriptOptions` and pass it
/// through `BashOptions.embeddedRuntimes`. The runtime owns a single
/// `JSCEngine` actor that creates a fresh `JSContext` per invocation.
///
/// ```swift
/// let bash = Bash(options: .init(
///     allowedURLPrefixes: ["https://api.example.com/"],
///     embeddedRuntimes: [
///         JavaScriptRuntime(options: BashJavaScriptOptions(
///             bootstrap: "globalThis.APP_NAME = 'demo';"
///         ))
///     ]
/// ))
/// let result = await bash.exec("js-exec -c 'console.log(APP_NAME)'")
/// // result.stdout == "demo\n"
/// ```
public struct JavaScriptRuntime: EmbeddedRuntime {
    private let engine: JSCEngine

    public init(options: BashJavaScriptOptions = .init()) {
        self.engine = JSCEngine(options: options)
    }

    public func commands() -> [AnyBashCommand] {
        [makeJsExecCommand(engine: engine)]
    }
}
