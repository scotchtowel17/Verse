# Third-Party Licenses & Bundled Artifacts

This manifest is the source of truth for the CI license gate (`scripts/license-gate.sh`,
Build Contract §12). Every bundled component declares a machine-readable SPDX identifier on
its own line. The gate fails the build on any copyleft (GPL / AGPL / LGPL) identifier, or any
identifier not on the permissive allowlist.

Allowlist: `MIT`, `Apache-2.0`, `BSD-2-Clause`, `BSD-3-Clause`, `ISC`, `0BSD`, `CC0-1.0`,
`Unlicense`, the named `GeneralUser-GS-License-v2.0`, and `Apple-System` (system frameworks).

---

## Code dependencies (SPM)

### Apple system frameworks
- Component: AVFoundation, AVFAudio, CoreMIDI, CoreML, Accelerate, AppKit, SwiftUI, Combine,
  UniformTypeIdentifiers, and (when available) MusicUnderstanding.
- Use: audio engine, persistence, analysis, ML, UI.
- SPDX-License-Identifier: Apple-System
- Notes: shipped with macOS; not redistributed by Verse.

> Verse's MVP has **no external Swift Package dependencies** — the audio core is built on
> raw `AVAudioEngine` (the spec permits raw AVAudioEngine *or* AudioKit; raw was chosen to
> keep the dependency graph empty and the license gate trivially reproducible). If AudioKit
> (`SPDX-License-Identifier: MIT`) is added later, pin its exact tag + commit in
> `Package.resolved` and re-run the gate.

---

## Bundled non-code artifacts

### GeneralUser GS (SoundFont, SF2)
- Source: https://github.com/mrbumpy409/GeneralUser-GS (mirror of schristiancollins.com/generaluser.php)
- Version: 2.0.x (target v2.0.3 — 261 presets / 13 drum kits / ~30.7 MB)
- Use: bundled instrument sounds loaded by `AVAudioUnitSampler`.
- SPDX-License-Identifier: GeneralUser-GS-License-v2.0
- License text (excerpt): "You may use GeneralUser GS without restriction for your own music
  creation, private or commercial. … Please feel free to use it in your software projects."
- Caveat: NOT public domain (CC0). Sample provenance is "as good as the information provided
  by the original sources" (unchallenged since 2000). Apple's native SoundFont synth
  mis-renders some modulator-heavy presets — Verse bundles a curated, auditioned subset.
- File: `GeneralUser-GS.sf2` (32 MB), fetched from `mrbumpy409/GeneralUser-GS@main`.
- SHA-256: `9575028c7a1f589f5770fccc8cff2734566af40cd26ed836944e9a5152688cfe`

### MuseScore General (SoundFont, SF2)
- Source: https://ftp.osuosl.org/pub/musescore/soundfont/MuseScore_General/
- License text: https://ftp.osuosl.org/pub/musescore/soundfont/MuseScore_General/MuseScore_General_License.md
- Version: 0.2
- Copyright: Michael Cowgill (2014-16) and Frank Wen (2000-2002, 2008)
- Use: preferred higher-quality instrument bank loaded by `AVAudioUnitSampler` when present.
  New instruments store the logical name `MuseScoreGeneral`; if the file is absent, Verse
  falls back to GeneralUser GS then the sampler built-in voice. Absence is normal (CI never
  downloads this file).
- SPDX-License-Identifier: MIT
- File: `MuseScore_General.sf2`, 215,614,036 bytes
- SHA-256: `ee51d2c4b1525e70f19a45909c4fd7a2e26d91d115fa89dbf5a6bc413d8b9bf3`
- Fetch: `scripts/fetch-artifacts.sh --with-musescore` only. `scripts/make-app.sh` bundles it
  when already present and verified; it never auto-fetches this file.

### Basic Pitch CoreML model (hum→MIDI)
- Source: https://github.com/spotify/basic-pitch (official TF model; re-convert with coremltools),
  OR community `.mlpackage` from https://github.com/john-rocky/CoreML-Models (~272 KB).
- Use: audio-to-MIDI inference on short clips (feature-flagged; degrades off if absent).
- SPDX-License-Identifier: Apache-2.0
- SHA-256: `PENDING` (recorded by scripts/fetch-artifacts.sh on download)

---

## Explicitly excluded (Phase 2 — not bundled, not linked)

These are recorded so the gate's intent is auditable. None ship in MVP.

| Component | Why excluded | License |
|---|---|---|
| sfizz / SFZ | needs C/C++ interop | Phase 2 — excluded (BSD-2-Clause core, but interop deferred) |
| VST3 SDK | Steinberg dual license is copyleft-or-proprietary | Phase 2 — excluded |
| Demucs / ONNX Runtime | large models + C/C++ runtimes | Phase 2 — excluded |
| aubio / Vamp | copyleft, license-incompatible | Phase 2 — excluded |
| Essentia | copyleft, license-incompatible | Phase 2 — excluded |

> The copyleft mentions above are deliberately in an *excluded / Phase 2* context; the gate
> permits them only in that context and fails on any copyleft identifier used in the core.
