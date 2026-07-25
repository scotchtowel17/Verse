// swift-tools-version:6.0
import PackageDescription

// Verse — native macOS songwriting/recording app.
// Pure Swift + Apple frameworks. No C/C++ targets, no cxxLanguageStandard (Build Contract §D).
// Built with SwiftPM (this machine has Command Line Tools, not full Xcode); the executable
// is wrapped into a code-signed Verse.app by scripts/make-app.sh.
//
// Language mode 5 is used across targets per Build Contract §A ("language mode 5 acceptable
// initially; strict concurrency where practical"); a Swift-6 strict-concurrency hardening
// pass is a later, non-blocking refinement.

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Verse",
    // Floor is macOS 14 so #available(macOS 26, *) guards around Music Understanding stay
    // meaningful; the package builds against the macOS 26 SDK on this machine.
    platforms: [.macOS("14.0")],
    products: [
        .executable(name: "Verse", targets: ["Verse"])
    ],
    targets: [
        // ── Model: data model + schema versioning/migration. Imports no UI, no Engine.
        .target(name: "VerseModel", swiftSettings: swift5),

        // ── Engine: AVAudioEngine graph, sampler, recording, metering. Imports no UI.
        //    Resources/ holds the curated preset manifest and (optionally) the bundled SF2;
        //    the SF2 is fetched by scripts/fetch-artifacts.sh and is gitignored.
        .target(
            name: "VerseEngine",
            dependencies: ["VerseModel"],
            resources: [.copy("Resources")],
            swiftSettings: swift5
        ),

        // ── Persistence: .verse package IO, atomic save, journal + crash recovery. No UI.
        .target(
            name: "VersePersistence",
            dependencies: ["VerseModel"],
            swiftSettings: swift5
        ),

        // ── Commands: command pattern + undo/redo. No UI.
        .target(
            name: "VerseCommands",
            dependencies: ["VerseModel"],
            swiftSettings: swift5
        ),

        // ── AI: verse-patch request builder, lenient parser, validator, applier. Model+Commands only.
        .target(
            name: "VerseAI",
            dependencies: ["VerseModel", "VerseCommands"],
            swiftSettings: swift5
        ),

        // ── Analysis: Music Understanding (canImport-gated) + manual tap-tempo/key fallback.
        .target(
            name: "VerseAnalysis",
            dependencies: ["VerseModel"],
            swiftSettings: swift5
        ),

        // ── Plugins: Audio Unit discovery (insertion lives in VerseEngine). Leaf module.
        .target(
            name: "VersePlugins",
            dependencies: ["VerseModel", "VerseEngine"],
            swiftSettings: swift5
        ),

        // ── AudioToMIDI: Basic Pitch CoreML (gated on artifact) + monophonic fallback. Leaf.
        .target(
            name: "VerseAudioToMIDI",
            dependencies: ["VerseModel"],
            resources: [.copy("Resources")],
            swiftSettings: swift5
        ),

        // ── App core: AppStore + SwiftUI views. Library so VerseCheck can import and test it.
        //    The Verse executable is a thin @main shim that imports this module.
        .target(
            name: "VerseAppCore",
            dependencies: ["VerseModel", "VerseEngine", "VersePersistence", "VerseCommands",
                           "VerseAI", "VerseAnalysis", "VersePlugins", "VerseAudioToMIDI"],
            swiftSettings: swift5
        ),

        // ── App: thin @main entry point only. Logic lives in VerseAppCore.
        .executableTarget(
            name: "Verse",
            dependencies: ["VerseAppCore"],
            swiftSettings: swift5
        ),

        // ── Verification harness (runs the spec's required checks; works under CLT and Xcode).
        //    Invoked by `swift run VerseCheck`. Grows per milestone.
        .executableTarget(
            name: "VerseCheck",
            dependencies: ["VerseModel", "VerseEngine", "VersePersistence", "VerseCommands",
                           "VerseAI", "VerseAnalysis", "VersePlugins", "VerseAudioToMIDI",
                           "VerseAppCore"],
            swiftSettings: swift5
        ),
    ]
)
