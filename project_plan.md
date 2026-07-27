# Verse — Project Plan (current state)

Branch lineage: `phase-a-safety` and later phases. Full historical log (every step,
defect write-up, and resolution): [`docs/history/project_plan_archive.md`](docs/history/project_plan_archive.md).

State legend for remaining work: PENDING / IN PROGRESS / DONE / BLOCKED.

Each change must leave `swift build` clean and `swift run VerseCheck` exiting 0.

---

## What Verse does today

Native macOS (Apple Silicon) songwriting and recording app. Pure Swift, SwiftUI,
`AVAudioEngine`. No external package dependencies. Clipboard Claude copilot (no API key).

### Modules

| Module | Role |
|--------|------|
| `VerseModel` | Project, Track, Clip, Note, Schema, Migration. Pure values. No UI, no audio. |
| `VerseEngine` | Graph, transport, metronome, sound bank, metering, recording. |
| `VersePersistence` | `.verse` package IO, journal, autosave, crash recovery. |
| `VerseCommands` | Undo stack and project commands. |
| `VerseAI` | RequestBuilder → PatchParser → PatchValidator → PatchApplier, via Copilot. |
| `VerseMIDI` | Class-compliant MIDI input (hot-plug, note/CC parse). |
| `Verse` / `VerseAppCore` | `@MainActor` AppStore + SwiftUI. |
| `VerseCheck` | Verification harness (`swift run VerseCheck`). |

### Product surface

- Multitrack instrument and audio tracks: volume, pan, mute, solo, tempo, key, time signature.
- Arrangement view: clip select/marquee, move in time, resize, copy/paste, move between
  compatible tracks, split MIDI clips. Transport honours `Clip.lengthBeats` as a hard stop.
- Inline piano roll (aligned to the arrangement): add/move/resize notes, marquee, snap on/off,
  bounded pitch window (no inner vertical scroll), transport and selection shortcuts.
- Recording: audio takes into `.verse` packages; MIDI capture while record-armed and playing
  (virtual CoreMIDI proven in harness). Record control has armed / capturing appearance and
  plain-language status.
- Instruments: curated GM preset list (~70), track name separate from instrument. Sound banks:
  MuseScore General preferred when present, else GeneralUser GS, else sampler built-in voice.
  SF2s are gitignored; fetch scripts verify SHA-256; absence is normal, never an error.
- Effects: built-in inserts persist on the track; hosted third-party Audio Units are
  session-only and honestly dropped on reconfigure (status message, not a silent lie).
- Claude copilot: paste request / paste reply, structural fingerprint, mandatory plain-English
  preview from validated ops only, one undo group per applied patch.
- AI ops (19): `createTrack`, `setInstrument`, `addMidiClip`, `addNotes`, `setTempo`, `setKey`,
  `setTimeSignature`, `setTrackMix`, `deleteClip`, `renameTrack`, `quantizeNotes`,
  `transposeNotes`, `moveClip`, `resizeClip`, `duplicateClip`, `splitClip`, `moveClipToTrack`,
  `deleteNote`, `moveNote`.
- Schema **v2**: `Clip.mediaStartSeconds` (default 0). v1 projects migrate on open. Future
  schema versions refuse to open with a plain-language message.
- Model-level `Project.splitAudioClip` exists and is tested; **not** in the UI or AI yet.
- Recovery: journal, autosave, SIGKILL-style recovery path; media prune on clean quit without
  deleting unrelated takes.

### Verification

`swift build` and `swift run VerseCheck`. Property/fuzz coverage includes patch parse/validate,
MIDI parse range, model round-trip, migration hostility, undo round-trip, layout/selection/
split pure functions, scale projects, and MIDI capture end-to-end via virtual CoreMIDI.

---

## Standing constraints

These do not expire with a phase. They match `Agents.md` and lessons from production defects.

1. **Safety and truthfulness before features.** Failure modes produce clear, plain-language
   messages. The app owner is not a programmer.
2. **No silent no-ops reported as success.** If the user asked for something and it did not
   happen, say so (`statusMessage` or a reject). Deliberate high-frequency no-ops need a
   comment explaining why silence is correct.
3. **Preview shows validated ops only**, never Claude's prose summary as the approval text.
4. **One undo entry per completed gesture.** Snapshot on gesture begin, mutate during the
   drag, record once on end. Continuous volume/pan sliders must never record undo (they would
   flush the stack).
5. **Whole AI patch = one undo group.** Parse → validate (collect **all** errors) →
   transactional apply. Validation resolves positional handles to UUIDs so later ops cannot
   be corrupted; apply must not be the first place a bad reference is discovered.
6. **No new external dependencies. Ever.**
7. **Schema stays at the current version** unless a step explicitly bumps it. Schema is 2
   after V6; do not bump casually.
