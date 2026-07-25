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

## Step P4 — Integration — DONE

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

## Step P5 — Short notes cannot be moved (found by running it) — DONE

Verified live: the resize hit zone is a fixed pixel width taken from the right edge of a note.
On a note only 1/16 long, that zone covers essentially the whole block, so dragging it always
resizes and it can never be moved. Since 1/16 is the default snap and a newly added note is
exactly one snap unit long, **every note the user draws is unmovable until they lengthen it.**

Fix: make the resize zone proportional and bounded, for example
`min(fixedEdgeWidth, noteWidth * 0.3)`, so the middle of even the shortest note always moves.
Consider a cursor change over the resize zone so the two behaviours are discoverable.

## Step P4 — Piano roll integration — DONE

1. A track with no MIDI clip needs an obvious way to create an empty clip and start drawing.
   Today the roll can only be opened for a clip that already exists, so a brand-new project
   has no path into the editor at all.
2. Confirm edits route through the same autosave path as every other mutation.
3. A patch applied while the roll is open must be reflected in the roll.
4. Draw the transport playhead over the grid during playback if it is cheap. If it is not,
   say so and defer rather than half-building it.

## Step P6 — Snap off, for free manual positioning — DONE

Owner request: keep the grid snap for note start and length, but allow turning it OFF so a
note can be dragged to an exact manual position and length.

The math already supports this: `PianoRollView.snap(_:)` has `guard snapBeats > 0 else
{ return beats }`. Snap-off is simply never offered in the UI.

1. Snap control becomes **Off | 1/4 | 1/8 | 1/16**, with `Off` tagged `0.0`. Keep 1/16 as the
   default so existing behaviour is unchanged until the user opts out.
2. With snap Off, move, resize, and add must all be continuous, with no rounding of start
   position or length.
