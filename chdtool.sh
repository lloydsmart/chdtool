#!/usr/bin/env bash

set -euo pipefail
set +H
script_start_time=$(date +%s)
shopt -s nullglob
shopt -s extglob

USAGE="Usage: $0 [--keep-originals|-k] [--recursive|-r] <input directory>"
KEEP_ORIGINALS=false
RECURSIVE=false
INPUT_DIR=""
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)-$$}"
CHDMAN_MSG_LEVEL="${CHDMAN_MSG_LEVEL:-DEBUG}"
case "${CHDMAN_MSG_LEVEL^^}" in
  DEBUG|INFO|WARN|ERROR) ;;     # OK
  *) CHDMAN_MSG_LEVEL="INFO" ;; # fallback
esac
    
# Manual parsing to support long options
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-originals|-k)
            KEEP_ORIGINALS=true; shift ;;
        --recursive|-r)
            RECURSIVE=true; shift ;;
        -*)
            echo "❌ Unknown option: $1"
            echo "$USAGE"; exit 1 ;;
        *)
            if [[ -z "$INPUT_DIR" ]]; then
                INPUT_DIR="${1%/}" # Remove trailing slash
            else
                echo "❌ Unexpected extra argument: $1"
                echo "$USAGE"; exit 1
            fi
            shift ;;
    esac
done

if [[ -z "$INPUT_DIR" ]]; then
    echo "$USAGE"; exit 1
fi

mkdir -p logs
if [[ ! -d "$INPUT_DIR" ]]; then
  echo "❌ Input directory does not exist or is not a directory: $INPUT_DIR" >&2
  exit 1
fi
LOGFILE="logs/chd_conversion_$(date +%Y%m%d_%H%M%S).log"

# --- Pluggable logging: console/file/syslog/journald (auto) -------------------
# Control via env vars (no root needed to write to journald/syslog):
#   LOG_DEST=auto|console|file|syslog|journald
#   LOGFILE=/path/to/file   (used when LOG_DEST=file; defaults to ./logs/…)
#   LOG_TAG=chdtool
LOG_DEST="${LOG_DEST:-auto}"
LOG_TAG="${LOG_TAG:-chdtool}"

_detect_backend() {
  case "$LOG_DEST" in
    journald) echo journald ;;
    syslog)   echo syslog   ;;
    file)     echo file     ;;
    console)  echo console  ;;
    auto)
      if [[ -S /run/systemd/journal/socket ]] && command -v systemd-cat >/dev/null 2>&1; then
        echo journald
      elif command -v logger >/dev/null 2>&1; then
        echo syslog
      else
        echo file
      fi
      ;;
    *) echo file ;;
  esac
}
LOG_BACKEND="$(_detect_backend)"

# add RUN_ID tag only for journald/syslog
if [[ "$LOG_BACKEND" == journald || "$LOG_BACKEND" == syslog ]]; then
  LOG_TAG="${LOG_TAG}[${RUN_ID}]"
fi

# ensure the logfile directory exists when we write to a file (console tees to file as well)
if [[ "$LOG_BACKEND" == file || "$LOG_BACKEND" == console ]]; then
  mkdir -p -- "$(dirname -- "$LOGFILE")"
fi

# Mirror policy: auto (TTY only), 1 (always), 0 (never)
LOG_TEE_CONSOLE="${LOG_TEE_CONSOLE:-auto}"

__should_mirror_console() {
  case "${LOG_TEE_CONSOLE}" in
    1|true|yes) return 0 ;;
    0|false|no) return 1 ;;
    auto) [[ -t 2 ]] && return 0 || return 1 ;;  # use fd 2
    *) return 1 ;;
  esac
}

__console_print() {
  # $1=ts, $2=level, $3=message (may be multiline)
  local ts="$1" lvl="$2" msg="$3"
  while IFS= read -r line; do
    printf '[%s] %s: %s\n' "$ts" "$lvl" "$line" >&2
  done <<< "$msg"
}

# Internal emitter: $1=LEVEL (INFO/WARN/ERROR/DEBUG), $2...=message
_emit_log() {
  local lvl="$1"; shift || true
  local msg="${*:-}"
  local ts; ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

  local pri=info
  case "$lvl" in
    DEBUG) pri=debug ;;
    INFO)  pri=info  ;;
    WARN)  pri=warning ;;
    ERROR) pri=err ;;
  esac

  case "$LOG_BACKEND" in
    journald)
      {
        echo "LEVEL=$lvl"
        echo "RUN_ID=$RUN_ID"
        while IFS= read -r line; do echo "$line"; done <<< "$msg"
      } | systemd-cat --priority="$pri" --identifier="$LOG_TAG"
      __should_mirror_console && __console_print "$ts" "$lvl" "$msg"
      ;;
    syslog)
      while IFS= read -r line; do
        logger -p "user.$pri" -t "$LOG_TAG" -- "$lvl: $line"
      done <<< "$msg"
      __should_mirror_console && __console_print "$ts" "$lvl" "$msg"
      ;;
    file)
      while IFS= read -r line; do
        printf '[%s] %s: %s\n' "$ts" "$lvl" "$line" >> "$LOGFILE"
      done <<< "$msg"
      __should_mirror_console && __console_print "$ts" "$lvl" "$msg"
      ;;
    console|*)
      while IFS= read -r line; do
        printf '[%s] %s: %s\n' "$ts" "$lvl" "$line" | tee -a "$LOGFILE"
      done <<< "$msg"
      ;;
  esac
}

