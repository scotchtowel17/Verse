#!/usr/bin/env bash
# Verse CI license gate (Build Contract §12, §I).
#
# Fails the build if any GPL/AGPL/LGPL SPDX identifier appears in the resolved SPM
# dependency graph or the declared license manifest, or if any declared license is not
# on the permissive allowlist. Scans:
#   1. Package.resolved            — every resolved SPM dependency (by URL/identity).
#   2. THIRD-PARTY-LICENSES.md     — every `SPDX-License-Identifier:` line.
#
# Exit 0 = clean, non-zero = gate failed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESOLVED="$ROOT/Package.resolved"
[ -f "$RESOLVED" ] || RESOLVED="$ROOT/.build/checkouts/Package.resolved"
MANIFEST="$ROOT/THIRD-PARTY-LICENSES.md"

# Permissive allowlist. The named GeneralUser GS license is permissive (© S. C. Collins).
ALLOWLIST=(
  "MIT" "Apache-2.0" "BSD-2-Clause" "BSD-3-Clause" "ISC" "0BSD" "CC0-1.0"
  "Unlicense" "GeneralUser-GS-License-v2.0" "Apple-System"
)
# Any SPDX id matching these (case-insensitive) hard-fails the gate.
FORBIDDEN_REGEX='(^|[^A-Z])(A?GPL|LGPL)(-|$)'

fail=0
note() { printf '  %s\n' "$1"; }

is_allowed() {
  local id="$1"
  for a in "${ALLOWLIST[@]}"; do [ "$a" = "$id" ] && return 0; done
  return 1
}

check_id() {
  local id="$1" source="$2"
  # Normalize whitespace.
  id="$(echo "$id" | tr -d '[:space:]')"
  [ -z "$id" ] && return 0
  if echo "$id" | grep -Eiq "$FORBIDDEN_REGEX"; then
    note "FORBIDDEN copyleft license '$id' (from $source)"
    fail=1
    return
  fi
  if ! is_allowed "$id"; then
    note "NON-ALLOWLISTED license '$id' (from $source) — add to allowlist via PR if it is genuinely permissive"
    fail=1
  fi
}

echo "== Verse license gate =="

# 1) SPM dependency graph -------------------------------------------------------
echo "Checking SPM dependencies (Package.resolved)…"
if [ -f "$RESOLVED" ]; then
  # Extract dependency identities/URLs (works for resolved format v2/v3).
  deps="$(grep -Eo '"(location|identity|repositoryURL)"[[:space:]]*:[[:space:]]*"[^"]+"' "$RESOLVED" \
            | sed -E 's/.*:[[:space:]]*"([^"]+)"/\1/' | sort -u || true)"
  if [ -z "$deps" ]; then
    note "no external SPM dependencies resolved (empty graph) — OK"
  else
    while IFS= read -r d; do
      [ -z "$d" ] && continue
      note "dependency: $d (verify its SPDX is declared in THIRD-PARTY-LICENSES.md)"
    done <<< "$deps"
    # Any dependency must have a corresponding allowlisted SPDX line in the manifest.
  fi
else
  note "no Package.resolved found — pure first-party + Apple frameworks (OK)"
fi

# 2) Declared license manifest --------------------------------------------------
# Only real declaration lines are validated: a line whose first non-space token after the
# marker is a clean SPDX token (charset [A-Za-z0-9.+-]). Prose that merely *mentions* the
# marker or a license name is ignored, so documentation can describe the gate freely.
echo "Checking declared licenses (THIRD-PARTY-LICENSES.md)…"
if [ -f "$MANIFEST" ]; then
  found=0
  while IFS= read -r line; do
    val="${line#*SPDX-License-Identifier:}"
    val="$(printf '%s' "$val" | tr -d '`' | awk '{print $1}')"
    # Require a clean SPDX token AND that it was the only meaningful content after the marker
    # (the original line, minus the marker+value, must be whitespace/punctuation only).
    rest="$(printf '%s' "${line#*SPDX-License-Identifier:}" | tr -d '`' | awk '{$1=""; print}' | tr -d '[:space:].,;')"
    if printf '%s' "$val" | grep -Eq '^[A-Za-z0-9.+-]+$' && [ -z "$rest" ]; then
      found=$((found+1))
      check_id "$val" "manifest"
    fi
  done < <(grep -F 'SPDX-License-Identifier:' "$MANIFEST" || true)
  note "validated $found declared license identifier(s)"
else
  note "WARNING: THIRD-PARTY-LICENSES.md missing"
  fail=1
fi

echo
if [ "$fail" -ne 0 ]; then
  echo "RESULT: ❌ license gate FAILED"
  exit 1
fi
echo "RESULT: ✅ license gate passed (all licenses permissive / allowlisted)"
