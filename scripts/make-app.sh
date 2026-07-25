#!/usr/bin/env bash
# Build Verse with SwiftPM and assemble a runnable, ad-hoc-signed Verse.app bundle.
#
# Why this exists: this machine has Command Line Tools (no full Xcode), so there is no
# `xcodebuild -scheme Verse`. We build the executable with `swift build`, wrap it in a
# proper .app bundle (Info.plist with NSMicrophoneUsageDescription), copy SwiftPM resource
# bundles next to it, and ad-hoc code-sign with the audio-input entitlement so the OS will
# grant microphone access. No Team ID, no paid account, no notarization required.
#
# Usage: scripts/make-app.sh [debug|release]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
APP="$ROOT/build/Verse.app"

# GeneralUser GS SF2: optional but strongly preferred. Fetched when missing so a fresh
# clone still ships real instruments. Checksum from THIRD-PARTY-LICENSES.md; never bundle
# an unverified binary. App still builds and makes sound without it (built-in voice).
SF2_DST="$ROOT/Sources/VerseEngine/Resources/GeneralUserGS.sf2"
SF2_URL="https://raw.githubusercontent.com/mrbumpy409/GeneralUser-GS/main/GeneralUser-GS.sf2"
SF2_EXPECTED_SHA="9575028c7a1f589f5770fccc8cff2734566af40cd26ed836944e9a5152688cfe"

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

ensure_sf2() {
  echo "== Ensuring GeneralUser GS SF2 =="
  if [ -f "$SF2_DST" ]; then
    local got
    got="$(sha256_of "$SF2_DST")"
    if [ "$got" = "$SF2_EXPECTED_SHA" ]; then
      echo "  present and verified ($(du -h "$SF2_DST" | awk '{print $1}'))"
      return 0
    fi
    echo "  WARNING: existing SF2 checksum mismatch (got $got)."
    echo "  Removing unverified file; will re-fetch."
    rm -f "$SF2_DST"
  else
    echo "  not present; fetching…"
  fi

  if curl -fSL -m 180 "$SF2_URL" -o "$SF2_DST.tmp"; then
    local got
    got="$(sha256_of "$SF2_DST.tmp")"
    if [ "$got" = "$SF2_EXPECTED_SHA" ]; then
      mv "$SF2_DST.tmp" "$SF2_DST"
      echo "  saved and verified: $SF2_DST ($(du -h "$SF2_DST" | awk '{print $1}'))"
    else
      rm -f "$SF2_DST.tmp"
      echo "  WARNING: downloaded SF2 checksum mismatch (got $got, expected $SF2_EXPECTED_SHA)."
      echo "  Not bundling unverified binary; app will use the sampler's built-in default voice."
    fi
  else
    rm -f "$SF2_DST.tmp"
    echo "  WARNING: SF2 download failed — app will use the sampler's built-in default voice."
  fi
}

ensure_sf2

echo "== Building Verse ($CONFIG) with SwiftPM =="
( cd "$ROOT" && swift build -c "$CONFIG" )

BIN_DIR="$(cd "$ROOT" && swift build -c "$CONFIG" --show-bin-path)"
EXE="$BIN_DIR/Verse"
[ -x "$EXE" ] || { echo "ERROR: built executable not found at $EXE"; exit 1; }

echo "== Assembling $APP =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$EXE" "$APP/Contents/MacOS/Verse"
cp "$ROOT/Config/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Copy SwiftPM-generated resource bundles (Verse_*.bundle) so Bundle.module resolves
# at runtime. Bundle.main.resourceURL inside the .app is Contents/Resources.
shopt -s nullglob
for b in "$BIN_DIR"/*.bundle; do
  echo "  bundling resource: $(basename "$b")"
  cp -R "$b" "$APP/Contents/Resources/"
done
shopt -u nullglob

echo "== Code signing (ad-hoc) =="
# Sign nested resource bundles first, then the app with entitlements.
find "$APP/Contents/Resources" -maxdepth 1 -name '*.bundle' -print0 2>/dev/null \
  | while IFS= read -r -d '' nb; do codesign --force --sign - "$nb" >/dev/null 2>&1 || true; done
codesign --force --sign - \
  --entitlements "$ROOT/Config/Verse.entitlements" \
  --identifier "com.verse.app" \
  "$APP"

echo "== Verifying signature =="
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/  /' || true

echo
echo "✅ Built: $APP"
echo "   Run with:  open \"$APP\"     (or: scripts/run.sh)"
