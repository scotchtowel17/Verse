#!/usr/bin/env bash
# Build (if needed) and launch Verse.app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
"$ROOT/scripts/make-app.sh" "$CONFIG"
open "$ROOT/build/Verse.app"