8. **Preserve user-visible behaviour** unless the step explicitly changes it.
9. **No wall-clock upper bounds in tests.** Assert ordering and lower bounds that carry
   meaning; CI load makes “finished within N seconds” flaky.
10. **Assert what is observable**, not the intent of a layout or scroll call the harness cannot
    see. Prefer pure functions of inputs over “we called scrollTo”.
11. **Out of scope unless a step says otherwise:** coordinator extraction from AppStore,
    free-form harmony/melody generation, direct Claude API calls, strict-concurrency mode,
    `setClipGain`, phrase library.

---

## Durable engineering lessons

Keep these prominent. Full defect narratives live in the archive.

| Lesson | Why it exists |
|--------|----------------|
| **One undo entry per gesture** | Slider drags and note moves used to flood or skip undo; AI patches and arrangement edits depend on a single reverse step. |
| **No wall-clock upper bounds in tests** | CI runners are loaded; upper bounds measure machine load, not product behaviour. |
| **Assert the observable result** | Pitch “centring” via `scrollTo` passed tests three times and failed live. Bounded pitch windows made the visible range assertable. |
| **Validation must guarantee apply cannot fail on references** | H2-VAL-1: `deleteClip` left handles live; apply threw after “valid” patches. Invalidate handles in the validator. |
| **Never leave the UI claiming something that did not happen** | Effects that vanished after reconfigure while the picker still showed them; record arm with no visual state; silent `guard` returns on user-facing actions. |
| **Structural fingerprint on AI patches** | Positional handles (`T1`, `T2C1`) go stale if the project changes between copy and apply. |
| **Reject future schema versions** | H2-MIG-1: loading schema 99 as “current shape” silently dropped unknown fields and re-saved the lie. |
| **Never open Core Audio input without a safe path** | VerseCheck hung forever on `inputNode` without mic usage description; preflight and soft-fail MIDI-only arm. |
| **Collect all validation errors** | Early return hid the second and third problems in a multi-op patch. |
| **Do not bundle unverified binaries** | SF2 checksum mismatch: warn and continue with built-in voice; absence is normal. |

---

## Open items

Work still worth doing; not a commitment to order.

| Item | Notes |
|------|--------|
| **Audio split UI (and optional AI op)** | Model and playback honour `mediaStartSeconds`; `Project.splitAudioClip` is tested. Wire arrangement UI (and, if desired, a `splitClip`-style AI path for audio) without a further schema bump. |
| **Hosted AU persistence** | Built-in effects round-trip; third-party inserts stay session-only until `stateBlob` restore is designed. |
| **Phrase library / free-form content ops** | Explicitly deferred; different safety category from structure ops. |
| **`setClipGain`** | No per-clip gain path in the mixer. |

Nothing in this table is in progress unless marked on a new step heading below.

---

## Known-unverified

Claims that must not be stated as proven until exercised on real hardware or a finished UI path.

| Item | Status |
|------|--------|
| **Physical MIDI controller (e.g. Akai MPK mini)** | Hot-plug and capture proven with **virtual** CoreMIDI in VerseCheck. Physical device attach, play, and record-arm take remain unverified by hand. |
| **Audio split in the running app** | Model/transport groundwork only. No UI path; no end-to-end product verification. |
| **Hosted third-party AU restore across reconfigure/save** | Intentionally not implemented; do not claim plug-ins survive. |

---

## Completed phases (index only)

Full step text, resolutions, and defect write-ups: archive file.

| Phase | Summary |
|-------|---------|
| A / 1–9 | AI safety: clip ownership, fingerprint, undo hygiene, AppStore split, mutation helpers, mandatory preview, AI ops expansion, Edit-menu undo fix, AppStore testability. |
| G | Effects truth, workspace retention, crash-shape hardening, engine/persistence/recording coverage; G5-1 TakeRecorder duration fixed via failing tests. |
| F | Real SF2 bundling, track name ≠ instrument, curated presets. |
| P | Piano roll model helpers, view, editing, integration, short-note move, snap off. |
| M | MIDI input engine, live play, record into clip, hot-plug, record-arm UI (M4). |
| I | Expanded presets, MuseScore General preferred bank, mic-safe recording for CLI harness (I1b). |
| H | Record freeze, fuzz/property tests, H2-VAL-1 / H2-MIDI-1 / H2-MIG-1 fixes. |
| R | Transport honours `lengthBeats`; arrangement view and first-use layout fixes. |
| S | Piano-roll transport, selection, double-click add, copy/paste. |
| T | Inline aligned piano roll; bounded pitch window (T4) after scroll-based centring failed live. |
| U | Clip selection, copy/paste, move between tracks, MIDI split. |
| V1–V6 | Undo round-trip property; MIDI capture E2E; AI parity ops; silent no-op audit; layout/selection/split properties; audio-split model (schema v2). |