3. **New-note length when snap is Off.** Today a new note's length is `max(snapBeats,
   minimumNoteLengthBeats)`. With `snapBeats == 0` that collapses to the 1/32 minimum, so
   clicking would produce a near-invisible sliver. Instead remember the last non-zero grid
   value (default 1/16) and use that as the drawn length when snap is Off. The user can then
   drag it to any exact length they want.
4. The minimum length guard stays in force with snap Off: a note must never reach zero and
   become invisible.
5. The choice persists for the session while the roll is open.
6. Tests: with snap Off a move lands on an unrounded start beat and a resize produces an
   unrounded length; with snap on 1/8 both are rounded to 0.5; a note added with snap Off has
   the remembered grid length, not the 1/32 minimum; the minimum guard still holds with snap Off.

Do not add a modifier-key snap override in this step; the request was a toggle.

---

# Phase M — MIDI input (Akai MPK mini and any class-compliant controller)

Owner has an Akai MPK mini (Special Edition Black): 25 velocity-sensitive keys, 8 pads,
8 knobs, arpeggiator, octave up/down. Verse currently has **no MIDI input whatsoever** —
zero CoreMIDI usage anywhere in the codebase. This is a new subsystem.

Note: the device was NOT attached while this was built, so nothing here is verified against
the real hardware. Everything must therefore be verified against a virtual MIDI source, and
any claim about the physical controller must be stated as unverified.

## Step M1 — MIDI input engine — DONE

1. New `Sources/VerseMIDI/` target (CoreMIDI is an Apple system framework; add
   `.linkedFramework("CoreMIDI")` if SwiftPM needs it). It must import no UI.
2. Create a MIDI client and an input port, enumerate sources, and connect to them.
   Handle **hot-plug**: sources appearing or disappearing while the app runs must be picked up
   (observe `MIDIClientCreateWithBlock` notifications or re-scan on change).
3. Decode at minimum: note on, note off, and control change, with channel and velocity.
   **Treat note-on with velocity 0 as note-off** — most controllers including the MPK mini
   send that, and missing it leaves permanently stuck notes.
4. **Threading is the correctness risk.** CoreMIDI delivers on a high-priority MIDI thread.
   `VerseAudioEngine` is documented main-thread-only. Every dispatch into the engine must hop
   to the main actor. Never call the engine from the MIDI callback thread.
5. Expose a small, testable surface: a parse function from raw MIDI bytes to a typed event
   (pure, unit-testable) plus a delegate/callback for live events.
6. Publish the list of connected source names so the UI can show what is attached.

## Step M2 — Play the active instrument from the controller — DONE

1. `AppStore` subscribes to MIDI events and routes note on/off to the active instrument track
   with the incoming **velocity** (do not flatten to a constant).
2. Incoming notes light up the on-screen keyboard using the existing `heldNotes` set, so the
   two input paths look identical to the user.
3. Show connected device names in the header area, in plain language: "Akai MPK mini connected"
   when present, and something honest when nothing is attached. Never claim a device that is
   not there.
4. Panic / all-notes-off must clear notes originating from MIDI too.
5. The app must launch and work normally with **no** MIDI device attached, and must not block,
   hang, or prompt at startup.

## Step M3 — Record MIDI input into a clip — DONE

The real songwriting payoff: play the controller during playback and capture it.

1. While the transport is playing and recording is armed, incoming note on/off are captured as
   `Note` values with correct `startBeat` and `lengthBeats` derived from the transport position.
2. Captured notes land in a MIDI clip on the armed instrument track, creating the clip if none
   exists, and appear in the piano roll afterwards.
3. One undo entry for the whole captured take, labelled "Record MIDI".
4. A note still held when recording stops is closed out at the stop position rather than left
   with zero or infinite length.

## Testing without the hardware

The physical MPK mini is unavailable. Test end-to-end against a **virtual MIDI source** created
in the harness (`MIDISourceCreate` plus `MIDIReceived`), which exercises real CoreMIDI delivery,
the thread hop, and decoding. Cover at minimum: note on, note off, note-on-velocity-0 as
note-off, velocity preserved, and a stuck-note check. State clearly in the report that the
physical device is unverified.

## Step M2b — MIDI hot-plug is broken (found by running it) — DONE

Verified live against a virtual CoreMIDI source named "MPK mini TEST":

- A source that exists **before** Verse launches is found correctly. The header reads
  "MPK mini TEST connected" and played notes light up the on-screen keyboard, so the whole
  path (CoreMIDI to parser to main actor to engine to UI) is sound.
- A source that appears **after** Verse is already running is never noticed. The header stays
  on "No MIDI controller connected" and notes are ignored.

This is the common real-world case: the owner will open Verse and then plug in the MPK mini.
M1 item 2 required hot-plug and it does not work.

Fix: react to CoreMIDI setup changes. Use the notification block passed to
`MIDIClientCreateWithBlock` and handle `kMIDIMsgSetupChanged` (and/or object added/removed) by
re-enumerating sources and connecting any new ones, disconnecting any that vanished. Update the
published device-name list so the header follows. Do not leak connections when a source is
re-added, and do not connect the same source twice.

Test: with the harness's virtual source, create it AFTER the input engine has started and
assert it becomes connected and delivers events; then dispose it and assert it is dropped from
the connected list.

## Step M4 — Record arm has no visible state — PENDING

Found while testing M3 by hand. Clicking the transport record button produces no visual change:
the button looks identical armed and unarmed, so there is no way to tell whether a take is
being captured. For a non-programmer this is the difference between "I recorded that" and
"I lost that". MIDI capture itself is covered by tests but could not be confirmed by hand
because the armed state could not be established or observed.

1. Give the record button a clear armed appearance (colour/fill), and a distinct appearance
   again while actually capturing during playback.
2. Surface a plain-language status while armed, for example "Armed. Press play to record what
   you play." and while capturing, "Recording what you play…".
3. If arming fails (no audio input, for instance) say so; never leave the control looking armed
   when it is not, and never leave it looking unarmed when it is.
4. Confirm by hand afterwards that arm plus play plus incoming MIDI produces a clip.

---

# Phase I — Richer instruments

## Step I1 — Expand curated presets over the existing bank — PENDING

GeneralUser GS ships 261 presets and 13 drum kits. Verse exposes 29 presets and exactly ONE
drum kit. This is free variety with zero licence risk and no new download.

1. Expand `presets.json` to roughly 60-80 auditioned GM presets, keeping the existing
   `category` grouping and adding categories as needed (Organ, Synth Pad, Ethnic, Percussion,
   Sound Effects).
2. **Expose the drum kits.** Bank 120 carries multiple kits at different program numbers
   (Standard 0, Room 8, Power 16, Electronic 24, TR-808 25, Jazz 32, Brush 40, Orchestra 48,
   SFX 56). Give them clear plain-language names. Verify each program actually loads rather
   than assuming; drop any that do not.
3. Keep `fallbackPresets` in `SoundBank.swift` in sync with the manifest.
4. The picker must stay scannable at this size: keep the category grouping and make sure a
   long list does not become a wall of names.

## Step I2 — Optional higher-quality bank (MuseScore General) — PENDING

Licence verified directly at source, not assumed:
`https://ftp.osuosl.org/pub/musescore/soundfont/MuseScore_General/MuseScore_General_License.md`
states MIT, copyright Michael Cowgill (2014-16) and Frank Wen (2000-2002, 2008), with no
restriction on redistribution or commercial use beyond retaining the notice. MIT is already on
the licence-gate allowlist.

