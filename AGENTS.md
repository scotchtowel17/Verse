# Verse — Worker Instructions

Native macOS (Apple Silicon) songwriting/recording app. Pure Swift, SwiftUI, AVAudioEngine.
No external dependencies. Build with `swift build`. Test with `swift run VerseCheck`.

## Non-negotiable principles

1. **Safety and truthfulness before features.** Every failure mode must produce a clear,
   honest, plain-language message. The app owner is not a programmer.
2. **No silent no-ops reported as success.** If an operation cannot be performed, it must
   throw or reject with a readable message, never return quietly.
3. **Preview shows what the validated ops will do, never Claude's prose summary.**
4. **Continuous UI gestures (volume/pan sliders) must never destroy the undo stack.**
5. **Preserve exact current user-visible behavior** unless the step explicitly changes it.
6. **No new external dependencies. Ever.**
7. **No em-dashes in code comments, strings, or documentation.** Use commas, colons,
   periods, or parentheses.

## Architecture

- `VerseModel` — `Project`, `Track`, `Clip`, `Note`, `Schema`, `Migration`. Pure value types.
  Imports no UI and no audio frameworks. Schema is at v1 and stays at v1 unless a step says otherwise.
- `VerseEngine` — `VerseAudioEngine`, `Transport`, `Metronome`, `SoundBank`, metering.
- `VersePersistence` — `ProjectPackage` (.verse file package), `RecoveryManager` (journal,
  autosave, crash recovery).
- `VerseCommands` — `UndoStack`, `ProjectCommand`.
- `VerseAI` — the Claude bridge: `RequestBuilder` -> `PatchParser` -> `PatchValidator` ->
  `PatchApplier`, faced by `Copilot`.
- `VerseCheck` — the verification harness. This is the test suite. Run it after every change.
- `Verse` — the app target: `AppStore` (main-actor `@Observable` state) plus SwiftUI views.

## The AI patch pipeline (treat as load-bearing)

The safety model is: **parse -> validate -> transactional apply -> one undo group.**

- `PatchParser` is deliberately lenient about locating JSON in prose. Do not make it stricter.
- `PatchValidator` collects **all** errors before rejecting. Never early-return on the first
  error. Never let a validation failure mutate anything.
- Track handles (`T1`, `T2`, ...) and clip handles (`T2C1`, ...) are **positional**, computed
  from array order. They are resolved to UUIDs at validation time so that later ops in the
  same patch cannot be corrupted by earlier ones. Preserve that property.
- `PatchApplier` throws on any unresolvable reference. Do not reintroduce silent `if let` skips.
- A whole patch is one `PatchCommand` and therefore one undo group.

## Conventions

- Swift 6 toolchain, but the package is **not** in strict-concurrency mode. Do not enable it.
- `AppStore` is `@MainActor @Observable`. Stored properties and timers live in `AppStore.swift`
  only. Extensions may hold methods, never stored properties.
- Engine and realtime work never blocks the main actor. `Transport` schedules on main
  deliberately (see its doc comment); do not "optimize" that onto a background queue.
- User-facing strings use curly quotes for quoted names, matching existing code.
- Prefer small, reviewable diffs. Do not reformat untouched code. Do not rename things that
  the step did not ask you to rename.

## Testing

`swift run VerseCheck` must exit 0 with all assertions passing before you report a step done.
When a step adds behavior, add assertions to the matching `Check*.swift` file. Tests live in
`Sources/VerseCheck/`. Follow the existing `tk.suite { }` / `tk.check(...)` style.

Never mark a step complete on a build alone. Build success is not test success.

## Out of scope (do not do these unprompted)

- Coordinator/service-object extraction from `AppStore`
- Piano-roll editor, automation lanes
- Direct Claude API calls (the clipboard round-trip is intentional: privacy, no API key)
- Schema version bumps
- Any operation that authors musical content freely (harmony/melody generation)
- Strict concurrency hardening