---

## Step V7 — Compact project_plan.md — DONE

The plan had grown into a long append-only log (completed phases, superseded steps, and defect
write-ups interleaved). That log remains valuable as history but was no longer navigable as a
working plan.

1. Rewrite `project_plan.md` as this **current-state document**: what Verse does today, standing
   constraints, open items, and the known-unverified list.
2. Move the full historical log to `docs/history/project_plan_archive.md` **unchanged** (no
   deletion or rewrite of history; defect write-ups preserved).
3. Keep durable engineering lessons prominent here rather than only in the archive.
)

## Step W1 — The piano roll should be obvious, and drawing should not require a clip first — DONE

Owner: "It isn't intuitive for me to get to or access the piano roll. I should be able to add
notes manually without having to record."

The capability already exists: `openPianoRoll(forTrack:)` creates an empty clip when a track has
none. The problem is the mental model and the discoverability. The roll is bound to a **clip**,
`showPianoRoll` defaults to false so the pane starts collapsed, and on a brand-new project the
only way in is a small unlabelled icon in the track row. The user has to know that a clip must
exist before notes can exist, which is an implementation detail they should never meet.

Invert it: **the roll edits the active track.** A clip is created on demand when the user
actually draws something.

1. **The roll pane is expanded by default**, not collapsed, and shows the active instrument
   track's grid immediately on a brand-new project. It should be visible without the user
   discovering anything.
2. **The roll follows the active track.** Selecting a track row makes the roll edit that track.
   The roll header names the track and, when relevant, the clip within it.
3. **Drawing works with no clip present.** Double-clicking an empty grid on a track with no MIDI
   clip creates a clip positioned to contain that beat and adds the note, as ONE undo entry
   ("Add Note"), not two. The user should never have to create a clip as a separate act.
4. When the active track has several MIDI clips, the roll edits the one under the playhead if
   there is one, otherwise the nearest earlier one, otherwise the first. Clicking a clip in the
   arrangement still selects it explicitly and wins over that default.
5. **The empty state must say what to do**, in plain language, for example "Double-click to add
   a note." Not a bare grid.
6. An audio track cannot be edited in the roll: say so plainly rather than showing a dead grid.
7. Keep every Phase S and T behaviour: the shared time axis, double-click to add, marquee,
   group move, copy/paste, bounded pitch window, one undo entry per gesture.

The target is that on a fresh launch, adding a note takes exactly one action: double-click.

---

# Phase X — Visual polish, colour identity, and frequent-action buttons

Owner: more polished and professional but still minimalist; use colour to differentiate and
identify functions and tracks; add buttons for actions done often; look to other software.

Audit first. Several things read as "aesthetics" but are missing functionality:

- **`quantizeNotes` has no UI at all.** It exists as a model helper and an AI op only, so a
  user cannot make their own notes line up by hand. For a songwriting app that is a core action,
  not a nicety.
- **`duplicateClip` has no UI**, also AI-only.
- **`splitClip` is Cmd-E only**, no button or visible affordance.
- **Redo has no button**, menu only.
- **No timeline zoom.** `beatWidth` is a fixed constant, so a long song cannot be seen whole and
  fine edits cannot be made close up.
- **No per-track colour.** `Track` has no colour field.

## Step X1 — Track colour identity — DONE

Every serious DAW gives each track a colour and carries it through the whole UI. That is the
single biggest "know what I'm looking at" win and it is what the owner is asking for.

1. Add `colorIndex: Int` to `Track` (index into a fixed palette, not a raw hex string, so
   themes stay coherent). **Bump `Schema.current` to 3** with an additive migration; existing
   tracks get assigned by position. The v1-to-v2 migration proved the chain works, so this is
   now routine.
2. A palette of **8 colours**, chosen to stay legible and distinct in both light and dark mode
   and to remain distinguishable for common colour-vision deficiencies. Assign round-robin on
   track creation.
3. Carry the colour through: the track row's accent strip, the arrangement lane header, the
   clips in that lane, the notes in the piano roll when editing that track, and the track meter.
   A clip and its notes must read as belonging to the same track at a glance.
4. Let the user change a track's colour from the track row.
5. **Semantic colour stays separate from identity colour.** Record armed and recording are red,
   playing is the accent, selection is the system accent, refusal or error is the standard
   warning colour. Never overload a track's identity colour to mean a state.
6. Keep it minimalist: colour is a thin accent strip and a clip fill, not large blocks of
   saturated colour. Text stays high-contrast on every palette entry in both appearances.

## Step X2 — Action bar, zoom, and exposing hidden actions — DONE