- File: `MuseScore_General.sf2`, version 0.2, roughly 210 MB, uncompressed.
- Source: `https://ftp.osuosl.org/pub/musescore/soundfont/MuseScore_General/`
- NOTE: the `.sf3` variant is Ogg-compressed and **will not load** in `AVAudioUnitSampler`.
  Use the `.sf2` only.

1. Add it to `scripts/fetch-artifacts.sh` behind an explicit opt-in flag (it is ~7x the size of
   the current bank). Record its real SHA-256 on first download.
2. Add a THIRD-PARTY-LICENSES.md entry with `SPDX-License-Identifier: MIT`, both copyright
   holders, and the source URL, so the licence gate sees it.
3. `SoundBank` gains a second logical bank. `Instrument.sf2` is already a logical bank name in
   the schema, so **no schema change is needed**.
4. If the file is absent, everything must behave exactly as today with GeneralUser GS. Absence
   is the normal case and must never be an error.
5. Keep it gitignored. Do not commit a 210 MB binary.

## Step M4 — Record arm has no visible state (see Phase M) — PENDING

Implement M4 as already specified above in the Phase M section.

## Step I1b — VerseCheck hangs after the I1/M4 changes — DONE

**True root cause (not the selectPreset / CoreMIDI hypotheses):** the new M4 suite (and any
later MIDI-record suite) calls `AppStore.startRecording()` → `VerseAudioEngine.startRecording(to:)`
→ `avEngine.inputNode`. On a bare CLI process (VerseCheck has no `NSMicrophoneUsageDescription`),
reading `inputNode` enables the hardware input device and then **blocks forever** inside
CoreAudio (`EnableInputDevice` → `CreateIOProcID` → `_TellServerAboutStreamUsage` / `mach_msg`),
instead of throwing. Sample stacks confirmed the hang even with M4 isolated (no MIDI clients,
no expanded preset loads). The earlier F2 suite name in the plan was a mis-attribution: stdout
buffering / progress made it look like selectPreset, but the blocked frame is always
`startRecording` on the M4 path. Instrument soft-fail for MIDI arm never ran because the hang
is before any throw.

