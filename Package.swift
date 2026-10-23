// swift-tools-version: 6.2
import PackageDescription

// Meeting Intelligence — native macOS meeting recorder, transcriber and analyst.
//
// Module graph (lower layers never import higher ones):
//
//   MeetingCore      Domain model, persistence (GRDB/SQLite + FTS5), search, export,
//                    AI provider contracts, security. No audio, no ML, no UI.
//   MeetingAudio     Capture (Core Audio process taps + AVAudioEngine) and DSP utilities.
//   MeetingSpeech    FluidAudio integration: Parakeet Ultra ASR, offline diarization,
//                    speaker recognition, and the processing pipeline.
//   MeetingSemantic  Local text embeddings (multilingual-e5-small) for semantic search.
//                    Optional, opt-in; the MCP server does not link it.
//   MeetingIntelligenceApp   SwiftUI application (executable).
//   MeetingMCPServer         Read-only MCP server over stdio (executable).
//   MeetingIntelligenceCLI   Headless diagnostics and processing (executable).
//   MeetingReleaseTool       `mi-release`: signs update archives for publishing (not bundled).

let strictConcurrency: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "MeetingIntelligence",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "MeetingIntelligence", targets: ["MeetingIntelligenceApp"]),
        .executable(name: "meeting-intelligence-mcp", targets: ["MeetingMCPServer"]),
        .executable(name: "mi", targets: ["MeetingIntelligenceCLI"]),
        // Publisher-only: signs update archives (TD-29). Not bundled in the app.
        .executable(name: "mi-release", targets: ["MeetingReleaseTool"]),
        .library(name: "MeetingCore", targets: ["MeetingCore"]),
    ],
    dependencies: [
        // Pinned exactly: ASR/diarization behaviour is part of the product contract.
        // NemoTextProcessing trait disabled — we use ASR and diarization only (no TTS/ITN).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        // Text embeddings via MLTensor (TD-25). swift-collections pinned: 1.7.x does not build with CLT 27 + SDK 26.5.
        .package(url: "https://github.com/jkrukowski/swift-embeddings", exact: "0.1.1"),
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.2.1"),
    ],
    targets: [
        .target(
            name: "MeetingCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "MeetingAudio",
            dependencies: ["MeetingCore"],
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "MeetingSpeech",
            dependencies: [
                "MeetingCore",
                "MeetingAudio",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "MeetingSemantic",
            dependencies: ["MeetingCore", .product(name: "Embeddings", package: "swift-embeddings")],
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "MeetingIntelligenceApp",
            dependencies: ["MeetingCore", "MeetingAudio", "MeetingSpeech", "MeetingSemantic",
                           .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: strictConcurrency + [
                .defaultIsolation(MainActor.self),
            ]
        ),
        .executableTarget(
            name: "MeetingMCPServer",
            dependencies: ["MeetingCore", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "MeetingIntelligenceCLI",
            dependencies: ["MeetingCore", "MeetingAudio", "MeetingSpeech", "MeetingSemantic",
                           .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "MeetingReleaseTool",
            dependencies: ["MeetingCore"],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "MeetingCoreTests",
            dependencies: ["MeetingCore", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "MeetingAudioTests",
            dependencies: ["MeetingAudio", "MeetingCore"],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "MeetingSpeechTests",
            dependencies: ["MeetingSpeech", "MeetingAudio", "MeetingCore", .product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "MeetingSemanticTests",
            dependencies: ["MeetingSemantic", "MeetingCore"],
            swiftSettings: strictConcurrency
        ),
        // App logic (services and settings); views are verified with snapshots (TD-15).
        .testTarget(
            name: "MeetingIntelligenceAppTests",
            dependencies: ["MeetingIntelligenceApp", "MeetingCore", "MeetingAudio", "MeetingSpeech",
                           .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: strictConcurrency + [
                .defaultIsolation(MainActor.self),
            ]
        ),
    ]
)
