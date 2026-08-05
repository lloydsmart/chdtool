#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT:-$REPO_ROOT/chdtool.sh}"
if [[ "$SCRIPT" != /* ]]; then
  SCRIPT="$(cd "$(dirname "$SCRIPT")" && pwd)/$(basename "$SCRIPT")"
fi
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
export PATH="$REPO_ROOT/tests/bin:$PATH"

help_output="$(bash "$SCRIPT" --help)"
grep -q '^Usage:' <<< "$help_output" || { echo "FAIL: --help omitted usage" >&2; exit 1; }
grep -q -- '--allow-unverified-cue-audio' <<< "$help_output" || { echo "FAIL: --help omitted audio warning option" >&2; exit 1; }

version_output="$(bash "$SCRIPT" --version)"
[[ "$version_output" =~ ^chdtool\.sh\ [0-9]+\.[0-9]+\.[0-9]+ ]] || { echo "FAIL: unexpected --version output: $version_output" >&2; exit 1; }

mkdir "$FIX/-input"
(
  cd "$FIX"
  cli_output="$(LOG_DEST=console LOG_LEVEL_THRESHOLD=ERROR bash "$SCRIPT" --dry-run --no-file-tee -- -input 2>&1)"
  [[ "$cli_output" != *'unknown predicate'* ]] || { echo "FAIL: leading-dash path reached find as an option" >&2; exit 1; }
)
[[ ! -e "$FIX/logs" ]] || { echo "FAIL: --no-file-tee created a console-backend logfile" >&2; exit 1; }

if TMPDIR="$FIX/dry-temp" LOG_DEST=console LOG_LEVEL_THRESHOLD=ERROR \
  bash "$SCRIPT" --dry-run --no-file-tee "$FIX/-input"; then
  [[ ! -e "$FIX/dry-temp" ]] || { echo "FAIL: dry-run created a temporary workspace" >&2; exit 1; }
else
  echo "FAIL: dry-run CLI invocation failed" >&2
  exit 1
fi

echo "PASS: help, version, option terminator, logging, and dry-run CLI behaviour"
