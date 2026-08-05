#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT:-$REPO_ROOT/chdtool.sh}"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
export PATH="$REPO_ROOT/tests/bin:$PATH" PROGRESS_STYLE=none LOG_DEST=console LOG_LEVEL_THRESHOLD=ERROR

mkdir "$FIX/default" "$FIX/override" "$FIX/dry"
: > "$FIX/default/Default.iso"
CHDMAN_ARGS_LOG="$FIX/default.args" bash "$SCRIPT" --keep-originals "$FIX/default" >/dev/null
! grep -q -- ' -hs ' "$FIX/default.args" || { echo "FAIL: default conversion forced a hunk size" >&2; exit 1; }

: > "$FIX/override/Override.iso"
CHDMAN_ARGS_LOG="$FIX/override.args" CHDMAN_THREADS=999999 CHDMAN_HUNK_SIZE=8192 \
  bash "$SCRIPT" --keep-originals "$FIX/override" >/dev/null
grep -q -- '-hs 8192' "$FIX/override.args" || { echo "FAIL: hunk override missing" >&2; exit 1; }
threads="$(sed -n 's/.*-np \([0-9][0-9]*\).*/\1/p' "$FIX/override.args")"
(( threads >= 1 && threads <= $(nproc) )) || { echo "FAIL: thread override was not CPU-bounded" >&2; exit 1; }

: > "$FIX/dry/Dry.iso"
dry_output="$(LOG_LEVEL_THRESHOLD=INFO CHDMAN_THREADS=1 CHDMAN_HUNK_SIZE=4096 bash "$SCRIPT" --dry-run "$FIX/dry" 2>&1)"
grep -q -- '-np 1 -hs 4096 -i' <<< "$dry_output" || { echo "FAIL: dry-run command omitted effective options" >&2; exit 1; }

echo "PASS: resource selection and chdman command construction"