1. A compact action bar for things done constantly, grouped and icon-led with tooltips:
   **undo, redo, split at playhead, duplicate, delete, quantize**. Minimalist: one row, no
   labels beyond tooltips, disabled rather than hidden when not applicable.
2. **Quantize needs a real UI**, since it currently has none. Quantize the selected notes (or
   the whole clip when nothing is selected) to the current snap value, as one undo entry
   ("Quantize Notes"). This closes a genuine functional gap.
3. **Duplicate and split** get buttons, working on the current selection in whichever surface
   has focus, consistent with the existing Cmd-C/V focus routing.
4. **Timeline zoom.** Replace the fixed `beatWidth` with a zoom level shared by the arrangement
   and the roll, since they must stay aligned. Zoom in/out buttons plus fit-to-content. The
   shared beat-to-x mapping already exists, so zoom belongs there and nowhere else.
5. Buttons must reflect state honestly: disabled when the action cannot apply, with a tooltip
   saying why, consistent with the V4 rule that a user never asks for something and gets silence.

Keep every existing behaviour and shortcut working. No regressions in the shared time axis.

## Step X3 — Visual regressions found by running X1/X2 — DONE

The colour identity works and reads well: blue, amber and green carry from the track rows
through the lane headers, the clips and the notes in the roll. Three problems, found by looking.

1. **The roll draws fewer pitch rows than its own range label claims, hiding notes again.**
   With the Lead clip selected, the header reads "D#4-D6" (24 semitones) and "3 notes", but only
   about 12 rows are drawn and only 1 note is visible. The drawn rows are almost exactly HALF
   the stated range, which points at a mismatch between the row height used to compute
   `visiblePitchRange` and the row height used to draw, or a pane height that is halved before
   it reaches the range function. The likely trigger is X2's action bar taking vertical space
   without the roll's height being recomputed.
   This is the same class of failure as T4 (what is claimed versus what is shown), so fix the
   cause and add an assertion tying the two together: **the number of rows drawn must equal the
   number of pitches in the range that the label reports.**
2. **Dark-mode contrast is inverted.** The note grid is nearly black with rows barely
   distinguishable, while the piano-key gutter is pure white and visually dominates the pane.
   The gutter should be the quiet element and the grid the readable one. Raise grid row contrast
   and soften the gutter so the keyboard reads as a reference strip, not the main event. Check
   both appearances; do not fix dark by breaking light.
3. **Every action-bar icon reads as disabled.** The icons are uniformly dim, so an enabled
   action looks the same as an unavailable one. Enabled actions need normal-weight foreground
   contrast, with disabled ones clearly lighter. The point of X2 item 5 was that state is
   honest; right now nothing looks available.

Keep the palette, the semantic-colour separation, and every behaviour from X1 and X2.

## Step X4 — On-screen keyboard keys are far too wide — DONE

Owner: "add another octave range to the piano keys below, or shorten the width. Right now it
looks weird having them so big."

`ContentView` passes `octaves: 2` as a hard-coded constant and `PianoKeyboardView` divides the
full window width by 15 white keys. At the window sizes actually in use that is roughly 90pt per
white key, several times the proportions of a real keyboard, which is why it looks wrong.

Do not simply swap 2 for a larger constant: that just moves the problem to a different window
size. Make the octave count adaptive.

1. Add a pure, testable function that picks the octave count from the available width and a
   target white-key width (about 26pt reads correctly on screen; a real white key is around
   23mm). Clamp to a sensible range, roughly 1 to 7 octaves, so a very narrow window still shows
   something playable and a very wide one does not become absurd.
2. The keys then fill the available width exactly with that octave count, so the resulting key
   width lands near the target without leaving a gap or stretching.
3. Keep the keyboard's height proportionate to the new key width; very wide, very short keys are
   part of what looks wrong today. Black keys keep their usual proportion of white-key width and
   height.
4. `baseOctaveC` and the Z/X octave shift must keep working, and the held-note highlighting from
   both the mouse and MIDI must keep working across the new range.
5. Tests on the pure function: a narrow width yields the minimum, a wide width yields more
   octaves rather than wider keys, the resulting key width stays within a sane band across a
   range of widths, and the clamp holds at both ends.

## Step X5 — X4 broke the keyboard: it renders blank — DONE

Verified live: the on-screen keyboard now draws as a flat empty bar with a single divider, no
playable keys, at any window width.

Root cause, from reading `PianoKeyboardView`: the view measures its own width with a
`GeometryReader` inside a background that writes a `PianoKeyboardWidthKey` preference, then uses
that measured width both to choose the octave count AND to set its own `.frame(height:)`. That
is a layout cycle: the size depends on a value derived from the size. SwiftUI resolves it by not
converging, so the width stays at its initial 0, `octaveCount(availableWidth: 0)` returns the
minimum, and almost nothing is drawn.

