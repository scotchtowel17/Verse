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

## Step W1 — The piano roll should be obvious, and drawing should not require a clip first — PENDING

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
