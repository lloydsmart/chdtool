#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT:-$REPO_ROOT/chdtool.sh}"   # <— CHANGED: allow override via env
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

export PATH="$REPO_ROOT/tests/bin:$PATH"
export PROGRESS_STYLE=none
export KEEP_ORIGINALS=true
export LOG_DEST=console
export LOG_LEVEL_THRESHOLD=DEBUG

# 1) Create empty CHDs that look like a 2-disc set
touch "$FIX/Virtua Fighter (Disc 1).chd"
touch "$FIX/Virtua Fighter (Disc 2).chd"

# 2) Create a zip whose listing seeds expected_chds
(
  cd "$FIX"
  printf "" > "Virtua Fighter (Disc 1).cue"
  printf "" > "Virtua Fighter (Disc 2).cue"
  zip -q "vf.zip" "Virtua Fighter (Disc 1).cue" "Virtua Fighter (Disc 2).cue"
  rm -f "Virtua Fighter (Disc 1).cue" "Virtua Fighter (Disc 2).cue"
)

# 3) Run the script
bash "$SCRIPT" "$FIX"

# 4) Assert M3U exists + order
M3U="$FIX/Virtua Fighter.m3u"
if [[ ! -f "$M3U" ]]; then
  echo "FAIL: M3U not created: $M3U" >&2
  ls -al "$FIX" >&2 || true
  exit 1
fi

expected=$'Virtua Fighter (Disc 1).chd\nVirtua Fighter (Disc 2).chd'
actual="$(tr -d '\r' < "$M3U")"

if [[ "$actual" != "$expected" ]]; then
  echo "FAIL: M3U contents mismatch" >&2
  echo "--- expected ---" >&2
  echo "$expected" >&2
  echo "--- actual -----" >&2
  echo "$actual" >&2
  exit 1
fi

echo "PASS: M3U generated and correctly ordered"