`octaveCount` itself is correct; do not change its maths.

Fix the layout, not the function:
1. Use a `GeometryReader` as the **container** for the keys and compute the octave count from
   `geo.size.width` directly inside it. Do not route width back out through a preference.
2. **Break the height dependency.** Derive the keyboard's height from the *target* white-key
   width, which is a constant, not from the resulting key width. Height must not depend on
   measured width, or the cycle returns.
3. Guard the degenerate case explicitly: if the measured width is 0 or not yet known, draw
   nothing rather than a misleading empty bar, and let the next layout pass fill it in.
4. Keep everything X4 asked for: adaptive octave count, keys filling the width exactly, sensible
   proportions, `baseOctaveC` and Z/X shift and held-note highlighting all still working.
5. Add an assertion that a realistic width yields more than one octave, so a collapse to the
   minimum is caught rather than merely looking wrong on screen.

---

# Phase Y — Track focus, keyboard fixes, and roll zoom

Four items from real use.

## Step Y1 — Upper keys are silent, and the keyboard needs a hide toggle — DONE

**The bug.** `baseC` is `baseOctaveC`, which defaults to 60 (middle C). X4 made the keyboard
adaptive and it now renders about 7 octaves, so the top white key maps to roughly pitch 144,
well past the MIDI ceiling of 127. The engine takes `UInt8(clamping:)`, so every key above the
ceiling collapses onto pitch 127, which on a piano sample is effectively inaudible. That is why
the upper half of the keyboard makes no sound.

1. The rendered range must always fit within MIDI 0-127. Derive the lowest C from the octave
   count so the whole keyboard fits, rather than always starting at `baseOctaveC`, and cap the
   octave count so the range can never exceed the ceiling.
2. `baseOctaveC` and the Z/X octave shift should still move the range, but clamped so it can
   never push notes out of range. Shifting at the top or bottom should stop, not silently
   produce dead keys.
3. Add an assertion that **every key the keyboard renders maps to a pitch within 0-127**, at
   every octave count and every shift position. A dead key must fail a test, not just feel wrong.
4. **Hide toggle.** The owner does not need the on-screen keyboard while working in the piano
   roll. Add a way to hide and show it, remembered for the session, and give the space back to
   the roll and arrangement when hidden.

## Step Y2 — Track focus, and zoom inside the piano roll — DONE

1. **Selecting a track must be obvious.** The owner wants to work on one track while still
   seeing the others. Make the selected track unmistakable: a clear selected state on the track
   row and its arrangement lane, using the track's own colour plus the selection accent, while
   every other track stays visible and legible rather than hidden or greyed into uselessness.
2. **Context in the roll.** When editing one track's clip, optionally draw the notes of other
   tracks' clips that overlap the same time range as dimmed, non-interactive ghosts behind the
   grid, in their own track colours. This is what lets someone write a part against what is
   already there. It must be clearly subordinate to the editable notes and must never be
   selectable or draggable. Provide a toggle, default on.
3. **Zoom in the roll.** X2 added a shared timeline zoom driven from the action bar, but it is
   not discoverable from the roll and there is no vertical zoom. Add zoom controls to the roll
   itself for the horizontal (time) axis, sharing the same value as the arrangement so the two
   stay aligned, and add a separate vertical zoom that changes pitch row height so more or fewer
   pitches are visible. Both need sensible clamps.
4. Vertical zoom must keep the bounded-window invariant from T4: the number of rows drawn always
   equals the span the range label reports, at every zoom level.

## Step Y3 — Roll toolbar is overcrowded, and ghosts are unconfirmed — DONE

Y2's substance works and was verified live: the selected track is unmistakable (selection ring
on the row, tinted lane) while the other tracks stay fully legible, the roll carries its own
time and pitch zoom, and the keyboard hide toggle works. Two problems.

1. **The roll toolbar has outgrown its row.** It now holds Snap with four options, octave
   up/down, a zoom percentage, four magnifier buttons, a Ghosts checkbox and a note count. The
   "Ghosts" label is squeezed so hard it renders **one letter per line vertically**, which looks
   broken. Reorganise the toolbar so it fits at realistic widths: group related controls, use
   icons with tooltips instead of words where the meaning is obvious, and let low-priority items
   collapse into an overflow rather than deform. Nothing may render vertically or clip.
2. **Ghost notes could not be confirmed on screen.** With the Lead clip open (notes 72-79) the
   ghosts from Chords (60-69) and Bass (36, 43) sit outside the visible pitch window, and
   zooming out vertically did not bring them into view. Determine whether ghosts render at all,
   and make the vertical zoom-out actually widen the pitch window as expected. Add an assertion
   that with ghosts enabled and an overlapping clip on another track, the ghost set is non-empty
   and excludes the edited clip's own notes.