**Fix:** `VerseAudioEngine.canSafelyOpenInputNode` preflights mic permission + presence of
`NSMicrophoneUsageDescription` on `Bundle.main`. When unsafe, `startRecording` throws
`noInputAvailable` (AppStore soft-fails into MIDI-only arm) and `setMonitoring` / `stopRecording`
never touch `inputNode` without a live tap. Verse.app still has the usage string and attempts
the real HAL path. Regression suite: `Recording I1b: startRecording refuses mic when process
cannot open input`.

## Step I2 — MuseScore General as the preferred bank — DONE

Verified before writing this step, not assumed:

- Licence: **MIT**, confirmed at
  `https://ftp.osuosl.org/pub/musescore/soundfont/MuseScore_General/MuseScore_General_License.md`
  Copyright Michael Cowgill (2014-16) and Frank Wen (2000-2002, 2008). No restriction on
  redistribution or commercial use beyond retaining the notice. MIT is already on the
  licence-gate allowlist.
- File: `MuseScore_General.sf2`, 215,614,036 bytes.
  SHA-256 `ee51d2c4b1525e70f19a45909c4fd7a2e26d91d115fa89dbf5a6bc413d8b9bf3`
- Loads correctly in `AVAudioUnitSampler`: Grand Piano, Slap Bass, Strings, Trumpet,
  Standard Kit and TR-808 Kit all loaded (6/6), including bank 120 drum kits.
- It uses the same GM program/bank numbering, so the existing 70-preset manifest works
  unchanged against either bank.
- The `.sf3` variant is Ogg-compressed and will NOT load. Use `.sf2` only.

1. `SoundBank` gains a second logical bank, `MuseScoreGeneral`. Preference order when
   resolving an instrument: the bank named on the instrument if that file is present, else the
   other bundled bank, else the sampler's built-in voice. Absence is normal and never an error.
2. **New** instruments default to the MuseScore General bank name so new songs get the better
   sound. **Existing saved projects keep whatever bank name they stored**, so a song that was
   written against GeneralUser GS still loads GeneralUser GS and does not silently change
   character. No schema change: `Instrument.sf2` is already a logical bank name.
3. `scripts/fetch-artifacts.sh` fetches it behind an explicit opt-in flag (it is ~7x the size of
   the current bank), verifying the SHA-256 above and refusing to keep an unverified file.
4. `scripts/make-app.sh` bundles it **only if already present**. It must NOT auto-fetch it.
   CI runs make-app.sh on every push and already downloads the 31 MB bank; adding a 206 MB
   download per run would make CI slow and flaky.
5. Add a `THIRD-PARTY-LICENSES.md` entry with `SPDX-License-Identifier: MIT`, both copyright
   holders, the source URL, the byte count and the SHA-256, so the licence gate sees it.
6. Add `MuseScore_General.sf2` to `.gitignore`. Do not commit a 206 MB binary.
7. The header badge must name whichever bank is actually in use, so it never claims a sound
   the app is not producing.
8. Tests must pass with the file ABSENT (that is the CI case) and must not assume either bank.

---

# Phase H — Battle hardening (remote, no screen required)

## Step H1 — Record can freeze the whole app — DONE

**Real, user-facing, and structurally invisible to CI.** Proven with `sample` on a hung process:

```
AppStore.startRecording()                       AppStore.swift:621
  VerseAudioEngine.startRecording(to:)          +Recording.swift:25
    -[AVAudioEngine inputNode]
      AVAudioEngineImpl::UpdateInputNode
        AVAudioIOUnit_OSX::EnableInputDevice
          BindToDeviceInternal
            -[AUHALOutputUnit setDeviceID:error:]   <- blocked indefinitely
```

`let input = avEngine.inputNode` blocks forever when the input device cannot be bound (no
permission, contended device, unentitled binary). `startRecording` runs on the main actor, so
**pressing Record freezes the entire app**. The existing
`guard fmt.channelCount > 0` was meant to catch "no input" but runs AFTER the blocking call.