# Public logger. Backwards-compatible: `log "message"` still works.
# Optional levels: `log INFO "message"`, `log WARN "msg"`, etc.
LOG_LEVEL_THRESHOLD="${LOG_LEVEL_THRESHOLD:-INFO}"   # DEBUG|INFO|WARN|ERROR
__level_num() { case "$1" in DEBUG) echo 10;; INFO) echo 20;; WARN) echo 30;; ERROR) echo 40;; *) echo 999;; esac; }

log() {
  local lvl="INFO"
  case "${1:-}" in DEBUG|INFO|WARN|ERROR) lvl="$1"; shift ;; esac
  if (( $(__level_num "$lvl") < $(__level_num "$LOG_LEVEL_THRESHOLD") )); then
    return 0
  fi
  _emit_log "$lvl" "$*"
}

log INFO "🚀 Script started, input dir: $INPUT_DIR"
[[ "$RECURSIVE" == true ]] && log INFO "📂 Recursive mode enabled — scanning subdirectories"

verify_output_log() {
  local lvl="${1:-INFO}"
  case "$lvl" in DEBUG|INFO|WARN|ERROR) shift || true ;; *) lvl="INFO" ;; esac
  while IFS= read -r line; do
    log "$lvl" "$line"
  done
}

is_in_list() {
  local needle="$1"; shift
  local x
  for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
  return 1
}

required_commands=(chdman unzip unrar 7z stat awk)
archive_exts=(zip rar 7z 7zip)
disc_exts=(iso cue gdi ccd)
all_exts=("${archive_exts[@]}" "${disc_exts[@]}")

get_chd_basename() {
    local file="$1"
    basename "${file%.*}"
}

build_find_expr() {
    local patterns=("$@")
    local expr=()
    for ext in "${patterns[@]}"; do
        expr+=("-iname" "*.${ext}" "-o")
    done
    unset "expr[${#expr[@]}-1]"   # Remove trailing -o
    echo "${expr[@]}"
}

build_ext_regex() {
    local exts=("$@")
    local regex="\."
    regex+="($(IFS='|'; echo "${exts[*]}"))\$"
    echo "$regex"
}

for cmd in "${required_commands[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log ERROR "❌ Error: Required command '$cmd' not found. Please install it and ensure it's in your PATH."
        exit 1
    fi
done

chdman_version="$(chdman --help 2>&1 | head -n 1 || true)"
log INFO "ℹ️ Using $chdman_version"
# Detect 'createdvd' capability (newer chdman versions)
CHDMAN_HAS_CREATEDVD=false
if chdman -help 2>&1 | grep -qiE '(^|[[:space:]])createdvd([[:space:]]|$)'; then
    CHDMAN_HAS_CREATEDVD=true
fi
log DEBUG "ℹ️ chdman createdvd support: $CHDMAN_HAS_CREATEDVD"


total_original_size=0
total_chd_size=0
archives_processed=0
chds_created=0
failures=0

human_readable() {
    local bytes=$1
    if [[ $bytes -lt 1024 ]]; then
        echo "${bytes} B"
    elif [[ $bytes -lt 1048576 ]]; then
        echo "$((bytes / 1024)) KB"
    elif [[ $bytes -lt 1073741824 ]]; then
        echo "$((bytes / 1048576)) MB"
    else
        echo "$((bytes / 1073741824)) GB"
    fi
}

format_duration() {
    local total_seconds=$1
    local minutes=$((total_seconds / 60))
    local seconds=$((total_seconds % 60))
    if (( minutes > 0 )); then
        printf "%dm %02ds" "$minutes" "$seconds"
    else
        printf "%ds" "$seconds"
    fi
}

get_file_size() {
    if stat --version >/dev/null 2>&1; then
        stat -c%s "$1"
    else
        stat -f%z "$1"
    fi
}

# ---------- chdman progress handling ----------
# Config: PROGRESS_STYLE=auto|bar|line|none ; default: auto (TTY -> bar, non-TTY -> none)
PROGRESS_STYLE_DEFAULT="auto"
PROGRESS_THROTTLE_MS=250   # reduce flicker
PROGRESS_BAR_MAX=40        # hard cap so we don't get too wide
PROGRESS_MARGIN=28         # spare columns to avoid wrap (emoji-width safety)

# Print N copies of a char
_repeat_char() { local n=$1 c=$2 out=""; while (( n-- > 0 )); do out+="$c"; done; printf "%s" "$out"; }

# Draw a single-line status (bar or line) to stderr, staying on one row.
PROGRESS_BAR_MAX=${PROGRESS_BAR_MAX:-40}
PROGRESS_FUDGE=${PROGRESS_FUDGE:-8}   # extra safety to prevent wrap with wide glyphs

