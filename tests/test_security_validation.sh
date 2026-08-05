#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT:-$REPO_ROOT/chdtool.sh}"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

export PATH="$REPO_ROOT/tests/bin:$PATH"
export PROGRESS_STYLE=none LOG_DEST=console LOG_LEVEL_THRESHOLD=ERROR

expect_failure() {
  local dir="$1"
  set +e
  bash "$SCRIPT" "$dir" >/dev/null 2>&1
  local status=$?
  set -e
  [[ $status -eq 2 ]] || { echo "FAIL: $dir returned $status, expected 2" >&2; exit 1; }
}

# Safe nested references resolve component-by-component and successful direct
# descriptor cleanup removes the complete validated source set.
mkdir -p "$FIX/nested/Tracks"
printf 'FILE "tracks/DATA.BIN" BINARY\n  TRACK 01 MODE1/2352\n' > "$FIX/nested/Game.cue"
: > "$FIX/nested/Tracks/data.bin"
bash "$SCRIPT" "$FIX/nested" >/dev/null
[[ -f "$FIX/nested/Game.chd" && ! -e "$FIX/nested/Game.cue" && ! -e "$FIX/nested/Tracks/data.bin" ]] || {
  echo "FAIL: nested CUE conversion or source-set cleanup" >&2; exit 1;
}

mkdir -p "$FIX/parent" "$FIX/absolute"
printf 'FILE "../outside.bin" BINARY\n' > "$FIX/parent/Unsafe.cue"
: > "$FIX/outside.bin"
printf 'FILE "/tmp/outside.bin" BINARY\n' > "$FIX/absolute/Unsafe.cue"
expect_failure "$FIX/parent"
expect_failure "$FIX/absolute"

mkdir -p "$FIX/gdi" "$FIX/ccd"
printf '1\n1 0 4 2352 missing.bin 0\n' > "$FIX/gdi/Missing.gdi"
printf '[CloneCD]\nVersion=3\n' > "$FIX/ccd/Missing.ccd"
: > "$FIX/ccd/Missing.img"
expect_failure "$FIX/gdi"
expect_failure "$FIX/ccd"

# Both selected entries map to "A - B.chd" after sanitisation.
mkdir -p "$FIX/collision/build"
: > "$FIX/collision/build/A:B.iso"
: > "$FIX/collision/build/A?B.iso"
(cd "$FIX/collision/build" && zip -q ../collision.zip ./*)
expect_failure "$FIX/collision"

# A traversal member must be rejected from the listing before extraction.
mkdir -p "$FIX/traversal/build"
: > "$FIX/traversal/escape.iso"
(cd "$FIX/traversal/build" && zip -q ../traversal.zip ../escape.iso)
expect_failure "$FIX/traversal"

echo "PASS: descriptor and archive security validation"
