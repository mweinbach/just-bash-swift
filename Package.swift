// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JustBash",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .macCatalyst(.v18),
    ],
    products: [
        .library(name: "JustBash", targets: ["JustBash"]),
        .library(name: "JustBashJavaScript", targets: ["JustBashJavaScript"]),
        .executable(name: "TokenizerBenchmark", targets: ["TokenizerBenchmark"]),
    ],
    targets: [
        .target(
            name: "JustBashFS",
            path: "Sources/JustBashFS",
            sources: [
                "VirtualFileSystem.swift",
                "FilesystemProtocol.swift",
                "OverlayFileSystem.swift",
                "ReadWriteFileSystem.swift",
                "MountableFileSystem.swift",
            ]
        ),
        .target(
            name: "JustBashCommands",
            dependencies: ["JustBashFS"],
            path: "Sources/JustBashCommands"
        ),
        .target(
            name: "JustBashCore",
            dependencies: ["JustBashFS", "JustBashCommands"],
            path: "Sources/JustBashCore"
        ),
        .target(
            name: "JustBash",
            dependencies: ["JustBashCore", "JustBashFS", "JustBashCommands"],
            path: "Sources/JustBash",
            sources: ["Bash.swift"]
        ),
        .target(
            name: "JustBashJavaScript",
            dependencies: ["JustBashCommands", "JustBashFS", "JustBashCore"],
            path: "Sources/JustBashJavaScript",
            resources: [.process("Resources")],
            linkerSettings: [.linkedFramework("JavaScriptCore")]
        ),
        .testTarget(
            name: "JustBashJavaScriptTests",
            dependencies: ["JustBashJavaScript", "JustBash", "JustBashFS"],
            path: "Tests/JustBashJavaScriptTests"
        ),
        .testTarget(
            name: "JustBashFSTests",
            dependencies: ["JustBashFS", "JustBash"],
            path: "Tests/JustBashFSTests"
        ),
        .testTarget(
            name: "JustBashCoreTests",
            dependencies: ["JustBash", "JustBashCore", "JustBashFS", "JustBashCommands"],
            path: "Tests/JustBashCoreTests"
        ),
        .testTarget(
            name: "JustBashCommandTests",
            dependencies: ["JustBash", "JustBashCommands", "JustBashFS"],
            path: "Tests/JustBashCommandTests"
        ),
        .testTarget(
            name: "JustBashParityTests",
            dependencies: ["JustBash"],
            path: "Tests/JustBashParityTests"
        ),
        .executableTarget(
            name: "TokenizerBenchmark",
            dependencies: ["JustBashCore"],
            path: "Benchmarks/TokenizerBenchmark"
        ),
    ]
)
