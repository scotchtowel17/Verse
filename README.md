# Verse

A native macOS (Apple-Silicon) songwriting/recording app for hobbyists — pick a sound, play
it, record takes, layer tracks, and get an AI copilot driven by your existing Claude
subscription (no API key, no billing). Built in pure Swift on Apple frameworks
(`AVAudioEngine`, `AVAudioUnitSampler`, Core MIDI, CoreML, optional Music Understanding).

## Requirements

- macOS 26 (Tahoe) or later, Apple Silicon.
- Swift 6 toolchain (Command Line Tools are sufficient — full Xcode not required).

## Build & run

```bash
swift build                 # compile
swift test                  # run unit tests
scripts/make-app.sh         # assemble an ad-hoc-signed build/Verse.app
scripts/run.sh              # build + launch
```

The app is **ad-hoc code-signed** locally (no paid Apple Developer account, no Team ID, no
notarization). On first launch macOS may say the app is from an unidentified developer:

> **System Settings ▸ Privacy & Security ▸** scroll to the message about “Verse” ▸ **Open Anyway**.

The first time you record, macOS will ask for **microphone** permission — click **Allow**.

## Architecture (module boundaries — Build Contract §J)

```
Sources/
  VerseModel/        data model + schema versioning/migration (no UI, no audio)
  VerseCommands/     command pattern + undo
  VerseEngine/       AVAudioEngine graph, transport, recording, metering (no UI)
  VersePersistence/  .verse file-package IO, atomic save, journal, crash recovery
  VerseAI/           verse-patch request builder, lenient parser, validator, applier
  VerseAnalysis/     Music Understanding wrapper (canImport-gated) + manual fallback
  VerseAudioToMIDI/  Basic Pitch CoreML inference (feature-flagged)
  VersePlugins/      Audio Unit discovery + insert
  Verse/             @main SwiftUI app
```

`VerseEngine` and `VerseModel` import no UI. ML features are leaf modules behind protocols
so they can be feature-flagged off without breaking the build.

## Licensing

The CI license gate (`scripts/license-gate.sh`) fails on any GPL/AGPL/LGPL SPDX. All bundled
content is permissive: see [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md).

## Features (MVP, M0→M7)

- Multitrack `AVAudioEngine` graph: instrument + audio tracks, volume/pan/mute/solo, master bus.
- Bundled GeneralUser GS instruments via `AVAudioUnitSampler` (curated presets; default-voice fallback).
- On-screen piano + computer-keyboard (musical typing) + transport (play/stop/loop/metronome/tempo).
- Journaled recording to `.verse` packages, atomic saves, autosave, **SIGKILL crash recovery**.
- Built-in Apple effects (reverb/echo/crunch/EQ) and hosting of **installed Audio Units**.
- **Claude copilot** via clipboard `verse-patch` round-trip — no API key, no billing; full undo.
- Tempo/key analysis (Music Understanding when available; tap-tempo + key picker fallback).
- **Hum → MIDI**: monophonic melody transcription always; Basic Pitch CoreML when the model is bundled.

## Verify

```bash
swift run VerseCheck                  # 91 assertions (model, audio, recording, persistence,
                                      #   verse-patch fixtures, analysis, AU hosting, hum→MIDI)
bash scripts/crash-recovery-test.sh   # real kill -9 mid-recording → recovers
bash scripts/license-gate.sh          # fails on any GPL/AGPL/LGPL
```

## Optional artifacts

```bash
scripts/fetch-artifacts.sh                 # GeneralUser GS SF2 (already fetched) + checksum
scripts/fetch-artifacts.sh --with-model    # Basic Pitch CoreML model → enables polyphonic hum→MIDI
```

Built milestone by milestone (M0→M7); see the history in `git log`.
