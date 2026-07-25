# Verse — Safety Foundations + Controlled Expansion

Branch: `phase-a-safety`. Baseline: `2c451f8`.
State legend: PENDING / IN PROGRESS / DONE / BLOCKED.

Each step must leave `swift build` clean and `swift run VerseCheck` exiting 0.

---

## Step 1 — A3 corrections — DONE

Close the defects found in the A3 review.

1. `PatchValidator.resolveClip`: when a clip handle resolves, verify it belongs to the track
   named in the op's `track` field. On mismatch, error: `Clip "T3C2" isn't on track "T1".`
2. `PatchApplier.resolveClipLocation`: the `.existing` case carries a comment claiming an
   "optional ownership sanity check" that does not exist. Ownership is now enforced in the
   validator, so delete the misleading comment.
3. `Copilot.apply`: apply to a local `var working = project` and assign back to `project` only
   on success. Today a throw mid-apply leaves the caller's `inout` partially mutated. It is
   safe only because `AppStore` happens to pass a scratch copy; make it safe on its own terms.
4. `PatchApplier.apply`: thread the op index into every thrown `PatchError` so messages render
   as "Operation 3: ..." instead of losing the location. Iterate `ops.enumerated()`.
5. `RequestBuilder`: `var clipDict` is never mutated. Make it `let`.
6. Tests in `CheckPatch.swift`: addNotes to an existing clip adds notes; deleteClip on an
   existing clip removes it; a clip handle naming the wrong track is rejected; an unresolvable
   reference surfaces a rejection rather than a silent success.

## Step 2 — A1 project fingerprint — DONE

Close the staleness hole. Handles are positional; without this they can silently resolve to
the wrong track or clip if the project changes between "Copy request" and "Apply".

1. `VerseModel`: add `Project.structuralFingerprint` — an 8-hex-character digest over ordered
   track UUIDs and, per track, its ordered clip UUIDs. **Structural input only.** Do not
   include `modifiedAt`, `tempoBPM`, `key`, names, or any field that changes without changing
   handle meaning. Implement the digest with Foundation only (no CryptoKit dependency is
   needed; a stable FNV-1a or similar over the UUID string is fine, but it must be
   deterministic across runs and platforms).
2. `RequestBuilder`: emit `"fingerprint": "<8 hex>"` inside `verseRequest`, and instruct Claude
   in the prose preamble to copy the `fingerprint` value verbatim into the patch.
3. `PatchParser.ParsedPatch`: add a `fingerprint: String?` field populated from the patch object.
4. `PatchValidator`: compare against the live project and distinguish the two cases.
   - Missing: `Claude left out the project code. Ask it to include the fingerprint field exactly.`
   - Mismatch: `Your project changed since you copied this request. Copy a fresh one.`
5. Tests: matching fingerprint passes; mismatched rejects with the mismatch message; absent
   rejects with the missing message; a tempo or title change alone does NOT invalidate a
   fingerprint; adding or deleting a clip DOES.

## Step 3 — A2 undo hygiene — DONE

1. `UndoStack` stores a label alongside each state. Expose `undoName` / `redoName`.
   `record(_ state:name:)`. Keep the 100-entry limit.
2. `VerseApp` Edit menu shows the label ("Undo Add Track") and disables when nothing to undo.
3. `AppStore.history.clear()` in `newProject()`, `openPackage()`, and `applyRecovery()`.
4. Record undo on discrete actions only: `addInstrumentTrack`, `addAudioTrack`, `deleteTrack`,
   `selectPreset`, `setTempo`, `setKey`, `stopRecording`, `analyzeLastTake` (snapshot inside
   the `MainActor.run`, immediately before the mutation, not before the `Task`), plus the
   existing `applyCopilotReply` and `humToMIDIFromLastTake`.
5. `setVolume` / `setPan` must NOT record. A slider drag emits ~100 calls and would flush the
   entire 100-entry stack, destroying the AI-patch undo point. Leave a comment saying so.

## Step 4 — B file organization — DONE

Split `AppStore.swift` into extensions. No behavior change, no logic edits.
`AppStore+Transport.swift`, `AppStore+Persistence.swift`, `AppStore+Copilot.swift`.
All stored properties, timers, `init`, and lifecycle stay in `AppStore.swift`.
Widen `private` to `internal` only where a move requires it.

## Step 5 — C mutation helpers — DONE

Pure helpers on `Project` / `Track` in `VerseModel`. Schema stays v1.

1. `moveClip(id:toStartBeat:)` — reject `startBeat < 0` (transport drops negative-onset MIDI
   notes and clamps audio, so a negative start is silently partly inaudible).
2. `duplicateClip(id:)` — regenerate the clip UUID **and** every contained `Note` UUID.
   Place the copy at `startBeat + lengthBeats`.
3. `quantizeNotes(in:to:)` — grids 1/4, 1/8, 1/16. Pin the semantics in a doc comment:
   nearest-grid, note **starts only**, lengths untouched, notes never moved past the clip end.
4. Do NOT add `resizeClip` (see Step 7). Do NOT add `gain`, `color`, or `locked`.
5. Tests for each, including the rejection cases and note-id regeneration.

## Step 6 — D mandatory preview — DONE

1. Split `Copilot.apply` into `preview(reply:project:) -> Result<Success, ...>` and
   `commit(ops:to:)`. Keep `apply` as a thin wrapper if anything still needs it.
2. Add a plain-English renderer that builds its description **exclusively from validated
   `TypedOp` values**. Never from `parsed.summary`. Group large note additions
   ("Track 4 'Bass': add 64 notes"). Include clamp notices. For `deleteClip` on an audio clip,
   say which take is being removed.
3. `CopilotPanel`: a modal sheet showing the rendered ops with Apply / Cancel. Claude's own
   summary, if shown, is labeled "Claude says:" and is never the approval text.
4. Re-check the fingerprint at commit time, and disable transport/record commands while the
   sheet is up (a SwiftUI sheet does not disable `CommandGroup` menu items on its own).
5. Tests for the renderer: it never emits `parsed.summary`, and it names the right tracks.

## Step 7 — E AI expansion — DONE

Add ops to `versePatchOps`, `TypedOp`, `RequestBuilder.capabilityOps`, validator, applier,
and the preview renderer.

1. `quantizeNotes` — reject audio clips.
2. `transposeNotes` — reject audio clips; validate resulting pitches stay within 0-127 and
   **reject** rather than clamp.
3. `moveClip` — `startBeat` is honored by the transport for both clip kinds.
4. `deleteClip` already works after Step 1.

**Do NOT add `resizeClip`.** `Clip.lengthBeats` is not honored during playback: audio duration
comes from the file itself and MIDI notes are not clipped at the clip boundary. It would change
the loop length while changing nothing audible. Reintroduce only after the transport enforces
`lengthBeats` as a hard boundary.

**Do NOT add `setClipGain`** (no per-clip gain path in the mixer) **or `addHarmony`** (free-form
content authoring is a different safety category).

Clamp policy: reject with a readable message. The existing `setTrackMix` volume/pan clamping
stays as a deliberate exception.

---

## Deferred (not in this pass)

- Coordinator extraction (revisit only above ~1,200 lines in `AppStore` and with test coverage)
- Transport honoring `lengthBeats`, which would unblock `resizeClip`
- Phase F: curated presets, licensed phrase library

## Step 8 — Edit menu undo/redo never updates (found by smoke test) — DONE

Live defect found by running the app: after adding a track, Edit shows a greyed-out "Undo"
with no label, and Cmd-Z does nothing. The undo stack itself is correct (Step 3 tests pass);
the menu is what is broken, and it predates Step 3.

Root cause: `.commands { }` lives in `App.body`, which does NOT participate in `@Observable`
change tracking. `store.canUndo` / `store.undoName` are read once when the scene is built
(both empty at launch) and never re-read, so the item stays permanently disabled.

Fix: move the observable reads into a **View** body, which does track observation.

1. Add `struct UndoRedoCommands: Commands` holding the `AppStore`.
2. Inside it, `CommandGroup(replacing: .undoRedo) { UndoRedoMenuContent(store: store) }`.
3. `private struct UndoRedoMenuContent: View` reads `store.undoName`, `store.canUndo`,
   `store.redoName`, `store.canRedo` in its `body` and renders the two buttons with their
   keyboard shortcuts and `.disabled(...)`.
4. Use it from `VerseApp.commands`.
5. Audit the other command groups for the same latent bug and note anything that reads
   observable state at scene-build time.

Acceptance: after adding a track, Edit reads "Undo Add Track" and is enabled; Cmd-Z removes
the track; after undo, Edit reads "Redo Add Track". Verified by running the app, not by tests.

### Step 8, attempt 2 (attempt 1 verified FAILED in a live run)

Wrapping the buttons in a `Commands` struct that holds the store did NOT fix it. Verified by
running the app: after adding a track, Edit still shows a greyed, unlabeled "Undo" and Cmd-Z
does nothing. `.commands` does not re-evaluate from `@Observable` state at all, no matter how
the reads are nested, because the menu is built once per scene.

The supported SwiftUI mechanism for driving menu state from window content is `FocusedValue`.

1. New file `Sources/Verse/UndoFocus.swift`:
   - `struct UndoMenuState: Equatable { var canUndo: Bool; var undoName: String?;
     var canRedo: Bool; var redoName: String? }`
   - `struct UndoMenuStateKey: FocusedValueKey { typealias Value = UndoMenuState }`
   - `extension FocusedValues { var undoMenuState: UndoMenuState? { get/set } }`
2. `ContentView` publishes it:
   `.focusedSceneValue(\.undoMenuState, UndoMenuState(canUndo: store.canUndo,
   undoName: store.undoName, canRedo: store.canRedo, redoName: store.redoName))`
   ContentView is a View, so it re-evaluates on observation and re-publishes.
3. The undo/redo `Commands` struct reads `@FocusedValue(\.undoMenuState) private var undoState`
   and drives BOTH the label and `.disabled(...)` from it. The button actions may still call
   `store.undo()` / `store.redo()` directly; only label and enablement need to be reactive.

Fallback if `FocusedValue` still does not refresh in a live run: remove `.disabled(...)`
entirely and use static "Undo" / "Redo" labels. `AppStore.undo()` already guards internally,
so an always-enabled item is a safe no-op when the stack is empty. A working Cmd-Z with a
generic label beats a permanently dead menu item. Say clearly in your report which path you
took and why.

## Step 9 — Make AppStore testable, then test the undo contract — DONE

Step 8 was a bug that made undo permanently dead and survived every test, because `AppStore`
lives in the `Verse` executable target and no test target can import an executable. Close that
structural gap.

1. **New library target `VerseAppCore`** in `Package.swift` containing everything currently in
   `Sources/Verse/` EXCEPT the `@main` entry point: `AppStore.swift`, the three `AppStore+*`
   extensions, `ContentView.swift`, `UndoFocus.swift`, and `Views/`.
   Same dependencies the `Verse` target has today.
2. **`Verse` executable becomes a thin shim**: only `VerseApp.swift` with `@main`, importing
   `VerseAppCore`. Move nothing else into it.
3. Add `public` where the shim and tests now require it. Do not widen more than necessary,
   and do not change any logic.
4. **Testability injection**: `AppStore.init` currently hardcodes `RecoveryManager()`, which
   writes to the real Application Support directory. Add an optional parameter so a test can
   pass a temporary directory (`RecoveryManager` already accepts a `baseDir`). Default
   behavior must be identical when the parameter is omitted.
5. `VerseCheck` gains a dependency on `VerseAppCore` and a new `CheckAppStore.swift` asserting
   the undo contract that Steps 3 and 6 established:
   - `addInstrumentTrack` / `addAudioTrack` / `deleteTrack` / `setTempo` / `setKey` /
     `selectPreset` each push exactly one undo entry, with the expected label
   - `setVolume` and `setPan` push NOTHING, even when called 200 times in a row, and an
     earlier undo entry is still present afterward (this is the regression that would
     otherwise silently destroy the AI-patch undo point)
   - `newProject()` clears the stack, so undo cannot resurrect the previous document
   - `undo()` restores the prior state and `undoName` / `redoName` report the right labels
   - applying a validated patch through the copilot path records exactly one undo entry
     for the whole patch (one undo group)

Constraints: no behavior change, no schema change, `swift build` clean, `swift run VerseCheck`
green, and the app must still launch (`scripts/make-app.sh` then open the bundle).

Note honestly in your report what this does NOT cover: SwiftUI view rendering and macOS menu
behavior still cannot be reached from `VerseCheck`. Step 8's exact bug would still require a
manual run to catch.

---

# Phase G — Safety parity for the audio and state layer

Phase A hardened the AI layer. These are the equivalent defects one layer down, found by an
objective review at `037caff`. Same rules: no silent state lies, no silent no-ops, honest
messages, no behavior change beyond what each step names.

## Step G1 — Effects truth — DONE

Today `setEffect` records the chosen kind in `AppStore.trackEffects` while the engine holds the
actual node in `trackNodes`. `syncEngineToProject()` calls `engine.reconfigure`, which calls
`reset()` -> `removeTrack` on every track and destroys every effect node. `trackEffects` is
never cleared. `syncEngineToProject` runs on undo, redo, and every applied Claude patch, so a
track's effect silently disappears while the UI picker still shows it.

Separately, `Track.inserts: [AudioUnitRef]` is persisted schema that no code anywhere reads or
writes, so effects also vanish on save and reopen with no message.

1. **Survive reconfigure.** After `engine.reconfigure(with:)` in `syncEngineToProject()`,
   re-apply the built-in effect for every track that still exists, and drop `trackEffects`
   entries whose track is gone. Effects must survive undo, redo, and patch apply.
2. **Persist built-in effects.** Write the chosen `BuiltInEffect` into the track's existing
   `inserts: [AudioUnitRef]` on change, and restore it on open. Use a clear marker, for example
   `AudioUnitRef(type: "aufx", subtype: <kind.rawValue>, manufacturer: "verse.builtin",
   name: <kind.label>)`. **The schema already has this field. Do NOT bump `Schema.current`.**
   A project with no `inserts` must load exactly as it does today.
3. **Hosted third-party Audio Units stay session-only.** Restoring them needs `stateBlob` work
   that is out of scope. Do not pretend otherwise: when a hosted AU is dropped by a reconfigure,
   set that track's `trackEffects` entry correctly and surface a plain status message such as
   "Reverted <track> to no effect (hosted plug-ins are not restored yet)." Never leave the UI
   claiming an effect that is not in the graph.
4. Tests: an effect survives a round trip through `syncEngineToProject`; `trackEffects` never
   names a track that does not exist; a built-in effect survives save then open; a v1 project
   with no `inserts` still opens unchanged.

## Step G3 — Workspace retention — DONE

Two opposite failures today. Clean quit calls `endSessionCleanly(clearMedia: false)`, so every
take ever recorded accumulates forever in Application Support. Meanwhile `discardRecovery()`
calls `endSessionCleanly(clearMedia: true)`, which deletes the ENTIRE Media directory, including
takes belonging to other saved projects.

1. **Prune on clean quit.** Delete only workspace media files not referenced by any clip in the
   current project. Keep everything referenced.
2. **Stop the catastrophic delete.** `discardRecovery()` must remove the recovery artifacts
   (session lock, journal, autosave) and at most the single in-progress take named in the
   journal. It must NOT remove the Media directory.
3. Add `RecoveryManager.pruneMedia(keeping:)` taking the set of referenced filenames. Keep it
   pure and testable against a temporary directory.
4. Tests, all against a temp `baseDir`: prune keeps referenced files and removes unreferenced
   ones; `discardRecovery` leaves unrelated takes on disk; prune on an empty set does not throw.

Constraint for both steps: `swift build` clean, `swift run VerseCheck` green, app still bundles
and launches.

## Step G4 — Crash-shape hardening — DONE

Four small independent fixes from the same review. Two are unreproduced crash shapes; fix them
because each is a few lines, but do not claim they were observed.

1. **Audition format mismatch (possible hard crash).** `VerseAudioEngine.playFile` connects
   `auditionPlayer` using the FIRST file's `processingFormat` and reuses that connection for
   every later file. `scheduleFile` with a mismatched format raises an AVAudioEngine exception
   that Swift cannot catch. Triggered by changing audio interface or sample rate mid-session and
   then auditioning an older take. Fix: track the format the audition player is connected with,
   and when a new file's `processingFormat` differs, disconnect and reconnect at the new format
   before scheduling.
2. **Tap removed before detach (possible crash).** `installMeterTaps` installs a tap on each
   track mixer, but `removeTrack` detaches the mixer without ever calling `removeTap(onBus: 0)`.
   Only the input node is ever untapped. This path runs on every reconfigure. Fix: call
   `removeTap(onBus: 0)` on the track mixer (and on the master mixer in `reset()`, resetting
   `masterMeterInstalled`) before detaching.
3. **Launch-time force unwrap.** `RecoveryManager.init` does `.first!` on the Application
   Support URL list. Replace with a graceful fallback (for example the temporary directory)
   rather than trapping before any UI exists.
4. **Duplicate track UUIDs load as a permanently silent track.** `configure` calls
   `addInstrumentTrack`/`addAudioTrack`, which return `false` when the id already exists, and
   nobody checks the result. A corrupted or hand-edited `.verse` yields a track that is visible
   but silent forever with no error. Fix: on load, detect duplicate track ids and either
   re-key them or surface a clear message. Do not fail the open silently.
5. Also remove the dead `let solos = false` in `VerseAudioEngine.applyMix`, which reads as if
   solo were handled there when it is handled in `AppStore.applyEffectiveMix`.
6. Tests where practical: audition across two different formats does not throw; `removeTrack`
   after `installMeterTaps` leaves no tap installed; `RecoveryManager` still works with an
   injected base dir; a project with duplicate track ids opens with a clear outcome.
