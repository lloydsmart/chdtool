#!/usr/bin/env bash
set -euo pipefail

SCRIPT="${SCRIPT:-./chdtool.sh}"   # allow override
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# fresh temp input
INPUT_DIR="$(mktemp -d)"
trap 'rm -rf "$INPUT_DIR"' EXIT

run_case () {
  local name="$1"; shift
  local expect_file="$1"; shift  # 1 if a logfile should be created, 0 if not
  echo "=== CASE: $name ==="

  rm -rf logs
  mkdir -p logs

  # stub bin dir for journald/syslog
  local stub_bin
  stub_bin="$(mktemp -d)"
  chmod 755 "$stub_bin"

  # stub systemd-cat
  cat >"$stub_bin/systemd-cat" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
exit 0
EOF
  chmod +x "$stub_bin/systemd-cat"

  # stub logger
  cat >"$stub_bin/logger" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$stub_bin/logger"

env PATH="$stub_bin:$PATH" \
    RUN_ID="testrun" \
    LOG_LEVEL_THRESHOLD=INFO \
    "$@" \
    "$SCRIPT" --dry-run "$INPUT_DIR"

  if [[ $expect_file -eq 1 ]]; then
    shopt -s nullglob
    files=(logs/*.log)
    shopt -u nullglob
    if [[ ${#files[@]} -ne 1 ]]; then
      echo "FAIL: expected 1 log file, found ${#files[@]}"
      ls -la logs || true
      exit 1
    fi
    if ! grep -q "Script started" "${files[0]}"; then
      echo "FAIL: logfile exists but missing expected content"
      sed -n '1,80p' "${files[0]}" || true
      exit 1
    fi
    echo "PASS: logfile created and contains content (${files[0]})"
  else
    if compgen -G "logs/*.log" > /dev/null; then
      echo "FAIL: no logfile expected, but one was created"
      ls -la logs || true
      exit 1
    fi
    echo "PASS: no logfile created as expected"
  fi

  rm -rf "$stub_bin"
}

# Console backend → file expected
run_case "LOG_DEST=console" 1 LOG_DEST=console

# File backend → file expected
run_case "LOG_DEST=file" 1 LOG_DEST=file

# Syslog + tee ON → file expected
run_case "LOG_DEST=syslog + tee ON" 1 LOG_DEST=syslog LOG_TEE_FILE=1

# Journald + tee ON → file expected
run_case "LOG_DEST=journald + tee ON" 1 LOG_DEST=journald LOG_TEE_FILE=1

# Journald + tee OFF → no file expected
run_case "LOG_DEST=journald + tee OFF" 0 LOG_DEST=journald LOG_TEE_FILE=0
