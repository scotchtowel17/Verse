import Foundation

/// A tiny, dependency-free test harness.
///
/// Why not XCTest / Swift Testing? This project is built with Command Line Tools (no full
/// Xcode), and neither XCTest.framework nor the Testing library ships with CLT — so
/// `swift test` cannot run here. `VerseCheck` is an ordinary executable that runs the same
/// spec-required checks (model round-trip, verse-patch fixtures, render determinism, crash
/// recovery) and exits non-zero on failure. It runs identically under CLT and full Xcode,
/// and CI invokes it with `swift run VerseCheck`.
public final class TestKit {
    public struct Failure { let suite: String; let name: String; let message: String }
    private(set) var failures: [Failure] = []
    private var passed = 0
    private var currentSuite = "—"

    public init() {}

    public func suite(_ name: String, _ body: () throws -> Void) {
        currentSuite = name
        print("▶︎ \(name)")
        do { try body() }
        catch {
            record(name: "(threw)", "unexpected error: \(error)")
        }
    }

    public func expect(_ condition: Bool, _ name: String,
                       _ message: @autoclosure () -> String = "") {
        if condition { pass(name) } else { record(name: name, message().isEmpty ? "expected true" : message()) }
    }

    public func expectEqual<T: Equatable>(_ a: T, _ b: T, _ name: String) {
        if a == b { pass(name) } else { record(name: name, "expected \(b), got \(a)") }
    }

    public func expectThrows(_ name: String, _ body: () throws -> Void) {
        do { try body(); record(name: name, "expected an error, none thrown") }
        catch { pass(name) }
    }

    public func expectNoThrow(_ name: String, _ body: () throws -> Void) {
        do { try body(); pass(name) }
        catch { record(name: name, "unexpected error: \(error)") }
    }

    private func pass(_ name: String) { passed += 1; print("   ✓ \(name)") }

    private func record(name: String, _ message: String) {
        failures.append(.init(suite: currentSuite, name: name, message: message))
        print("   ✗ \(name) — \(message)")
    }

    /// Print a summary and terminate the process with an appropriate exit code.
    public func finish() -> Never {
        print("\n──────────────────────────────")
        if failures.isEmpty {
            print("✅ ALL CHECKS PASSED  (\(passed) assertions)")
            exit(0)
        } else {
            print("❌ \(failures.count) FAILURE(S), \(passed) passed:")
            for f in failures { print("   • [\(f.suite)] \(f.name): \(f.message)") }
            exit(1)
        }
    }
}
