# Verse — Worker Instructions

Native macOS (Apple Silicon) songwriting/recording app. Pure Swift, SwiftUI, AVAudioEngine.
No external dependencies. Build with `swift build`. Test with `swift run VerseCheck`.

## How to work: the decision sequence

Standing directive from the project owner. Full text: `docs/engineering-principles.md`, which is
the authority if this summary is ever unclear. **The order matters.**

1. **Define the actual objective.** What outcome is wanted, what must change, what must stay the
   same, how success will be verified. A step's proposed implementation is not the objective;
   preserve the objective and choose the simplest safe implementation of it.
2. **Inspect before acting.** Trace the real execution path, tests, call sites and conventions.
   Never rewrite from an assumption about how the system probably works. Read narrowly but
   sufficiently.
3. **Challenge every requirement.** Treat each as provisional until backed by the objective,
   behavior that must be preserved, a test, an external contract, or a real constraint. Do not
   follow a comment, a legacy pattern, or a prior implementation without verifying it still
   applies. If a step in the plan is wrong, say so rather than implementing it.
4. **Eliminate before adding.** Prefer, in order: remove a requirement, delete obsolete code,
   reuse an existing function, fix a small defect, extend an existing pattern, add new code, add
   an abstraction or dependency. No speculative config, premature abstraction, unused
   flexibility, or fallbacks that hide defects.
5. **Simplify what remains.** Direct control flow, small focused functions, narrow interfaces,
   local reasoning, predictable failure modes. Fewer lines is not the measure; another engineer
   understanding it quickly is.
6. **Make the smallest correct change.** Do not use a narrow task as licence to clean up
   surrounding code. Broaden scope only when the current structure prevents a correct solution,
   and only as far as needed.
7. **Correctness before optimization.** Optimize only with evidence, never a hypothetical
   bottleneck, and never at the cost of comprehensibility.
8. **Verify with reality.** Assert observable outcomes, not intent. Test the success path and the
   meaningful failure cases. When fixing a defect, add the test that would have caught it. State
   plainly what was tested and what remains unverified; never claim success you did not verify.
9. **Increase the rate of learning.** Change one meaningful variable, observe, then proceed. If
   the same approach fails twice, the approach is the problem: stop and re-decompose rather than
   attempting it a third time.
10. **Handle errors explicitly**, protect **security and data integrity**, and **respect existing
    contracts** (signatures, schemas, file formats, user-visible output, error semantics).
11. **Report precisely.** Distinguish verified behavior from reasoned conclusions, assumptions,
    and untested areas. Do not bury a failure or partial verification.

A change must be correct, necessary, simple, scoped, safe, tested, maintainable, and honest.
The job is the simplest verified solution to the real problem.

## Non-negotiable principles

1. **Safety and truthfulness before features.** Every failure mode must produce a clear,
   honest, plain-language message. The app owner is not a programmer.
2. **No silent no-ops reported as success.** If an operation cannot be performed, it must
   throw or reject with a readable message, never return quietly.
3. **Preview shows what the validated ops will do, never Claude's prose summary.**
4. **Continuous UI gestures (volume/pan sliders) must never destroy the undo stack.**
5. **Preserve exact current user-visible behavior** unless the step explicitly changes it.
6. **No new external dependencies. Ever.**
7. **No em-dashes in code comments or documentation you write.** Use commas, colons,
   periods, or parentheses. Existing user-facing product copy is the owner's voice: leave it
   alone unless a step explicitly asks you to change it.

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

**No wall-clock upper bounds in tests.** CI runners are loaded and slow, so an assertion like
"this finished within N seconds" measures machine load, not behavior, and will fail randomly.
If timing matters, record when the event actually fired (in its callback) and assert only the
bound that carries meaning, which is almost always the lower one: "it waited for X rather than
finishing early at Y." A flaky test is worse than no test, because it teaches everyone to
ignore red.

## Out of scope (do not do these unprompted)

- Coordinator/service-object extraction from `AppStore`
- Piano-roll editor, automation lanes
- Direct Claude API calls (the clipboard round-trip is intentional: privacy, no API key)
- Schema version bumps
- Any operation that authors musical content freely (harmony/melody generation)
- Strict concurrency hardening
