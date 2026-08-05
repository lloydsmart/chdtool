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

assert_no_temporary_chds() {
  if find "$FIX" -name '*.chd.tmp.*' -print -quit | grep -q .; then
    echo "FAIL: temporary CHD allocation remained in $FIX" >&2
    find "$FIX" -name '*.chd.tmp.*' -print >&2
    exit 1
  fi
}

# A failed converter writes a partial output; chdtool must remove it immediately.
: > "$FIX/Failure Game.iso"
CHDMAN_FAIL_INPUT="Failure Game.iso" bash "$SCRIPT" "$FIX" || true
assert_no_temporary_chds
[[ ! -e "$FIX/Failure Game.chd" ]] || {
  echo "FAIL: failed conversion produced a final CHD" >&2
  exit 1
}
rm -f "$FIX/Failure Game.iso"

# A signal while chdman is active must run the same tracked-file cleanup.
: > "$FIX/Interrupted Game.iso"
READY_FILE="$FIX/chdman.ready"
CHDMAN_READY_FILE="$READY_FILE" CHDMAN_PAUSE_SECONDS=2 \
  bash "$SCRIPT" "$FIX" &
script_pid=$!

for _ in {1..100}; do
  [[ -s "$READY_FILE" ]] && break
  sleep 0.05
done
[[ -s "$READY_FILE" ]] || {
  echo "FAIL: timed out waiting for chdman to start" >&2
  kill "$script_pid" 2>/dev/null || true
  wait "$script_pid" 2>/dev/null || true
  exit 1
}

tmp_path="$(tr -d '\r\n' < "$READY_FILE")"
[[ "$tmp_path" == "$FIX"/* && "$tmp_path" == *'.chd.tmp.'*/*'.chd' ]] || {
  echo "FAIL: chdman did not receive a unique destination-local temporary path: $tmp_path" >&2
  exit 1
}

kill -TERM "$script_pid"
set +e
wait "$script_pid" 2>/dev/null
interrupt_status=$?
set -e
[[ $interrupt_status -eq 130 ]] || {
  echo "FAIL: interruption returned $interrupt_status, expected 130" >&2
  exit 1
}
sleep 2.2
assert_no_temporary_chds
[[ ! -e "$FIX/Interrupted Game.chd" ]] || {
  echo "FAIL: interrupted conversion produced a final CHD" >&2
  exit 1
}

echo "PASS: failed and interrupted conversions clean unique temporary CHDs"
