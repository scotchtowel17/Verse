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

## Step G5 — Test coverage for the engine, persistence, and recording layer — DONE

The structural finding behind all of Phase G: 35 of ~70 suites cover `VerseAI`, while the
engine got 4, recording 2, and persistence 3. Every G-phase defect lived in the thin half.
Close the gap so this class of bug is caught by the harness rather than by review.

Add suites in `Sources/VerseCheck/`. Prefer real behavior over mocks; the engine can be built
and rendered offline (see the existing `renderOffline` usage in `CheckMultitrack.swift`), and
`RecoveryManager` and `ProjectPackage` take injectable directories.

1. **Engine graph lifecycle** (`CheckEngine.swift`): add/remove tracks repeatedly without leaks
   or throws; `reconfigure` on a project with many tracks leaves exactly the expected node set;
   `removeTrack` on an unknown id is a safe no-op; effects insert and remove cleanly and audio
   still flows through afterwards.
2. **Persistence round trips** (`CheckPersistence.swift`): save then read preserves every model
   field including `inserts`; a package missing `project.json` produces the readable error; a
   package whose media is unreadable reports the skipped names rather than failing the save;
   `extractMedia` reports failures instead of silently presenting an unplayable take.
3. **Recording** (`CheckRecording.swift`): `TakeRecorder` start/append/stop produces a readable
   file of the expected frame count; `stop()` twice is safe; `durationSeconds` is correct
   before and after stop; a zero-frame take reports no URL.
4. **Transport** (new `CheckTransport.swift`): scheduling a project with both audio and MIDI
   clips computes the arrangement end correctly; `stop()` cancels pending work so no note fires
   afterwards; a clip with a negative `startBeat` does not schedule a negative onset.

Do not change production behavior in this step. If a test reveals a real bug, STOP, write the
bug up in this file under a new heading, and report it rather than silently fixing it.

### Status (2026-07-25 PT)

All four G5 suites landed (tests only; no production edits). `swift build` succeeds.
`swift run VerseCheck` is red: **513 passed, 1 failed**. The failure is a real production
bug in `TakeRecorder.durationSeconds` after `stop()` (see next heading). G5 was BLOCKED until Bug G5-1 was fixed
until that bug is fixed and the harness is green; production was not patched in this step.

## Bug G5-1 — TakeRecorder.durationSeconds returns 0 after stop — FIXED

**Found by:** G5 suite `Recording G5: durationSeconds correct before and after stop`
**File:** `Sources/VerseEngine/TakeRecorder.swift`

### Symptom

After a non-empty take is stopped, `durationSeconds` returns `0` instead of
`frameCount / sampleRate`. Before `stop()` the same property is correct (e.g. 0.3s for
13230 frames at 44.1 kHz). `frameCount` is still correct after stop.

### Cause

`stop()` nils out the open `AVAudioFile` to flush and close it:

```swift
file = nil   // closes/flushes the AVAudioFile
```

`durationSeconds` only reads the sample rate from that file handle:

```swift
public var durationSeconds: Double {
    guard let file, file.fileFormat.sampleRate > 0 else {
        return 0
    }
    return Double(frameCount) / file.fileFormat.sampleRate
}
```

Once `file` is nil, the guard fails and the method returns 0 even when `frameCount > 0`.

### Why it matters

Callers that stop a take and then ask for its duration (UI labels, clip length, recovery
summaries) get a silent zero. The G5 contract requires duration to be correct before and
after stop.

### Suggested fix (do not apply under G5; tests-only step)

Retain the capture sample rate in a stored property set on `start`, and compute
`durationSeconds` from `frameCount` and that rate after the file is closed. Keep returning
0 when nothing was captured.

### Test lock

The failing assertion in `CheckRecording.swift` encodes the intended contract and must stay
failing until this bug is fixed (do not weaken it to match the broken return value).


**Resolution (G5-1):** `TakeRecorder` now captures `sampleRate` at `start` and computes
`durationSeconds` from it, so duration is correct both during capture and after `stop()` closes
the file. Latent only: production reads the value before `stop()` in
`VerseAudioEngine.stopRecording`, so no user-visible behavior changed. The G5 assertion stays
as the contract lock. 514 assertions green.

---

# Phase F — Sound that is actually good, and instruments that behave

