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
