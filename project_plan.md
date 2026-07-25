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

## Step 6 — D mandatory preview — PENDING

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

## Step 7 — E AI expansion — PENDING

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
