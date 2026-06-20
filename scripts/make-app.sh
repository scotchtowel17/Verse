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