Investigation before writing this: the SF2 was never fetched on this machine, so every preset
played the sampler's built-in default voice. "Grand Piano", "Warm Pad", and "Drum Kit" all
sounded identical, and the whole preset list was cosmetic. Fetching `GeneralUserGS.sf2`
(SHA-256 verified against THIRD-PARTY-LICENSES.md) fixed that instantly and the header badge
now reads "GeneralUser GS" instead of "Built-in voice". That is the single biggest sound win
available and it needed no code.

## Step F1 — Guarantee a built app has real sounds — DONE

The SF2 is gitignored by design and the app degrades gracefully without it, so a fresh clone
or a CI build silently produces an app where every instrument sounds the same.

1. `scripts/make-app.sh` fetches the SF2 when it is missing, before assembling the bundle.
2. Verify the download against the SHA-256 already recorded in THIRD-PARTY-LICENSES.md. On a
   checksum mismatch, do NOT bundle it: warn clearly and continue with the built-in voice.
   Never bundle an unverified binary.
3. Keep the graceful-degradation path intact (Build Contract section 9): no network, no SF2,
   the app must still build, launch, and make sound.
4. Do not commit the SF2. Do not change `.gitignore`.

## Step F2 — Separate track name from instrument — DONE

`TrackListView` binds the instrument Picker to `track.name`, and the preset tags are preset
names. A new project's track is named "Piano" while the preset is "Grand Piano", so **the
picker renders blank on every new project**. Worse, the two are conflated in both directions:
`selectPreset` overwrites `track.name`, so choosing an instrument renames the user's track;
and renaming a track (including via a Claude `renameTrack` patch) blanks its instrument.

1. Bind the Picker to the track's actual instrument identity (program + bankMSB + bankLSB),
   not to `track.name`. Match the current `Instrument` against the preset list so the correct
   preset always shows selected.
2. `selectPreset` must set the instrument and must NOT rename the track. Auto-naming a
   still-default track name is acceptable (for example a track literally named "Piano",
   "Instrument 2", or "Audio 3"), but a name the user or Claude chose must be preserved.
3. If the current instrument matches no curated preset (a Claude `setInstrument` patch can
   choose any GM program 0-127), show it honestly rather than blank: a "Custom (program N)"
   entry that is displayed but not selectable as a new choice.
4. Tests: a new project's track resolves to the Grand Piano preset; renaming a track leaves
   its instrument selection intact; `selectPreset` on a user-renamed track keeps the name;
   an off-list GM program resolves to the custom label instead of nothing.

## Step F3 — Curated preset list worth browsing — DONE

Only meaningful now that the SF2 is real. Expand `presets.json` from 7 to roughly 20-28
auditioned GM presets, grouped by the existing `category` field, covering at least Keys,
Guitar, Bass, Strings, Brass, Woodwind, Synth Lead, Pad, and Drums. Use standard GM program
numbers (bankMSB 121 for melodic, 120 for drums). Keep `fallbackPresets` in `SoundBank.swift`
in sync with the manifest. Group by category in the picker so a longer list stays scannable.

Do NOT add a phrase library in this phase; it is a separate capability with its own safety
questions and gets its own phase.

Constraints: no new dependencies, no schema change, `swift build` clean, `swift run VerseCheck`
green, app bundles and launches.

---

# Phase P — Piano roll (manual note editing)

The owner's most important feature, and it does not exist. Notes can only enter a project via
hum-to-MIDI or a Claude patch. There is no way to add, move, lengthen, or delete a single note
by hand. `PianoKeyboardView` is the on-screen keyboard for PLAYING notes; it is not an editor.

Target: notes drawn as horizontal blocks on a pitch-by-time grid that can be clicked, dragged,
lengthened, shortened, and deleted. Must feel obvious to a non-programmer songwriter.

## Step P1 — Note-level model helpers — DONE

Pure helpers on `Project` in `VerseModel`, alongside the existing clip helpers. Schema stays v1.

1. `addNote(toClip:pitch:startBeat:lengthBeats:velocity:) -> UUID` — rejects pitch outside
   0-127, `startBeat < 0`, `lengthBeats <= 0`.
2. `deleteNote(id:inClip:)`.
3. `moveNote(id:inClip:toPitch:toStartBeat:)` — same validation as add.
4. `resizeNote(id:inClip:toLengthBeats:)` — rejects `<= 0`; enforce a sensible minimum
   (one 1/32 beat) so a note can never become zero-length and invisible.