3. While reorganising, confirm the two zoom axes are clearly distinguishable. Four adjacent
   magnifier icons with no labels are ambiguous; time zoom and pitch zoom should be visibly
   different controls.

Keep every Y2 behaviour: shared horizontal zoom with the arrangement, the T4 invariant that rows
drawn equals the range label span at every row height, and ghosts non-interactive.

---

# Phase Z — Gaps found by comparing against Soundtrap's piano roll

Reference points taken from Soundtrap's MIDI editor: per-note velocity editing (a V mode or
Alt/Cmd modifier, velocity drawn as lines inside the note, drag up or down to change it, plus a
fader for a whole selection), quantize, chord detection that labels the harmonic content, a
pattern loop, and grid resolution down to 1/32.

Measured against Verse today:

- **Velocity: we have none.** Every hand-drawn note is fixed at velocity 100 forever. Captured
  MIDI preserves the played velocity, but nothing in the app can show or change it. This is the
  largest gap and the most musical one: it is the difference between a part that sounds played
  and one that sounds typed.
- **Grid stops at 1/16.** Soundtrap goes to 1/32, and there are no triplet divisions at all.
  The owner's own MPK mini has 1/4T, 1/8T and 1/16T arpeggiator divisions, so triplets are a
  natural thing to reach for.
- **No chord detection or labelling.** Verse already has `KeySignature` and an analysis path,
  but nothing names the harmony in a clip.
- **No per-clip loop.** The transport loops the whole arrangement; Soundtrap loops a pattern.

## Step Z1 — Per-note velocity editing — DONE

1. **Velocity must be visible on the note itself.** Draw it as fill intensity or an inner bar so
   a glance shows the dynamic shape of a phrase. It must stay legible against every track colour
   and in both appearances.
2. **Editing.** A velocity mode toggle in the roll, plus a modifier-drag so it is reachable
   without changing modes. Dragging up or down over a note changes its velocity, clamped 1-127.
   With a multi-note selection the change applies to the whole selection, preserving the
   relative differences between notes rather than flattening them to one value.
3. **One undo entry per completed gesture**, labelled "Set Velocity", never per update. The
   standing rule.
4. New notes take a default velocity that the user can set, so drawing a soft part does not mean
   editing every note afterwards.
5. Expose it to Claude too: a `setNoteVelocity` op, validated and rejected out of range like
   every other op, so the AI stays at parity with the UI.
6. Tests: velocity round-trips through save and load; a group change preserves relative
   differences and clamps at the ends without collapsing; one undo entry restores every note's
   prior velocity exactly.

## Step Z2 — Finer and triplet grid divisions — DONE

Add 1/32, and triplet divisions 1/4T, 1/8T, 1/16T, to the snap control used by both the roll and
the arrangement. Triplet values are a third of the corresponding straight division. Keep the
control compact; it is already dense, so consider grouping straight and triplet values rather
than adding six more buttons in a row.

## Step Z3 — Loop a region while writing — DONE

The transport already accepts `loop: ClosedRange<Double>` and `startPlayback` passes
`0...arrangementBeats` when the loop toggle is on, so looping only ever covers the whole song.
What a songwriter actually needs is to loop four bars while getting a part right.

1. A loop region with its own start and end in beats, drawn clearly in the shared ruler so it is
   visible from both the arrangement and the roll.
2. **Set it from the selected clip** in one action, since "loop this clip while I work on it" is
   the common case. Also allow dragging a region directly in the ruler, and dragging its edges
   to adjust.
3. The existing loop toggle enables and disables it. With loop on, playback starts at the loop
   start and repeats the region. With no region set, fall back to today's whole-arrangement
   behaviour rather than doing nothing.
4. Editing while looping must keep working, including notes added inside the looping region.
5. Loop state is transport state, not document state: no schema change, and it must never
   record an undo entry.
6. Tests: a region set from a clip matches that clip's bounds; playback with a region scheduled
   repeats it rather than running to the arrangement end; clearing the region restores the
   whole-arrangement fallback.

## Step Z2 — Finer and triplet grid divisions — DONE

Snap currently offers Off, 1/4, 1/8, 1/16 only. Add **1/32** and the triplet divisions
**1/4T, 1/8T, 1/16T**, where a triplet value is one third of the corresponding straight
division. The owner's MPK mini has exactly these triplet divisions on its arpeggiator, so they
are a natural thing to reach for and currently impossible.

The snap control is already dense and its row has overflowed once before, so do not simply add
four more buttons: group straight and triplet values so the control stays compact and nothing
deforms or clips at realistic widths. The same divisions must be available to the arrangement
and the roll, and quantize must use whichever is selected.

## Step Z4 — Loop region not confirmed on screen — DONE