CI cannot catch this: the runner has no audio device, so it takes a different path. This is why
the earlier mic guard was reverted. That revert was my mistake; the instinct was right and only
the assertion was wrong.

1. Before touching `avEngine.inputNode`, do a **non-blocking** pre-check:
   - Query the HAL for a default input device
     (`AudioObjectGetPropertyData` / `kAudioHardwarePropertyDefaultInputDevice`). If it is
     `kAudioObjectUnknown`, throw `noInputAvailable`.
   - Check microphone authorization non-blockingly
     (`AVCaptureDevice.authorizationStatus(for: .audio)`). If denied or restricted, throw a
     distinct, readable error such as "Verse doesn't have permission to use the microphone."
2. Only after both pass may `avEngine.inputNode` be touched.
3. Recording must never be able to hang the main actor. If binding can still be slow, that work
   belongs off the main actor with a bounded wait and a readable failure.
4. **Test the property, not the environment.** The reverted test asserted
   `startRecording` must throw `noInputAvailable`, which is false on a machine that has a mic,
   and that is why it failed CI. The correct assertion is that `startRecording` **returns**
   (throws or succeeds) within a bounded time and never hangs. That holds on every machine.

## Step H2 — Fuzz and property tests — DONE

Everything below is headless and needs no screen or hardware. Use a seeded, deterministic
pseudo-random generator so failures reproduce; never `Date()` or unseeded randomness.

Harness: `Sources/VerseCheck/CheckFuzz.swift` (`SeededRNG` + suites), wired from `main.swift`
via `runFuzzChecks`. Defect write-ups are under **H2 defects found** below.

1. **`PatchParser` fuzz.** DONE. Fixed adversarial corpus + 200 trials seed `0xA11CE001`.
   Property holds: always `ParsedPatch` or `ParseError`.
2. **`PatchValidator` property test.** DONE. Multi-error collection, reject mutates nothing,
   accepted ops apply. **H2-VAL-1** closed in H3 (`deleteClip` invalidates the handle).
3. **MIDI parser fuzz.** DONE. No-crash + every emitted event in 0…127 (including hostile
   high-bit / real-time mid-data). **H2-MIDI-1** closed in H3. Seeds `0xD1D1F002`, `0xC0FFEE01`.
4. **Model round-trip property test.** DONE. 80 seeded trials (`0xA011D7A1`) plus dense
   control case (`0xC017A01D`): encode → decode → re-encode byte-identical; fingerprint stable.
5. **Migration hostility.** DONE. 17 malformed/truncated/wrong-type `project.json` inputs all
   throw a non-empty error; missing package `project.json` is readable `PackageError`.
   Future `schemaVersion` found **H2-MIG-1** (FIXED in H4).
6. **Scale.** DONE. Seed `0x5CA1E7E57`: 50 tracks × 400 notes = 20,000 notes. Save/load
   (JSON + `.verse` package), fingerprint, and `PianoRollLayout` all succeed; layout covers
   global and per-track pitch ranges. Timings printed (no flaky wall-clock upper bound).

Report anything these find as a defect write-up, not a silent fix.

## H2 defects found — DO NOT silent-fix

Found by the Step H2 fuzz/property harness on 2026-07-25.
Production code was left unchanged for open defects; tests document them and assert the
properties that still hold. Close each write-up when the fix lands and rewrite the
matching suite in `Sources/VerseCheck/CheckFuzz.swift`.

### H2-VAL-1 — `deleteClip` does not invalidate the clip handle for later ops — CLOSED (H3)

**Surface:** `PatchValidator` then `PatchApplier`.

**Was:** A patch that deletes a clip and then operates on the same positional handle
validated successfully, then threw on apply.

**Fix (H3):** On accepted `deleteClip`, remove the handle from `clipHandles` and
`tempClips` (and `clipNotePitches` as before) so later ops report “Unknown clip”
and the whole patch is rejected at validation. There is no `deleteTrack` patch op,
so track-handle invalidation does not apply.

