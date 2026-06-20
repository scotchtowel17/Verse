#!/usr/bin/env bash
# Real SIGKILL crash-injection test (Build Contract §G "kill the app mid-recording").
#
# 1. Build VerseCheck and run it in `crash-writer` mode: it writes an in-progress take +
#    journal + autosaved edit to a temp workspace, then blocks.
# 2. SIGKILL (kill -9) that process — no clean shutdown, exactly like a crash.
# 3. Run `crash-recover` mode: assert the autosaved project + in-progress take are recovered.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$(mktemp -d /tmp/verse-crash.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT

echo "== Building VerseCheck =="
( cd "$ROOT" && swift build -c debug >/dev/null )
BIN="$(cd "$ROOT" && swift build -c debug --show-bin-path)/VerseCheck"

echo "== Spawning crash-writer (workspace: $DIR) =="
"$BIN" crash-writer "$DIR" &
PID=$!

# Wait for the writer to signal that crash state is fully on disk.
for _ in $(seq 1 100); do
  [ -f "$DIR/ready" ] && break
  sleep 0.1
done
if [ ! -f "$DIR/ready" ]; then echo "FAIL: writer never became ready"; kill -9 "$PID" 2>/dev/null; exit 1; fi

echo "== SIGKILL (kill -9) the running process =="
kill -9 "$PID" 2>/dev/null
wait "$PID" 2>/dev/null

echo "== Relaunch: run recovery =="
if "$BIN" crash-recover "$DIR"; then
  echo "RESULT: ✅ crash recovery passed"
  exit 0
else
  echo "RESULT: ❌ crash recovery FAILED"
  exit 1
fi
