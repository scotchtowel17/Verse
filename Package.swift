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

        // ── App: @main SwiftUI app + views. Depends on everything; grows per milestone.
        .executableTarget(
            name: "Verse",
            dependencies: ["VerseModel"],
            swiftSettings: swift5
        ),

        // ── Verification harness (runs the spec's required checks; works under CLT and Xcode).
        //    Invoked by `swift run VerseCheck`. Grows per milestone.
        .executableTarget(
            name: "VerseCheck",
            dependencies: ["VerseModel"],
            swiftSettings: swift5
        ),
    ]
)