Harness: suite `H3 VAL-1 fix — deleteClip then use same handle is rejected at validation`.

### H2-MIDI-1 — parser emits note/CC fields outside 0…127 on hostile streams — CLOSED (H3)

**Surface:** `MIDIParser.parse`.

**Was:** High-bit or real-time bytes in data slots produced note/CC fields 128…255.

**Fix (H3):** Channel-message data collection only accepts bytes with bit 7 clear.
Real-time (0xF8–0xFF) is skipped mid-message; any other status abandons the
incomplete message. Truncated or malformed input yields no event rather than an
out-of-range one. Velocity-0 still means note-off.

Harness: suite `H3 MIDI-1 fix — high-bit / real-time mid-data stay in 0…127`; random
and structured fuzz assert the 0…127 range property (not only no-crash).

### H2-MIG-1 — future `schemaVersion` loads without error and drops unknown fields — FIXED

**Surface:** `Migration.migrateRawIfNeeded` then `Project.fromJSON`.

**Found by:** suite `H2 migration hostility — future schemaVersion`.

**What happened:** A valid v1-shaped `project.json` with `"schemaVersion": 99` and an
extra key (`futureOnlyField`) was accepted. `migrateRawIfNeeded` returned the bytes
unchanged whenever `version >= Schema.current` (so 99 skipped the step loop). Codable
then decoded the known v1 fields and **silently dropped** unknown keys. Re-encoding
wrote `schemaVersion: 99` without `futureOnlyField`.

**Fix (H4):** `Migration.migrateRawIfNeeded` throws
`MigrationError.unsupportedFutureVersion` when `schemaVersion > Schema.current`, with a
plain-language message (e.g. “This song was saved with a newer version of Verse
(schema 99). Open it in an updated Verse.”). `Project.fromJSON` and
`ProjectPackage.read` both fail open via that path. `RecoveryManager` surfaces the
same message in `projectLoadFailureMessage` instead of treating the autosave as
missing garbage.

### H2 status (all items)

| Item | Result |
|------|--------|
| 1 PatchParser fuzz | Pass: always `ParsedPatch` or `ParseError` on fixed corpus + 200 seeded trials |
| 2 PatchValidator property | Pass; **H2-VAL-1** closed in H3 |
| 3 MIDI parser fuzz | Pass: every emitted event in 0…127; **H2-MIDI-1** closed in H3 |
| 4 Model round-trip | Pass: 80/80 seeded + dense control encode→decode→re-encode identical |
| 5 Migration hostility | Pass on malformed/truncated/wrong-type; **H2-MIG-1** FIXED in H4 |
| 6 Scale | Pass: 50 tracks / 20k notes save, load, fingerprint, piano-roll layout |

Scale timings from a green local run (illustrative; not pass/fail):
`build≈0.04s encode≈0.04s decode≈0.06s fingerprint≈0.0003s packageWrite≈0.05s packageRead≈0.06s layout20k≈0.007s` (~4.4 MB JSON).

## Step H3 — Fix the two defects the fuzzer found — DONE