Z3's loop region is implemented and unit-tested (a region set from a clip matches that clip's
bounds, playback with a region repeats rather than running to the arrangement end, clearing
restores the whole-arrangement fallback). It could NOT be confirmed by hand: after several
attempts using both the roll's loop control and the action bar's loop button, no loop band ever
appeared in the shared ruler.

**Root cause (fixed in AA3):** the region *was* being set correctly by the controls
(`setLoopRegionFromSelectedClip` and ruler Option-drag), but the band failed to *draw*. The
loop band was painted only inside a SwiftUI `Canvas` drawing closure that read
`store.loopRegion`. Canvas renderer closures are not reliably dependency-tracked for
`@Observable`, so setting the region never forced a ruler repaint. Fix: read loop state in the
view body and draw the band as a real `RoundedRectangle` overlay (orange, visible when loop is
on or off), with a status message when set from a clip.

---

# Phase AA — One track row, and a subtractive pass

Owner: "less is more. Minimalist but the functions that survive are hyper functional."

So this is not only the merge. It is a subtraction pass with the merge at its centre. Measured
today: 16 controls in a track row, snap rendered in two separate places, zoom controls in both
the action bar and the roll toolbar, and permanent instructional sentences occupying chrome.

## Step AA1 — Merge the track list into the arrangement — DONE

Verse renders each track's identity twice: once in the Tracks section with its controls, and
again as a lane label in the Arrangement. Soundtrap, and every other DAW, has one row per track
whose left end is the controls and whose right end is that track's timeline.

1. **One row per track.** The track controls become the lane's left gutter. Delete the separate
   Tracks section and the duplicated lane labels entirely.
2. **This recovers a whole stacked section of vertical height**, which is the point. Three
   separate defects this session traced to the piano roll being starved of room. Give the
   recovered space to the roll and arrangement rather than padding.
3. Selecting the row selects the track, exactly as selecting a lane does now.

## Step AA2 — Subtract — DONE

A control earns its place on screen or it moves into a menu. Judgement, not a formula.

1. **Always visible in a track row**: colour strip, name, record arm, mute, solo, volume, and a
   level indicator. These are touched constantly while writing.
2. **Into a per-track menu**: instrument choice, pan, effect, colour, rename, delete. Each is
   deliberate and infrequent. The menu must be one click and must not hide anything destructive
   behind ambiguity.
3. **One snap control, not two.** Snap currently renders separately for the arrangement and the
   roll. Decide whether they are one value: if yes, show it once; if they are genuinely
   independent, make that legible rather than looking like the same control twice.
4. **Zoom appears in both the action bar and the roll toolbar.** Keep one. Time zoom is shared
   between the two views anyway, so it belongs in one place.
