// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeUsageWidget",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: transcript parsing, pricing, aggregation. No UI, fully testable.
        .target(name: "UsageCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "ClaudeUsageWidget",
            dependencies: ["UsageCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The terminal side: a Claude Code hook and status line command. UsageCore only, so it starts fast.
        .executableTarget(name: "kaikei-advise", dependencies: ["UsageCore"], path: "Sources/KAIkeiAdvise", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"]),
    ]
)