_term_print() {
  if [[ -t 2 && -w /dev/tty ]]; then
    printf "%b" "$1" > /dev/tty
  else
    printf "%b" "$1" >&2
  fi
}

_draw_progress() {
    local phase="$1" pct="$2" ratio="$3"
    local style="${PROGRESS_STYLE:-$PROGRESS_STYLE_DEFAULT}"

    if [[ "$style" == "auto" ]]; then
        if [[ -t 2 ]]; then style="bar"; else style="none"; fi
    fi
    [[ "$style" == "none" ]] && return 0

    local cols="${COLUMNS:-}"
    [[ -z "$cols" && -t 2 ]] && cols=$(tput cols 2>/dev/null || echo 80)
    [[ -z "$cols" ]] && cols=80

    local left="⏳ ${phase} ${pct}%"
    [[ -n "$ratio" ]] && left+=" (r=${ratio}%)"

    local text
    if [[ "$style" == "line" ]]; then
        text="$left"
    else
        local margin=${PROGRESS_MARGIN:-20}
        local barw=$(( cols - (${#left} + margin) ))
        local cap=${PROGRESS_BAR_MAX:-40}
        (( barw > cap )) && barw=$cap
        (( barw < 10 )) && barw=10
        local scaled; scaled="$(awk -v p="$pct" -v w="$barw" 'BEGIN{ printf "%.0f",(p/100.0)*w }')" || scaled=0
        [[ -z "$scaled" ]] && scaled=0
        (( scaled < 0 )) && scaled=0
        (( scaled > barw )) && scaled=$barw
        local filled=$scaled
        local empty=$(( barw - filled ))
        text="$left [$(_repeat_char "$filled" "#")$(_repeat_char "$empty" "-")]"
    fi

    (( ${#text} > cols-2 )) && text="${text:0:cols-2}"

    # CR + clear + draw with autowrap temporarily off; NO newline
    _term_print "\r\033[2K\033[?7l${text}\033[?7h"
}

_now_ms() {
    local s
    if s="$(date +%s%3N 2>/dev/null)"; then
        printf '%s' "$s"
    else
        printf '%s' $(( $(date +%s) * 1000 ))
    fi
}

# Parse chdman stderr, render single-line progress, pass through non-progress lines
# --- REPLACE your _chdman_progress_filter with this ---
_chdman_progress_filter() {
    # Always re-enable autowrap on exit/interrupt
    _restore_wrap() { _term_print "\033[?7h"; }
    trap _restore_wrap INT TERM EXIT

    local last_draw=0 phase="Compressing" ratio="" progress_active=0 ms

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ([0-9]+([.][0-9]+)?)%[[:space:]]*complete ]]; then
            local pct="${BASH_REMATCH[1]}"
            [[ "$line" =~ ^([A-Za-z]+), ]] && phase="${BASH_REMATCH[1]}"
            if [[ "$line" =~ \(ratio=([0-9]+([.][0-9]+)?)%\) ]]; then ratio="${BASH_REMATCH[1]}"; else ratio=""; fi

            ms="$(_now_ms)"
            if (( ms - last_draw >= PROGRESS_THROTTLE_MS )); then
                _draw_progress "$phase" "$pct" "$ratio"
                last_draw=$ms
                progress_active=1
            fi
            continue
        fi

        # Ignore obvious chopped progress fragments
        if [[ "$line" =~ ^[[:space:]]*([A-Za-z]+,)?[[:space:]]*$ ]] || \
            [[ "$line" =~ ^[[:space:]]*[0-9]+([.][0-9]+)?[[:space:]]*$ ]]; then
            continue
        fi

        log "$CHDMAN_MSG_LEVEL" "$line"
    done

    # At EOF: end the progress line neatly with a single newline
    (( progress_active )) && _term_print "\r\033[2K\n"
}

# Wrapper to run chdman with a clean one-line progress display.
# Usage: run_chdman_progress createcd -i "$in" -o "$out"
run_chdman_progress() {
    # local last_draw=0 phase="Compressing" ratio="" progress_active=0 ms
    local bin="${CHDMAN_BIN:-chdman}"
    if [[ -t 2 && "${PROGRESS_STYLE:-$PROGRESS_STYLE_DEFAULT}" != "none" ]]; then
        "$bin" "$@" 2>&1 | _chdman_progress_filter
    else
        "$bin" "$@"
    fi
}
# ---------- end chdman progress ----------

# ---------- M3U (per-iteration) helpers ----------
# Trim leading/trailing spaces/dots/underscores/dashes
trim() {
    local s="$*"
    s="${s##+([[:space:]._-])}"
    s="${s%%+([[:space:]._-])}"
    printf "%s" "$s"
}

# --- helpers for robust parsing ---
normalize_for_parse() {
  # Normalize to make matching easier (full-width → ASCII, unify spaces/dashes)
  local s="$*"
  if command -v perl >/dev/null 2>&1; then
    s="$(printf '%s' "$s" | perl -CS -Mutf8 -pe '
      # full-width digits → ASCII
      tr/\x{FF10}-\x{FF19}/0-9/;
      # full-width parens/brackets → ASCII
      tr/\x{FF08}\x{FF09}/()/;     # （ ）
      tr/\x{FF3B}\x{FF3D}/[]/;     # ［ ］
      # ideographic space → normal space
      tr/\x{3000}/ /;
      # unify dashes to ASCII hyphen
      s/[-–—−―]/-/g;
    ')"
  fi
  printf '%s' "$s"
}

tidy_base() {
  # Trim + drop lingering separators/brackets at the end
  local s="$*"
  s="$(trim "$s")"
  if command -v perl >/dev/null 2>&1; then
    s="$(printf '%s' "$s" | perl -CS -Mutf8 -pe 's/[ \t._-]*[([{（［｛]*\s*$//')"
  else
    s="$(printf '%s' "$s" | sed -E 's/[[:space:]._-]*[\(\[\{]+[[:space:]]*$//')"
  fi
  printf '%s' "$s"
}

letter_to_num() {
  # A→1, B→2, … Z→26
  local L="${1:-}"
  [[ -z "$L" ]] && { echo ""; return 1; }
  L="${L^^}"
  printf '%d\n' $(( $(printf '%d' "'${L:0:1}") - 64 ))
}

# Parse disc info from a base name (no extension).
# On success, echoes "<base>|<disc_num>" and returns 0; else returns 1.
parse_disc_info() {
  local name="$1"
  local name_norm; name_norm="$(normalize_for_parse "$name")"

  # Pattern set 1: Disc/CD/Disk/GD(-ROM)? with optional separator or none:
  # e.g., "Title Disc2", "Title (CD-2)", "Title [Disk02]", "Title GD-ROM 3", "Title Disc 01"
  local re_core='([Dd]isc|[Cc][Dd]|[Dd]isk|[Gg][Dd](?:-[Rr][Oo][Mm])?)'
  local re_num='([0-9]{1,3})'
  local re_sep='[[:space:]]*[-_\.]?[[:space:]]*'

  if [[ "$name_norm" =~ ^(.*?)[[:space:]._-]*\(?$re_core$re_sep$re_num\)?([[:space:]]*.*)?$ ]]; then
    local base="${BASH_REMATCH[1]}"
    local num="${BASH_REMATCH[3]}"   # (1=label,2=sep? depends on grouping; ensure index)
    # Because of our grouping above, indexes are:
    # 1=prefix, 2=label, 3=number, 4=tail
    base="$(tidy_base "$base")"
    [[ -n "$base" && -n "$num" ]] && { echo "$base|$num"; return 0; }
  fi

  # Pattern set 2: Vol/Volume, Part/Pt
  if [[ "$name_norm" =~ ^(.*?)[[:space:]._-]*\(?([Vv]ol(?:ume)?|[Pp](?:art|t\.?))$re_sep$re_num\)?([[:space:]]*.*)?$ ]]; then
    local base="${BASH_REMATCH[1]}"
    local num="${BASH_REMATCH[3]}"
    base="$(tidy_base "$base")"
    [[ -n "$base" && -n "$num" ]] && { echo "$base|$num"; return 0; }
  fi

  # Pattern set 3: Side A/B/C… (map letters → 1/2/3…)
  if [[ "$name_norm" =~ ^(.*?)[[:space:]._-]*\(?([Ss]ide)[[:space:]]*([A-Za-z])\)?([[:space:]]*.*)?$ ]]; then
    local base="${BASH_REMATCH[1]}"
    local letter="${BASH_REMATCH[3]}"
    local num; num="$(letter_to_num "$letter")" || num=""
    base="$(tidy_base "$base")"
    [[ -n "$base" && -n "$num" ]] && { echo "$base|$num"; return 0; }
  fi

  # Pattern set 4: "1 of 2" / "1/2"
  if [[ "$name_norm" =~ ^(.*?)[[:space:]._-]*\(?([0-9]+)[[:space:]]*(?:of|/)[[:space:]]*[0-9]+\)?([[:space:]]*.*)?$ ]]; then
    local base="${BASH_REMATCH[1]}"
    local num="${BASH_REMATCH[2]}"
    base="$(tidy_base "$base")"
    [[ -n "$base" && -n "$num" ]] && { echo "$base|$num"; return 0; }
  fi

  # Pattern set 5: compact forms WITHOUT spaces/brackets:
  # "Title Disc02", "Title CD2", "Title Vol.2", "Title Pt.3"
  if [[ "$name_norm" =~ ^(.*?)[[:space:]._-]*(?:$re_core|[Vv]ol(?:ume)?|[Pp](?:art|t\.?))$re_sep$re_num([[:space:]]*.*)?$ ]]; then
    local base="${BASH_REMATCH[1]}"
    local num="${BASH_REMATCH[3]}"
    base="$(tidy_base "$base")"
    [[ -n "$base" && -n "$num" ]] && { echo "$base|$num"; return 0; }
  fi

  return 1
}

# Make a filename safe across Linux/macOS/Windows shares.
# - normalizes Unicode if `uconv` is available
# - removes control chars
# - replaces / \ : * ? " < > | with '-'
# - collapses whitespace; trims ends
# - optional Windows reserved-name guard (SANITIZE_CROSSPLATFORM=0 to disable)
# - truncates to a safe length (default 200 chars)
sanitize_filename() {
  local s="$1"

  # Unicode NFKC normalization if ICU's uconv exists (nice-to-have)
  if command -v uconv >/dev/null 2>&1; then
    s="$(printf '%s' "$s" | uconv -x any-nfkc 2>/dev/null || printf '%s' "$s")"
  fi

  # Strip control chars
  s="$(printf '%s' "$s" | tr -d '\000-\037\177')"

  # Replace problematic characters and tidy spaces/dashes
  s="$(printf '%s' "$s" \
      | sed -E 's/[\/\\:*?"<>|]/-/g; s/[[:space:]]+/ /g; s/[[:space:]]*-[[:space:]]*/ - /g')"

  # Trim leading/trailing separators/spaces
  s="$(printf '%s' "$s" | sed -E 's/^[[:space:]._-]+//; s/[[:space:]._-]+$//')"

  # Guard Windows reserved basenames for SMB users
  if [[ "${SANITIZE_CROSSPLATFORM:-1}" == 1 ]]; then
    case "${s^^}" in
      CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9]) s="_$s";;
    esac
  fi

  # Length cap (characters). 200 is comfortably under 255-byte limits.
  local max=${FILENAME_MAX_CHARS:-200}
  if (( ${#s} > max )); then
    s="${s:0:max}"
    s="$(printf '%s' "$s" | sed -E 's/[[:space:]._-]+$//')"  # re-trim tail
  fi

  [[ -z "$s" ]] && s="Set"
  printf '%s' "$s"
}

# Build/refresh a single M3U for a given base in one directory.
# We only consider CHDs that share the parsed base (case-insensitive).
generate_m3u_for_base() {
    local outdir="$1"
    local base="$2"
    local -a members=()

    local f stem p p_base
    while IFS= read -r -d '' f; do
        stem="${f##*/}"; stem="${stem%.chd}"
        if p="$(parse_disc_info "$stem")"; then
            p_base="${p%%|*}"
            if [[ "${p_base,,}" == "${base,,}" ]]; then
                members+=("$f")
            fi
        fi
    done < <(find "$outdir" -maxdepth 1 -type f -iname "*.chd" -print0)

    if (( ${#members[@]} < 2 )); then
        log DEBUG "ℹ️ Not generating M3U - fewer than two CHDs found for base: $base"
        return 0
    fi

    # Sort by parsed disc number
    local sorted
    sorted="$(
      for f in "${members[@]}"; do
        stem="${f##*/}"; stem="${stem%.chd}"
        p="$(parse_disc_info "$stem")"
        echo "${p##*|}|$f"
      done | sort -t'|' -k1,1n | cut -d'|' -f2
    )"
    mapfile -t members <<< "$sorted"

    # Write idempotently (relative file names in body)
    # inside generate_m3u_for_base, after computing safe_base
    local safe_base; safe_base="$(sanitize_filename "$base")"
    local legacy_path="$outdir/${base}.m3u"
    local m3u_path="$outdir/${safe_base}.m3u"

    # migrate legacy → sanitized (only if sanitized doesn't exist yet)
    if [[ -f "$legacy_path" && ! -f "$m3u_path" ]]; then
        mv -f "$legacy_path" "$m3u_path"
        log INFO "🧹 Renamed legacy M3U → sanitized: $(basename "$legacy_path") → $(basename "$m3u_path")"
    fi

    local tmp_m3u="$m3u_path.tmp"
    : > "$tmp_m3u"
    for f in "${members[@]}"; do
        printf '%s\n' "$(basename "$f")" >> "$tmp_m3u"
    done
    if [[ -f "$m3u_path" ]] && cmp -s "$tmp_m3u" "$m3u_path"; then
        rm -f "$tmp_m3u"
        log INFO "🧾 M3U up-to-date: $m3u_path"
    else
        # Remember pre-move existence to log Created vs Updated correctly
        local _m3u_existed=false
        [[ -f "$m3u_path" ]] && _m3u_existed=true
        mv -f "$tmp_m3u" "$m3u_path"
        if [[ "$_m3u_existed" == true ]]; then
            log INFO "📝 Updated M3U: $m3u_path"
        else
            log INFO "🆕 Created M3U: $m3u_path"
        fi
    fi
}

# Decide if $chd_base looks like a multi-disc title and (re)generate its M3U now.
maybe_generate_m3u_for() {
    local chd_base="$1"   # e.g. "Virtua Fighter (Disc 2)"
    local outdir="$2"     # directory where CHDs live
    local parsed
    if ! parsed="$(parse_disc_info "$chd_base")"; then
        log DEBUG "ℹ️ Not generating M3U - CHD not part of multi-disc set: $chd_base"
        return 0
    fi
    local base="${parsed%%|*}"
    log DEBUG "🔎 M3U check — base: $base"
    generate_m3u_for_base "$outdir" "$base"
}
# ---------- end M3U helpers ----------

verify_chds() {
    local outdir="$1"; shift
    local chds=("$@")
    local all_verified=true
    for chd in "${chds[@]}"; do
        local chd_path="$outdir/$chd"
        if [[ ! -f "$chd_path" ]]; then
            all_verified=false
            break
        fi
        local verify_output
        local verify_exit_code

        log INFO "🔎 Verifying: $chd_path"
        verify_output=$(chdman verify -i "$chd_path" 2>&1)
        verify_exit_code=$?
        echo "$verify_output" | verify_output_log INFO

        if [[ $verify_exit_code -ne 0 ]] || ! echo "$verify_output" | grep -qi "verification successful"; then
            local failure_reasons
            failure_reasons=$(echo "$verify_output" | grep -iE 'error|fail|invalid|corrupt' || true)
            log WARN "⚠️ Verification failed on first try for: $chd_path"
            [[ -n "$failure_reasons" ]] && log DEBUG "   Failure details: $failure_reasons"
            log INFO "⏳ Retrying after delay..."
            sleep 2

            log INFO "🔎 Verifying: $chd_path"
            verify_output=$(chdman verify -i "$chd_path" 2>&1)
            verify_exit_code=$?
            echo "$verify_output" | verify_output_log INFO

            if [[ $verify_exit_code -ne 0 ]] || ! echo "$verify_output" | grep -qi "verification successful"; then
                failure_reasons=$(echo "$verify_output" | grep -iE 'error|fail|invalid|corrupt' || true)
                failures=$((failures + 1))
                log ERROR "❌ Verification failed on retry for: $chd_path — deleting"
                [[ -n "$failure_reasons" ]] && log DEBUG "   Failure details: $failure_reasons"
                rm -f "$chd_path"
                all_verified=false
                break
            else
                log INFO "✅ Verified on retry: $chd_path"
            fi
        else
            log INFO "✅ Verified CHD: $chd_path"
        fi
    done
    $all_verified && return 0 || return 1
}

validate_cue_file() {
    local cue_file="$1"
    local cuedir
    cuedir="$(dirname "$cue_file")"
    local cue_basename
    cue_basename="$(basename "$cue_file")"
    local missing=0

    declare -A file_map
    while IFS= read -r -d '' f; do
    file_map["${f,,}"]="$f"
    done < <(find "$cuedir" -maxdepth 1 -type f -printf '%f\0')

    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*FILE[[:space:]]+\"([^\"]+)\" ]]; then
            local ref="${BASH_REMATCH[1]}"
            local ref_norm="${ref//\\//}"
            local ref_basename; ref_basename="$(basename "$ref_norm")"
            local ref_lower="${ref_basename,,}"

            [[ "$ref_lower" == "${cue_basename,,}" ]] && continue

            if [[ "$ref_lower" == *.mp3 || "$ref_lower" == *.wav ]]; then
                log WARN "⚠️ CUE file references unsupported audio format: $ref_basename"
            fi
            if [[ "$ref_norm" == /* || "$ref_norm" == *".."* ]]; then
                log WARN "⚠️ Skipping unsafe external path in CUE: $ref_basename"
                continue
            fi
            if [[ -z "${file_map["$ref_lower"]:-}" ]]; then
                log ERROR "❌ Missing referenced file in CUE: $ref_basename (required by $cue_file)"
                missing=1
            fi
        fi
    done < "$cue_file"

    return $missing
}

detect_disc_type() {
    # Echo "cd" or "dvd" based on the image
    local img="$1"
    local ext="${img##*.}"
    ext="${ext,,}"

    # CUE/CCD/GDI are CD-type
    case "$ext" in
        cue|ccd|gdi) echo "cd"; return 0 ;;
    esac

    if [[ "$ext" == "iso" ]]; then
        # Prefer 'file' if available
        if command -v file >/dev/null 2>&1; then
            local sig
            sig="$(file -b -- "$img" 2>/dev/null || true)"
            if echo "$sig" | grep -qi 'UDF filesystem'; then
                echo "dvd"; return 0
            fi
        else
            # Fallback: sniff for UDF "NSR0[23]" anchor near sector 256
            local anchor_offset=$((256 * 2048))
            if dd if="$img" bs=1 skip="$anchor_offset" count=$((64 * 1024)) status=none 2>/dev/null \
                | grep -aqE 'NSR0(2|3)?'; then
                echo "dvd"; return 0
            fi
        fi

        # Size heuristic: ≥ ~1 GB → likely DVD; otherwise CD
        local sz
        sz=$(get_file_size "$img")
        if (( sz >= 1000000000 )); then
            echo "dvd"; return 0
        fi

        echo "cd"; return 0
    fi

    # Unknown extension → default to CD (safe for createcd)
    echo "cd"
}

convert_disc_file() {
    local file="$1"
    local outdir="$2"

    # If it's a CUE, validate referenced files first
    if [[ "${file,,}" == *.cue ]]; then
        if ! validate_cue_file "$file"; then
            log ERROR "❌ Missing referenced file in CUE: $file"
            return 1
        fi
    fi

    local base
    base="$(get_chd_basename "$file")"
    local chd_path="$outdir/$base.chd"
    local tmp_chd="$outdir/$base.chd.tmp"

    # If a CHD already exists, verify it and skip if good
    if [[ -f "$chd_path" ]]; then
        log INFO "🔎 Verifying existing CHD before conversion: $chd_path"
        if verify_chds "$outdir" "$base.chd"; then
            log INFO "✅ Existing CHD verified, skipping conversion: $chd_path"
            return 0
        else
            failures=$((failures + 1))
            log WARN "❌ Existing CHD verification failed, will convert and replace"
        fi
    fi

    # Decide CD vs DVD and pick subcommand + icon
    local disc_type
    disc_type="$(detect_disc_type "$file")"

    local subcmd icon
    if [[ "$disc_type" == "dvd" ]]; then
        if [[ "$CHDMAN_HAS_CREATEDVD" == true ]]; then
            subcmd="createdvd"
            icon="📀"  # DVD
        else
            log WARN "⚠️ Detected DVD image but this chdman lacks 'createdvd'. Skipping: $file"
            failures=$((failures + 1))
            return 1
        fi
    else
        subcmd="createcd"
        icon="💿"      # CD
    fi

    log INFO "$icon Detected $disc_type image → using chdman $subcmd"
    log INFO "🔧 Converting: $file -> $tmp_chd"
    if ! run_chdman_progress "$subcmd" -i "$file" -o "$tmp_chd"; then
        log ERROR "❌ chdman $subcmd failed for: $file"
    return 1
    fi

    return 0
}

process_input() {
    local input_file="$1"
    local ext="${input_file##*.}"; ext="${ext,,}"
    local outdir
    outdir="$(dirname "$input_file")"

    local archive_entries=()
    local disc_files=()
    local expected_chds=()
    local archive_size_bytes
    archive_size_bytes=$(get_file_size "$input_file")
    local ext_regex
    ext_regex="$(build_ext_regex "${disc_exts[@]}")"
    local temp_dir=""

    local _cleanup() {
        if [[ -n "$temp_dir" && -d "$temp_dir" ]]; then
            rm -rf "$temp_dir"
            log INFO "🧹 Cleaned up temp dir: $temp_dir"
        fi
    }
    trap _cleanup RETURN  # runs on any return/exit from this function

    if is_in_list "$ext" "${archive_exts[@]}"; then
        archives_processed=$((archives_processed + 1))
        case "$ext" in
            zip) mapfile -t archive_entries < <(unzip -Z1 "$input_file" | grep -Ei "$ext_regex") ;;
            rar) mapfile -t archive_entries < <(unrar lb "$input_file" | grep -Ei "$ext_regex") ;;
            7z|7zip) mapfile -t archive_entries < <(7z l -ba "$input_file" | grep -Ei "$ext_regex") ;;
        esac
        for entry in "${archive_entries[@]}"; do
            expected_chds+=("$(get_chd_basename "$entry").chd")
        done
    fi

    if is_in_list "$ext" "${disc_exts[@]}"; then
        disc_files+=("$input_file")
        expected_chds+=("$(get_chd_basename "$input_file").chd")
    fi

    if [[ ${#expected_chds[@]} -eq 0 ]]; then
        log WARN "⏭️ Skipping $input_file - no disc files found (not a supported archive or disc format)"
        return 0
    fi

    # If all expected CHDs already exist and verify, remove original and done
    if verify_chds "$outdir" "${expected_chds[@]}"; then
        log INFO "✅ All expected CHDs verified for $input_file"
        if [[ "$KEEP_ORIGINALS" != true ]]; then
            log INFO "🗑️ Removing original input file: $input_file"
            rm -f "$input_file"
        else
            log INFO "📦 Keeping original input file due to KEEP_ORIGINALS=true"
        fi
        # Per-iteration M3U generation for already-present sets
        if [[ ${#expected_chds[@]} -gt 0 ]]; then
            local chd_base
            chd_base="$(basename "${expected_chds[0]}" .chd)"
            log DEBUG "🔤 Raw base name: $chd_base"
            maybe_generate_m3u_for "$chd_base" "$outdir"
        fi
        return 0
    fi

    # Extract archive to temp and discover disc files
    if is_in_list "$ext" "${archive_exts[@]}"; then
        temp_dir="$(mktemp -d -t "chdconv_$(basename "$input_file" ".${ext}")_XXXX")"
        log INFO "📦 Extracting $input_file to $temp_dir"
        case "$ext" in
            zip) unzip -qq "$input_file" -d "$temp_dir" ;;
            rar) unrar x -o+ "$input_file" "$temp_dir" >/dev/null ;;
            7z|7zip) 7z x -y -o"$temp_dir" "$input_file" >/dev/null ;;
        esac

        read -r -a disc_find_expr <<< "$(build_find_expr "${disc_exts[@]}")"
        mapfile -d '' -t disc_files < <(find "$temp_dir" -type f \( "${disc_find_expr[@]}" \) -print0)

        if [[ ${#disc_files[@]} -eq 0 && ${#archive_entries[@]} -gt 0 ]]; then
            for entry in "${archive_entries[@]}"; do
                local full_path="$temp_dir/$entry"
                [[ -f "$full_path" ]] && disc_files+=("$full_path")
            done
        fi
    fi

    local archive_chd_size=0
    local tmp_chds=()

    for disc in "${disc_files[@]}"; do
        if convert_disc_file "$disc" "$outdir"; then
            tmp_chds+=("$outdir/$(basename "${disc%.*}").chd.tmp")
        else
            failures=$((failures + 1))
        fi
    done

    # Verify .tmp CHDs and finalize
    if [[ ${#tmp_chds[@]} -gt 0 ]]; then
        if verify_chds "$outdir" "${tmp_chds[@]##*/}"; then
            for tmp_chd in "${tmp_chds[@]}"; do
                local final_chd="${tmp_chd%.tmp}"
                mv -f "$tmp_chd" "$final_chd"
                log INFO "🔄 Replaced old CHD with new verified CHD: $final_chd"
                chds_created=$((chds_created + 1))
            done

            if [[ "$KEEP_ORIGINALS" != true ]]; then
                log INFO "🗑️ Removing original input file: $input_file"
                rm -f "$input_file"
            else
                log INFO "📦 Keeping original input file due to KEEP_ORIGINALS=true"
            fi

            for chd in "${expected_chds[@]}"; do
                if [[ -f "$outdir/$chd" ]]; then
                    archive_chd_size=$((archive_chd_size + $(get_file_size "$outdir/$chd")))
                fi
            done
            if [[ $archive_size_bytes -gt 0 ]]; then
                local saving=$((archive_size_bytes - archive_chd_size))
                local saving_percent=$((100 * saving / archive_size_bytes))
                log INFO "📉 Space saving for $(basename "$input_file"): $(human_readable "$archive_size_bytes") → $(human_readable "$archive_chd_size"), saved $(human_readable "$saving") (${saving_percent}%)"
                total_original_size=$((total_original_size + archive_size_bytes))
                total_chd_size=$((total_chd_size + archive_chd_size))
            fi
        else
            for tmp_chd in "${tmp_chds[@]}"; do
                if [[ -f "$tmp_chd" ]]; then
                    rm -f "$tmp_chd"
                    log INFO "🗑️ Removed failed tmp CHD: $tmp_chd"
                fi
            done
            failures=$((failures + 1))
            log WARN "⚠️ CHD verification failed after conversion for $input_file, keeping original"
        fi
    fi

    # Per-iteration M3U generation for newly written CHDs
    if [[ ${#expected_chds[@]} -gt 0 ]]; then
        local chd_base
        chd_base="$(basename "${expected_chds[0]}" .chd)"
        log DEBUG "🔤 Raw base name: $chd_base"
        maybe_generate_m3u_for "$chd_base" "$outdir"
    fi

    # Per-iteration temp cleanup
    if [[ -n "$temp_dir" && -d "$temp_dir" ]]; then
        rm -rf "$temp_dir"
        log INFO "🧹 Cleaned up temp dir: $temp_dir"
    fi

    return 0
}

# Main processing loop
read -r -a find_expr <<< "$(build_find_expr "${all_exts[@]}")"

if [[ -z "${find_expr[*]:-}" ]]; then
    log ERROR "⚠️ No valid file extensions found for searching, exiting."
    exit 1
fi

if [[ "$RECURSIVE" == true ]]; then
    mapfile -d '' -t all_inputs < <(
        find "$INPUT_DIR" \( -path '*/.*' -prune \) -o -type f \( "${find_expr[@]}" \) -print0
    )
else
    mapfile -d '' -t all_inputs < <(
        find "$INPUT_DIR" -maxdepth 1 -type f \( "${find_expr[@]}" \) -print0
    )
fi
log INFO "🔎 Found ${#all_inputs[@]} inputs"

for input in "${all_inputs[@]}"; do
    log INFO "▶️ Processing file: $input"
    if ! process_input "$input"; then
        log ERROR "⚠️ Failed to process $input"
    fi
done

log INFO "📊 Summary:"
if [[ $total_original_size -gt 0 ]]; then
    total_saved=$((total_original_size - total_chd_size))
    total_percent=$((100 * total_saved / total_original_size))
    log INFO "📦 Total original size: $(human_readable "$total_original_size")"
    log INFO "💿 Total CHD size: $(human_readable "$total_chd_size")"
    log INFO "📉 Total space saved: $(human_readable "$total_saved") (${total_percent}%)"
fi
log INFO "📦 Archives processed: $archives_processed"
log INFO "💿 CHDs created:       $chds_created"
log INFO "❌ Failures:           $failures"
log INFO "⏱️ Elapsed time: $(format_duration $(( $(date +%s) - script_start_time )))"
log INFO "✅ Done!"
