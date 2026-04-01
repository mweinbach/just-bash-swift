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
    ],
    targets: [
        .target(
            name: "JustBashFS",
            path: "Sources/JustBashFS",
            sources: ["VirtualFileSystem.swift"]
        ),
        .target(
            name: "JustBashCommands",
            dependencies: ["JustBashFS"],
            path: "Sources/JustBashCommands",
            sources: ["Commands.swift"]
        ),
        .target(
            name: "JustBashCore",
            dependencies: ["JustBashFS", "JustBashCommands"],
            path: "Sources/JustBashCore",
            sources: ["CoreShell.swift", "Parser.swift", "Interpreter.swift"]
        ),
        .target(
            name: "JustBash",
            dependencies: ["JustBashCore", "JustBashFS", "JustBashCommands"],
            path: "Sources/JustBash",
            sources: ["Bash.swift"]
        ),
        .testTarget(
            name: "JustBashFSTests",
            dependencies: ["JustBashFS"],
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
    ]
)
