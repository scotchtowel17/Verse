#!/usr/bin/env bash
# Fetch bundled non-code artifacts and record SHA-256 (Build Contract §C).
# These are large/gitignored; the app degrades gracefully if they are absent, so this script
# is an optional quality upgrade, not a build prerequisite.
#
#   GeneralUser GS SF2  -> Sources/VerseEngine/Resources/GeneralUserGS.sf2   (permissive)
#   Basic Pitch CoreML  -> Sources/VerseAudioToMIDI/Resources/BasicPitch.mlpackage (Apache-2.0)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

sha() { shasum -a 256 "$1" | awk '{print $1}'; }

# ── GeneralUser GS SF2 ────────────────────────────────────────────────────────
SF2_URL="https://raw.githubusercontent.com/mrbumpy409/GeneralUser-GS/main/GeneralUser-GS.sf2"
SF2_DST="$ROOT/Sources/VerseEngine/Resources/GeneralUserGS.sf2"
echo "== Fetching GeneralUser GS SF2 =="
if curl -fSL -m 180 "$SF2_URL" -o "$SF2_DST.tmp"; then
  mv "$SF2_DST.tmp" "$SF2_DST"
  echo "  saved: $SF2_DST ($(du -h "$SF2_DST" | awk '{print $1}'))"
  echo "  SHA-256: $(sha "$SF2_DST")"
else
  rm -f "$SF2_DST.tmp"
  echo "  WARNING: SF2 download failed — app will use the sampler's built-in default voice."
fi

# ── Basic Pitch CoreML model (fetched on demand for M7) ───────────────────────
if [ "${1:-}" = "--with-model" ]; then
  MODEL_DIR="$ROOT/Sources/VerseAudioToMIDI/Resources"
  mkdir -p "$MODEL_DIR"
  MODEL_URL="https://github.com/john-rocky/CoreML-Models/releases/download/basicpitch/BasicPitch_nmp.mlpackage.zip"
  echo "== Fetching Basic Pitch CoreML model =="
  if curl -fSL -m 120 "$MODEL_URL" -o "$MODEL_DIR/BasicPitch.mlpackage.zip"; then
    ( cd "$MODEL_DIR" && unzip -oq BasicPitch.mlpackage.zip && rm -f BasicPitch.mlpackage.zip )
    echo "  model unpacked into $MODEL_DIR"
  else
    echo "  WARNING: model download failed — hum→MIDI will be feature-flagged off."
  fi
fi

echo "Done. Re-run 'swift build' / scripts/make-app.sh to bundle fetched artifacts."
