#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT:-$REPO_ROOT/chdtool.sh}"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
export PATH="$REPO_ROOT/tests/bin:$PATH"
export PROGRESS_STYLE=none LOG_DEST=console LOG_LEVEL_THRESHOLD=ERROR

make_archive() {
  local archive="$1"; shift
  (cd "$FIX" && zip -q "$(basename "$archive")" "$@" && rm -f -- "$@")
}

printf 'existing-valid\n' > "$FIX/Resume Game (Disc 1).chd"
: > "$FIX/Resume Game (Disc 1).iso"
: > "$FIX/Resume Game (Disc 2).iso"
archive="$FIX/resume-game.zip"
make_archive "$archive" "Resume Game (Disc 1).iso" "Resume Game (Disc 2).iso"
create_log="$FIX/create.log"
CHDMAN_CREATE_LOG="$create_log" bash "$SCRIPT" "$FIX"
[[ "$(cat "$FIX/Resume Game (Disc 1).chd")" == "existing-valid" ]] || { echo "FAIL: valid CHD replaced" >&2; exit 1; }
[[ "$(wc -l < "$create_log")" -eq 1 ]] && grep -q 'Disc 2' "$create_log" || { echo "FAIL: expected only Disc 2 conversion" >&2; exit 1; }
[[ -f "$FIX/Resume Game (Disc 2).chd" && -f "$FIX/Resume Game.m3u" && ! -e "$archive" ]] || { echo "FAIL: resumed set incomplete" >&2; exit 1; }

printf 'INVALID\n' > "$FIX/Replace Game.chd"
: > "$FIX/Replace Game.iso"
archive="$FIX/replace-game.zip"
make_archive "$archive" "Replace Game.iso"
: > "$create_log"
CHDMAN_CREATE_LOG="$create_log" bash "$SCRIPT" "$FIX"
[[ "$(wc -l < "$create_log")" -eq 1 ]] || { echo "FAIL: invalid CHD not converted once" >&2; exit 1; }
grep -q '^converted:' "$FIX/Replace Game.chd" || { echo "FAIL: invalid CHD not replaced" >&2; exit 1; }
[[ ! -e "$archive" ]] || { echo "FAIL: source retained after replacement" >&2; exit 1; }

echo "PASS: partial resume uses explicit output states"
