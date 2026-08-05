#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT:-$REPO_ROOT/chdtool.sh}"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

export PATH="$REPO_ROOT/tests/bin:$PATH"
export PROGRESS_STYLE=none LOG_DEST=console LOG_LEVEL_THRESHOLD=ERROR

run_and_capture() {
  local output_file="$1"; shift
  set +e
  "$@" >"$output_file" 2>&1
  RUN_STATUS=$?
  set -e
}

assert_no_temporary_chds() {
  local directory="$1"
  if find "$directory" -name '*.chd.tmp.*' -print -quit | grep -q .; then
    echo "FAIL: temporary CHD remained in $directory" >&2
    find "$directory" -name '*.chd.tmp.*' -print >&2
    exit 1
  fi
}

# Listing succeeds, but extraction fails: report the extraction error, retain the
# archive, and do not create either final or temporary conversion output.
mkdir -p "$FIX/extraction" "$FIX/extraction-bin"
: > "$FIX/extraction/Broken.zip"
cat > "$FIX/extraction-bin/unzip" <<'STUB'
#!/usr/bin/env bash
if [[ " $* " == *" -Z1 "* ]]; then
  printf '%s\n' 'Extraction Game.iso'
  exit 0
fi
echo 'stub unzip: requested extraction failure' >&2
exit 7
STUB
chmod +x "$FIX/extraction-bin/unzip"
run_and_capture "$FIX/extraction.log" env PATH="$FIX/extraction-bin:$PATH" bash "$SCRIPT" "$FIX/extraction"
[[ $RUN_STATUS -eq 2 ]] || { echo "FAIL: extraction failure returned $RUN_STATUS, expected 2" >&2; exit 1; }
grep -q 'Extraction failed' "$FIX/extraction.log" || { echo "FAIL: extraction failure was not reported" >&2; exit 1; }
[[ -f "$FIX/extraction/Broken.zip" && ! -e "$FIX/extraction/Extraction Game.chd" ]] || {
  echo "FAIL: extraction failure changed source/final output state" >&2; exit 1;
}
assert_no_temporary_chds "$FIX/extraction"

# A newly converted CHD that fails both verification attempts must be removed,
# leave its source intact, and make the overall process fail.
mkdir "$FIX/verification"
: > "$FIX/verification/Verify Game.iso"
verify_log="$FIX/verification-attempts.log"
run_and_capture "$FIX/verification.log" env \
  CHDMAN_FAIL_VERIFY_INPUT='Verify Game.chd' CHDMAN_VERIFY_LOG="$verify_log" \
  bash "$SCRIPT" "$FIX/verification"
[[ $RUN_STATUS -eq 2 ]] || { echo "FAIL: double verification failure returned $RUN_STATUS, expected 2" >&2; exit 1; }
[[ "$(wc -l < "$verify_log")" -eq 2 ]] || { echo "FAIL: expected exactly two verification attempts" >&2; exit 1; }
[[ -f "$FIX/verification/Verify Game.iso" && ! -e "$FIX/verification/Verify Game.chd" ]] || {
  echo "FAIL: unverified output was finalised or its source removed" >&2; exit 1;
}
assert_no_temporary_chds "$FIX/verification"

# A caller-supplied logfile path is authoritative.
mkdir "$FIX/custom-log-input"
: > "$FIX/custom-log-input/Custom Log Game.iso"
custom_log="$FIX/custom/logs/conversion.log"
run_and_capture "$FIX/custom-log.stderr" env LOG_DEST=file LOGFILE="$custom_log" \
  LOG_LEVEL_THRESHOLD=INFO bash "$SCRIPT" --dry-run "$FIX/custom-log-input"
[[ $RUN_STATUS -eq 0 ]] || { echo "FAIL: custom LOGFILE run returned $RUN_STATUS" >&2; cat "$FIX/custom-log.stderr" "$custom_log" >&2; exit 1; }
[[ -s "$custom_log" ]] || { echo "FAIL: custom LOGFILE was not created" >&2; exit 1; }
grep -q 'Script started' "$custom_log" || { echo "FAIL: custom LOGFILE is missing run output" >&2; exit 1; }

# Dry-run may log outside the source directory, but must not mutate anything in
# the input tree (including conversion output, playlists, or temporary files).
mkdir "$FIX/dry-run"
: > "$FIX/dry-run/Dry Game.iso"
before="$(find "$FIX/dry-run" -mindepth 1 -printf '%P|%s|%T@\n' | sort)"
LOG_DEST=file LOGFILE="$FIX/dry-run.log" bash "$SCRIPT" --dry-run "$FIX/dry-run"
after="$(find "$FIX/dry-run" -mindepth 1 -printf '%P|%s|%T@\n' | sort)"
[[ "$before" == "$after" ]] || { echo "FAIL: dry-run mutated the input tree" >&2; diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") >&2 || true; exit 1; }

# Independent RUN_ID/TMPDIR/log paths keep repeated parallel invocations from
# colliding. Run enough jobs to expose shared-name or cleanup races cheaply.
pids=()
for index in 1 2 3 4 5 6; do
  job_dir="$FIX/parallel-$index"
  mkdir "$job_dir"
  : > "$job_dir/Parallel Game $index.iso"
  LOG_DEST=file LOGFILE="$FIX/parallel-$index.log" RUN_ID="regression-$index" \
    TMPDIR="$FIX/tmp-$index" bash "$SCRIPT" "$job_dir" &
  pids+=("$!")
done
for pid in "${pids[@]}"; do
  wait "$pid" || { echo "FAIL: parallel invocation $pid failed" >&2; exit 1; }
done
for index in 1 2 3 4 5 6; do
  [[ -f "$FIX/parallel-$index/Parallel Game $index.chd" && ! -e "$FIX/parallel-$index/Parallel Game $index.iso" ]] || {
    echo "FAIL: parallel invocation $index produced an unstable result" >&2; exit 1;
  }
  assert_no_temporary_chds "$FIX/parallel-$index"
done

echo "PASS: extraction, verification, custom logging, dry-run, and parallel regressions"
