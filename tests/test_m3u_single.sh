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

# 1) Single CHD
touch "$FIX/Daytona USA (Disc 1).chd"

# 2) Zip with one entry
(
  cd "$FIX"
  printf "" > "Daytona USA (Disc 1).cue"
  zip -q "daytona.zip" "Daytona USA (Disc 1).cue"
  rm -f "Daytona USA (Disc 1).cue"
)

# 3) Run
bash "$SCRIPT" "$FIX"

# 4) Assert NO M3U
M3U="$FIX/Daytona USA.m3u"
if [[ -f "$M3U" ]]; then
  echo "FAIL: Unexpected M3U created for single-disc set"
  cat "$M3U" >&2
  exit 1
fi

echo "PASS: No M3U created for single-disc set"
