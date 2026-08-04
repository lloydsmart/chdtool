#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT:-$REPO_ROOT/chdtool.sh}"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

export PATH="$REPO_ROOT/tests/bin:$PATH"
export PROGRESS_STYLE=none
export LOG_DEST=console
export LOG_LEVEL_THRESHOLD=ERROR
export CHDMAN_FAIL_INPUT="Transactional Game (Disc 2).iso"

ARCHIVE="$FIX/transactional-game.zip"
(
  cd "$FIX"
  : > "Transactional Game (Disc 1).iso"
  : > "Transactional Game (Disc 2).iso"
  zip -q "$(basename "$ARCHIVE")" \
    "Transactional Game (Disc 1).iso" \
    "Transactional Game (Disc 2).iso"
  rm -f "Transactional Game (Disc 1).iso" "Transactional Game (Disc 2).iso"
)

# Issue #30 owns the overall process exit status; this test asserts filesystem effects only.
bash "$SCRIPT" "$FIX" || true

if [[ ! -f "$ARCHIVE" ]]; then
  echo "FAIL: source archive was deleted after a partial conversion" >&2
  exit 1
fi

if [[ -f "$FIX/Transactional Game.m3u" ]]; then
  echo "FAIL: M3U was generated for an incomplete CHD set" >&2
  exit 1
fi

if [[ ! -f "$FIX/Transactional Game (Disc 1).chd" ]]; then
  echo "FAIL: successfully verified Disc 1 CHD was not finalised" >&2
  exit 1
fi

if [[ -f "$FIX/Transactional Game (Disc 2).chd" ]]; then
  echo "FAIL: failed Disc 2 unexpectedly produced a final CHD" >&2
  exit 1
fi

echo "PASS: partial archive conversion retains source and omits M3U"