**H2-VAL-1 (serious: breaks the pipeline's core invariant).** Fixed: when `deleteClip`
is accepted, the validator removes that handle from `clipHandles` and `tempClips` so any
later op referencing it is **rejected at validation** with “Unknown clip”, not at apply.
There is no patch-level `deleteTrack` op. Multi-error collection is preserved.

**H2-MIDI-1.** Fixed: never treat a byte with bit 7 set as data. Skip real-time bytes
(0xF8–0xFF) transparently mid-message. Truncated or malformed messages yield no event
rather than an out-of-range one. Velocity-0-means-note-off is unchanged.

Fuzz assertions tightened: every emitted event carries pitch, velocity, and controller
values within 0–127 (fixed adversarial, seeded random, and structured+noise suites).

## Step H4 — Fix H2-MIG-1: a newer schema loads and silently loses data — DONE

Found by the migration-hostility fuzz, and previously raised in the first objective review of
this codebase as a non-blocking recommendation that was never actioned.

**Fixed:** `Migration.migrateRawIfNeeded` rejects `schemaVersion > Schema.current` with
`MigrationError.unsupportedFutureVersion` and a plain-language
`LocalizedError` message. `Project.fromJSON` and `ProjectPackage.read` fail open (no
partial load). `RecoveryManager.detectRecovery` keeps the autosave on disk and sets
`projectLoadFailureMessage` so the UI can explain “needs a newer Verse” instead of
pretending nothing was found. Current schema still opens; forward migration for older
versions is unchanged.

---

# Phase R — Arrangement (lay a song out in time)

You can now edit notes inside a clip, but there is no surface to position clips in time.
`moveClip` exists as a model helper and an AI patch op with **no UI path at all**. That is the
largest remaining gap for actually writing a song.

## Step R1 — Transport must honour `lengthBeats` — PENDING

Prerequisite, and a correctness fix in its own right. Today `Clip.lengthBeats` is not consulted
during playback at all:

- Audio: duration comes from the file (`scheduleFile` plays the whole thing).
- MIDI: notes are scheduled from `clip.startBeat + note.startBeat` with no clipping at the clip
  boundary, so a note extending past the clip end still sounds in full.

`lengthBeats` only affects `arrangementBeats`, which feeds the loop range. So a clip that looks
8 beats long in the piano roll can sound for 30 seconds. The moment R2 lets a user drag a clip
edge, that inconsistency becomes visible and confusing.

1. **MIDI**: a note must not sound past the clip end. A note starting at or after `lengthBeats`
   does not sound at all; a note crossing the boundary is truncated so its note-off fires at the
   clip end.
2. **Audio**: schedule only the portion of the file that falls inside the clip, using
   `scheduleSegment` with a frame count derived from `lengthBeats` and the tempo, rather than
   `scheduleFile`. If the file is shorter than the clip, it simply ends early; do not loop it.
3. Keep the existing behaviour that negative-onset material is not scheduled.
4. Tests via the existing offline render: audio stops at the clip boundary rather than playing
   the whole file, a MIDI note crossing the boundary stops at it, and a note beyond the end
   never sounds. Assert on rendered audio and scheduled events, not on wall-clock timing.

This also unblocks `resizeClip` as an AI op, which was cut precisely because length was inert.
Do NOT re-add that op in this step; note it as newly unblocked.

## Step R2 — Arrangement view — PENDING

1. New `Sources/VerseAppCore/Views/ArrangementView.swift`: one horizontal lane per track, with a
   shared beat ruler above showing bars. Clips draw as blocks positioned by `startBeat` and
   sized by `lengthBeats`, labelled with the clip name, and visually distinct for audio vs MIDI.
2. **Drag a clip horizontally to move it in time**, snapped, reusing the same snap control the
   piano roll uses (Off / 1/4 / 1/8 / 1/16). Clips may not start before beat 0.
3. **Drag a clip's right edge to resize** it. Same proportional-hit-zone lesson as the piano
   roll: on a short clip the resize zone must not swallow the move zone.
4. Clicking a MIDI clip opens it in the piano roll. Keep the existing per-track roll button
   working.
5. The transport playhead draws across the arrangement during playback.
6. **Undo grouping, same rule as everywhere else in this app**: exactly one entry per completed
   gesture, snapshot on gesture begin, never per drag update. Labels "Move Clip", "Resize Clip".
7. It must be reachable and obvious from the main window, and must behave sanely with zero clips.
8. Edits route through the existing autosave path.

Constraints: no new dependencies, no schema change, `swift build` clean, `swift run VerseCheck`
green, app bundles.