5. **Remove the permanent instructional sentences** ("Select · drag to move · right edge to
   resize · click MIDI for piano roll" and the roll's equivalent). Teaching text that never goes
   away is chrome. Keep such hints for empty states only, where they are genuinely useful, which
   is already how the empty roll behaves.
6. Every surviving control must be hyper functional: correct disabled states with a tooltip
   saying why, keyboard equivalents where they exist, and no dead affordances.

## Step AA3 — Per-track record arm, and fix the loop region — DONE

1. **Per-track record arm.** Today there is one global record button and the destination is
   implied by whichever track is active, which is ambiguous once MIDI capture is involved. Arm
   is now per track, in the row. The transport record button starts and stops the take; the
   armed track or tracks receive it. If nothing is armed, say so rather than silently recording
   nowhere.
2. **Fix Z4, the loop region that never appears.** It is unit-tested but no loop band has ever
   been seen in the ruler. Determine whether the controls fail to set it or it fails to draw,
   fix the real cause, and confirm by running the app. A loop you cannot see is a loop you
   cannot trust or adjust.

Preserve every behaviour: shared time axis, ghosts, velocity editing, zoom on both axes, the T4
row-count invariant, one undo entry per gesture, and the Cmd-C/V focus routing.

## Step AA4 — Default split now starves the arrangement — DONE

AA1 recovered vertical space and gave essentially all of it to the roll. With three tracks the
arrangement shows about two and a half rows and the third is clipped, so a song with more than a
couple of parts cannot be seen at a glance. Choose a default split that shows roughly four track
rows before the roll begins, keep the divider draggable, and let the arrangement scroll beyond
that. Do not go back to starving the roll; both need a fair share.

---

# Phase AB — Principled audit

Applied `docs/engineering-principles.md` to the whole codebase. Measured before acting rather
than assuming. Findings, and equally important, what was deliberately NOT changed.

**Measured state:** 23,046 lines, zero build warnings, zero TODO/FIXME/HACK markers, no dead
public API. Two initial leads were false positives on closer inspection: `yForPitch` is not
duplicated (the second is a thin forwarder to one implementation), and `pianoRollTrackID` and
`pruneArmedTracks` are used, just within their defining file. Recording those because a
correction is as much a result as a finding.

## Step AB1 — Correct three real findings — DONE

1. **`formatLoopBeat` is triplicated**, byte-identical, in `AppStore+Transport.swift`,
   `TransportBar.swift` and `TimelineWorkspaceView.swift`. Principle 4: no duplicate utilities.
   One implementation, used by all three. Put it where it belongs rather than inventing a new
   utility module for a four-line function.
2. **A corrupt recovery journal is indistinguishable from no journal.**
   `RecoveryManager.detectRecovery` and `discardRecovery` both do
   `try? Data(contentsOf:)` then `try? JSONDecoder().decode(...)`. A missing journal is normal
   and a correct silent no-op: there was no recording in progress. A journal that exists but
   fails to decode is a different thing entirely, and today it is silently treated as "nothing
   to recover" in the one subsystem whose entire purpose is not losing the user's work.
   Principle 10: a fallback is only appropriate when degraded behavior is intentional, safe and
   **observable**. Distinguish the two cases and surface the corrupt one. Do not start throwing
   for the normal missing-journal case.
3. **`pianoRollTrackID` and `pruneArmedTracks` are `public` but used only within their own
   file.** Narrow them. Principle 12 and the standard on narrow interfaces.

## Step AB2 — Deliberately NOT done, and why — DONE

Recorded so the reasoning is not re-litigated:

- **`AppStore.swift` is 1,560 lines, past the ~1,200 threshold I recorded earlier for revisiting
  coordinator extraction.** Not splitting it. That threshold was a proxy heuristic I invented,
  not an objective or a real constraint, and principle 3 says to challenge my own prior
  decisions too. The file is sectioned with `MARK`s, already split across four extension files
  by concern, fully covered by tests, and produces no warnings. Splitting a working, tested file
  because a number was crossed is precisely the broad refactor principles 5 and 6 warn against.
  Revisit only when a real change is made harder by the structure.
- **`PianoRollView.swift` is 1,715 lines**, the largest production file, holding both the view
  and the pure `PianoRollLayout` maths. Extracting the pure layout would be defensible on
  readability grounds, but it is a readability argument with no correctness or maintenance
  failure behind it today, and the pure functions are already directly tested. Not necessary.
- **`RecoveryManager` has 22 `try?` calls.** All but the journal decode above are best-effort
  cleanup where fire-and-forget is the intended behavior (removing a lock file that may not
  exist, creating a directory that may already exist). Count is not a defect.

## Phase AC — 20 screen-driven probe iterations (architect loop)

Each probe: drive the running app, look for a real defect, delegate any fix to the
worker (grok), verify against git diff + VerseCheck + the screen, then commit.
"No defect found" is a valid outcome and is recorded as such.

| # | Probe area | Status |
|---|---|---|
| AC1 | Note resize by dragging its right edge | DONE (headless logic; gesture wiring screen-pending) |
| AC2 | Velocity drag mode (V toggle) | DONE (headless: velocity clamp 1-127, one undo) |
| AC3 | Loop region create / move / resize (option-drag ruler) | DONE (headless: LoopRegionLogic normalize/move/resize) |
| AC4 | Loop playback wrap-around | PENDING |
| AC5 | Clip drag between tracks in the arrangement | DONE (headless: move preserves notes, kind mismatch rejected) |
| AC6 | Clip resize in the arrangement | DONE (headless: resize; non-destructive trim contract pinned) |
| AC7 | Clip split at playhead (scissors) | DONE (headless: split accounts for every note, fresh ids) |
| AC8 | Clip duplicate | DONE (headless: fresh clip AND note ids) |
| AC9 | Track menu: rename / delete | DONE (headless: last track refused with a message) |
| AC10 | Undo/redo deep stack, redo invalidation after a new edit | DONE (headless: deep stack + redo invalidation) |
| AC11 | Save / Open .verse package round trip | DONE (headless: save/open round trip) |
| AC12 | Crash recovery after a force quit mid-edit | PENDING |
| AC13 | Tempo change, including while playing | DONE (headless: clamp + one undo entry) |
| AC14 | Time signature change | DONE (headless: beats unchanged) |
| AC15 | Metronome toggle | PARTIAL (transport flag only; setMetronome is internal) |
| AC16 | Instrument change (sound picker) | DONE (headless: instrument survives save/open) |
| AC17 | Track effects / inserts | DONE (headless: inserts survive save/open) |
| AC18 | Volume and pan extremes, master volume | DONE (headless: DEFECT FOUND + FIXED, model clamp) |
| AC19 | Narrow-window layout and toolbar overflow | PENDING |
| AC20 | Multi-clip selection and bulk operations | DONE (headless: one undo restores all) |