5. Reuse `MutationError` and add cases as needed. Every rejection carries a readable message.
6. Tests for each, including every rejection path and that editing one note leaves others
   untouched.

## Step P2 — Piano roll view, read-only first — DONE

Get rendering and layout right before any editing.

1. New `Sources/VerseAppCore/Views/PianoRollView.swift`.
2. Vertical axis is pitch with a piano-key gutter on the left (black/white keys aligned to the
   grid rows). Horizontal axis is beats, with bar lines heavier than beat lines.
3. Notes render as rounded horizontal blocks positioned by `startBeat`/`lengthBeats`/`pitch`.
4. A snap control offering 1/4, 1/8, 1/16 (match the existing quantize grids).
5. Scroll both axes; default the vertical scroll so the clip's existing notes are centered,
   and show a useful range (about 3 octaves) rather than all 128 pitches at once.
6. Opens for a selected MIDI clip. Add a way to reach it from the track row.

## Step P3 — Editing interactions — DONE

Standard piano-roll interactions, chosen because they are what every DAW does and therefore
what muscle memory expects:

- Click empty grid: add a note at that pitch and snapped beat, length = current snap value.
- Drag a note body: move it in pitch and time, snapped.
- Drag a note's right edge: lengthen or shorten, snapped, floored at the minimum.
- Click a note: select it. Delete or Backspace removes the selection.
- Clicking or dragging a note auditions that pitch through the engine so the user hears it.

**Undo grouping is the critical detail and it repeats a lesson already learned in this repo.**
A drag emits a continuous stream of updates. Recording undo per update would flood and flush
the 100-entry stack, exactly as `setVolume`/`setPan` would have. Record **one** undo entry per
completed gesture: snapshot on drag begin, mutate freely during the drag, and do not record
again until the next gesture starts. Label entries plainly: "Add Note", "Move Note",
"Resize Note", "Delete Note".

## Step P4 — Integration — PENDING

1. Reachable in an obvious way from the track row for MIDI clips, and for a track with no clip
   yet, an obvious way to create an empty clip and start drawing.
2. Edits go through the same autosave path as every other mutation.
3. Verify the piano roll and the Claude patch flow do not fight: a patch that adds or
   quantizes notes must be reflected when the roll is open.
4. Transport playhead drawn over the grid during playback if it is cheap to do; if it costs
   more than a little, say so and defer it rather than half-building it.

Constraints: no new dependencies, no schema change, `swift build` clean, `swift run VerseCheck`
green, app bundles and launches. Do not weaken any existing safety behavior.

## Step P2b — Piano roll view corrections (found by running it) — DONE

The read-only roll renders, but opening it on a real clip shows an EMPTY grid while the header
says "6 notes". Verified live with a 6-note melody at pitches 60-67:

1. **Default vertical scroll does not centre on the clip's notes.** P2 item 5 required this and
   it was not done. The roll opens parked around C8/C9 while the melody sits at C4. The user
   opens their clip and sees nothing. Fix: on open, centre the viewport on the mean pitch of
   the clip's notes (fall back to middle C for an empty clip).
2. **The pitch range is effectively unnavigable.** All 128 pitches are laid out and 25 scroll
   ticks moved roughly one octave. P2 item 5 asked for a bounded useful range. Fix: show about
   3 octaves around the content, and make scrolling cover ground at a sane rate.
3. **Duplicate "Snap" label** in the toolbar: it currently reads "Snap Snap 1/4 1/8 1/16".
4. **The sheet is cramped.** Give the roll a substantially larger default size and let it
   resize; a piano roll is the primary editing surface, not a dialog.

## Step P3 — Editing interactions — DONE

See the Phase P section above for the full interaction list and the undo-grouping requirement.
Implement it now, on top of the P2b corrections.

Restating the one thing that must not be got wrong: **record exactly one undo entry per
completed gesture.** Snapshot on gesture begin, mutate freely during the drag, do not record
again until the next gesture. Per-update recording would flood and flush the 100-entry stack,
which is the same failure mode `setVolume`/`setPan` were deliberately excluded from undo to
avoid. Labels: "Add Note", "Move Note", "Resize Note", "Delete Note".

Also required:
- Clicking or dragging a note auditions that pitch through the engine.
- A note can never be resized to zero length and become invisible.
- Edits route through the same autosave path as every other mutation.
- Remove the "Read-only preview; drawing notes comes next" banner once editing works.
