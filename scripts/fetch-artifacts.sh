#!/usr/bin/env bash
# Fetch bundled non-code artifacts and record SHA-256 (Build Contract §C).
# These are large/gitignored; the app degrades gracefully if they are absent, so this script
# is an optional quality upgrade, not a build prerequisite.
#
#   GeneralUser GS SF2     -> Sources/VerseEngine/Resources/GeneralUserGS.sf2   (permissive)
#   MuseScore General SF2  -> Sources/VerseEngine/Resources/MuseScore_General.sf2 (MIT, opt-in)
#   Basic Pitch CoreML     -> Sources/VerseAudioToMIDI/Resources/BasicPitch.mlpackage (Apache-2.0)
#
# Flags:
#   --with-musescore   fetch MuseScore General (~206 MB); not fetched by default
#   --with-model       fetch Basic Pitch CoreML model
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

sha() { shasum -a 256 "$1" | awk '{print $1}'; }

WITH_MUSESCORE=0
WITH_MODEL=0
for arg in "$@"; do
  case "$arg" in
    --with-musescore) WITH_MUSESCORE=1 ;;
    --with-model) WITH_MODEL=1 ;;
    *) echo "Unknown flag: $arg (supported: --with-musescore, --with-model)" >&2; exit 2 ;;
  esac
done

# ── GeneralUser GS SF2 ────────────────────────────────────────────────────────
SF2_URL="https://raw.githubusercontent.com/mrbumpy409/GeneralUser-GS/main/GeneralUser-GS.sf2"
SF2_DST="$ROOT/Sources/VerseEngine/Resources/GeneralUserGS.sf2"
SF2_EXPECTED_SHA="9575028c7a1f589f5770fccc8cff2734566af40cd26ed836944e9a5152688cfe"
echo "== Fetching GeneralUser GS SF2 =="
if curl -fSL -m 180 "$SF2_URL" -o "$SF2_DST.tmp"; then
  got="$(sha "$SF2_DST.tmp")"
  if [ "$got" = "$SF2_EXPECTED_SHA" ]; then
    mv "$SF2_DST.tmp" "$SF2_DST"
    echo "  saved and verified: $SF2_DST ($(du -h "$SF2_DST" | awk '{print $1}'))"
    echo "  SHA-256: $got"
  else
    rm -f "$SF2_DST.tmp"
    echo "  WARNING: SF2 checksum mismatch (got $got). Not keeping unverified file."
  fi
else
  rm -f "$SF2_DST.tmp"
  echo "  WARNING: SF2 download failed — app will use the sampler's built-in default voice."
fi

# ── MuseScore General SF2 (opt-in; ~206 MB) ───────────────────────────────────
if [ "$WITH_MUSESCORE" -eq 1 ]; then
  MS_URL="https://ftp.osuosl.org/pub/musescore/soundfont/MuseScore_General/MuseScore_General.sf2"
  MS_DST="$ROOT/Sources/VerseEngine/Resources/MuseScore_General.sf2"
  MS_EXPECTED_SHA="ee51d2c4b1525e70f19a45909c4fd7a2e26d91d115fa89dbf5a6bc413d8b9bf3"
  echo "== Fetching MuseScore General SF2 (opt-in) =="
  # Long timeout: ~206 MB over public FTP mirror.
  if curl -fSL -m 900 "$MS_URL" -o "$MS_DST.tmp"; then
    got="$(sha "$MS_DST.tmp")"
    if [ "$got" = "$MS_EXPECTED_SHA" ]; then
      mv "$MS_DST.tmp" "$MS_DST"
      echo "  saved and verified: $MS_DST ($(du -h "$MS_DST" | awk '{print $1}'))"
      echo "  SHA-256: $got"
    else
      rm -f "$MS_DST.tmp"
      echo "  WARNING: MuseScore SF2 checksum mismatch (got $got)."
      echo "  Not keeping unverified file."
    fi
  else
    rm -f "$MS_DST.tmp"
    echo "  WARNING: MuseScore SF2 download failed — GeneralUser GS / built-in voice still work."
  fi
else
  echo "== MuseScore General SF2 skipped (pass --with-musescore to fetch ~206 MB) =="
fi

# ── Basic Pitch CoreML model (fetched on demand for M7) ───────────────────────
if [ "$WITH_MODEL" -eq 1 ]; then
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
