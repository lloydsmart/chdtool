#!/usr/bin/env bash
set -euo pipefail

# Paths
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/chdtool.sh"   # <-- adjust name/path if needed
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

# Put our stub chdman first in PATH
export PATH="$REPO_ROOT/tests/bin:$PATH"

# Quiet progress noise; keep originals so we can inspect zip afterward
export PROGRESS_STYLE=none
export KEEP_ORIGINALS=true
export LOG_DEST=console
export LOG_LEVEL_THRESHOLD=DEBUG

# 1) Create empty CHDs that look like a 2-disc set
touch "$FIX/Virtua Fighter (Disc 1).chd"
touch "$FIX/Virtua Fighter (Disc 2).chd"

# 2) Zip that advertises matching disc *images* so your script
#    builds expected_chds from archive entries (no real payload needed)
(
  cd "$FIX"
  # files only need to exist inside the zip list; your code reads names via unzip -Z1
  printf "" > "Virtua Fighter (Disc 1).cue"
  printf "" > "Virtua Fighter (Disc 2).cue"
  zip -q "vf.zip" "Virtua Fighter (Disc 1).cue" "Virtua Fighter (Disc 2).cue"
  rm -f "Virtua Fighter (Disc 1).cue" "Virtua Fighter (Disc 2).cue"
)

# 3) Run the script against the directory
bash "$SCRIPT" "$FIX"

# 4) Assert M3U exists with correct name and order
M3U="$FIX/Virtua Fighter.m3u"
if [[ ! -f "$M3U" ]]; then
  echo "FAIL: M3U not created: $M3U" >&2
  ls -al "$FIX" >&2 || true
  exit 1
fi

# Expected order (sorted by parsed disc number)
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
