#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT:-$REPO_ROOT/chdtool.sh}"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

export PATH="$REPO_ROOT/tests/bin:$PATH"
export PROGRESS_STYLE=none
export LOG_DEST=console
export LOG_LEVEL_THRESHOLD=INFO

run_and_capture() {
  local output_file="$1"; shift
  set +e
  "$@" >"$output_file" 2>&1
  RUN_STATUS=$?
  set -e
}

mkdir "$FIX/success"
: > "$FIX/success/Success Game.iso"
run_and_capture "$FIX/success.log" bash "$SCRIPT" "$FIX/success"
[[ $RUN_STATUS -eq 0 ]] || { echo "FAIL: success returned $RUN_STATUS, expected 0" >&2; exit 1; }
grep -q 'Completed successfully' "$FIX/success.log" || { echo "FAIL: clean completion log missing" >&2; exit 1; }

run_and_capture "$FIX/startup.log" bash "$SCRIPT" "$FIX/does-not-exist"
[[ $RUN_STATUS -eq 1 ]] || { echo "FAIL: startup failure returned $RUN_STATUS, expected 1" >&2; exit 1; }

mkdir "$FIX/listing" "$FIX/listing-bin"
: > "$FIX/listing/Broken.zip"
cat > "$FIX/listing-bin/unzip" <<'STUB'
#!/usr/bin/env bash
echo "stub unzip: unreadable archive" >&2
exit 9
STUB
chmod +x "$FIX/listing-bin/unzip"
run_and_capture "$FIX/listing.log" env PATH="$FIX/listing-bin:$PATH" bash "$SCRIPT" "$FIX/listing"
[[ $RUN_STATUS -eq 2 ]] || { echo "FAIL: archive listing failure returned $RUN_STATUS, expected 2" >&2; exit 1; }
grep -q 'Archive listing failed' "$FIX/listing.log" || { echo "FAIL: listing failure was not reported explicitly" >&2; exit 1; }
if grep -q 'no disc files found' "$FIX/listing.log"; then
  echo "FAIL: listing failure was reported as an empty archive" >&2
  exit 1
fi
grep -q 'Completed with failures' "$FIX/listing.log" || { echo "FAIL: failed completion log missing" >&2; exit 1; }

echo "PASS: success, startup, and archive-listing exit statuses"
