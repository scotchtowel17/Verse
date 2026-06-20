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

## Status

Built milestone by milestone (M0→M7). See `scripts/` and the milestone history in `git log`.
