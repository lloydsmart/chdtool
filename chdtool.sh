#!/usr/bin/env bash

set -Eeuo pipefail
set +H
script_start_time=$(date +%s)
shopt -s nullglob
shopt -s extglob

CHDTOOL_VERSION="0.3.0"
PROGRAM_NAME="$(basename -- "$0")"
USAGE="Usage: $PROGRAM_NAME [options] [--] <input directory>"

print_usage() {
  cat <<EOF
$USAGE

Options:
  -k, --keep-originals              Do not delete source files
  -r, --recursive                   Scan subdirectories
  -n, --dry-run                     Preview operations without changing inputs
  -a, --allow-unverified-cue-audio  Allow lossy/unverified CUE audio tracks
  -F, --file-tee                    Enable file mirroring
  -N, --no-file-tee                 Disable file mirroring
  -h, --help                        Show this help and exit
  -V, --version                     Show the version and exit
EOF
}
KEEP_ORIGINALS=false
RECURSIVE=false
DRY_RUN=false
ALLOW_UNVERIFIED_CUE_AUDIO=false
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
        --dry-run|-n)
            DRY_RUN=true; shift ;;
        --allow-unverified-cue-audio|-a)
            ALLOW_UNVERIFIED_CUE_AUDIO=true; shift ;;
        --file-tee|-F)
            LOG_TEE_FILE=1; shift ;;
        --no-file-tee|-N)
            LOG_TEE_FILE=0; shift ;;
        --help|-h)
            print_usage; exit 0 ;;
        --version|-V)
            printf '%s %s\n' "$PROGRAM_NAME" "$CHDTOOL_VERSION"; exit 0 ;;
        --)
            shift
            if [[ -n "$INPUT_DIR" || $# -ne 1 ]]; then
                echo "❌ Expected exactly one input directory after --" >&2
                echo "$USAGE" >&2; exit 1
            fi
            INPUT_DIR="${1%/}"
            shift
            break ;;
        -*)
            echo "❌ Unknown option: $1" >&2
            echo "$USAGE" >&2; exit 1 ;;
        *)
            if [[ -z "$INPUT_DIR" ]]; then
                INPUT_DIR="${1%/}" # Remove trailing slash
            else
                echo "❌ Unexpected extra argument: $1" >&2
                echo "$USAGE" >&2; exit 1
            fi
            shift ;;
    esac
done

if [[ -z "$INPUT_DIR" ]]; then
  echo "$USAGE" >&2; exit 1
fi
[[ "$INPUT_DIR" == -* ]] && INPUT_DIR="./$INPUT_DIR"
if [[ ! -d "$INPUT_DIR" ]]; then
  echo "❌ Input directory does not exist or is not a directory: $INPUT_DIR" >&2
  exit 1
fi

# Use a disk-based temp directory to avoid filling up RAM
TMP_ROOT="${TMPDIR:-/var/tmp/chdtool}"
TMPDIR="$TMP_ROOT/$RUN_ID"
[[ "$DRY_RUN" == true ]] || mkdir -p "$TMPDIR"

LOGFILE="${LOGFILE:-logs/chd_conversion_$(date +%Y%m%d_%H%M%S).log}"

# --- Pluggable logging: console/file/syslog/journald (auto) -------------------
# Control via env vars (no root needed to write to journald/syslog):
#   LOG_DEST=auto|console|file|syslog|journald
#   LOGFILE=/path/to/file   (used when LOG_DEST=file; defaults to ./logs/…)
#   LOG_TAG=chdtool
LOG_DEST="${LOG_DEST:-auto}"
LOG_TAG="${LOG_TAG:-chdtool}"

# Mirror policy: auto (TTY only), 1 (always), 0 (never)
LOG_TEE_CONSOLE="${LOG_TEE_CONSOLE:-auto}"

# New: mirror-to-file policy for journald/syslog backends.
# 1|true|yes (default) → also append to $LOGFILE
# 0|false|no           → do not write a file when using journald/syslog
LOG_TEE_FILE="${LOG_TEE_FILE:-1}"

__should_mirror_file() {
  case "${LOG_TEE_FILE}" in
    1|true|yes) return 0 ;;
    0|false|no) return 1 ;;
    *) return 0 ;; # default to on
  esac
}

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

# ensure the logfile directory exists when we might write to it
if [[ "$LOG_BACKEND" == file ]] || __should_mirror_file; then
  mkdir -p -- "$(dirname -- "$LOGFILE")"
fi

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
        # Also append to file if enabled
        if __should_mirror_file; then
            while IFS= read -r line; do
            printf '[%s] %s: %s\n' "$ts" "$lvl" "$line" >> "$LOGFILE"
            done <<< "$msg"
        fi
        __should_mirror_console && __console_print "$ts" "$lvl" "$msg"
        ;;
        syslog)
        while IFS= read -r line; do
            logger -p "user.$pri" -t "$LOG_TAG" -- "$lvl: $line"
        done <<< "$msg"
        # Also append to file if enabled
        if __should_mirror_file; then
            while IFS= read -r line; do
            printf '[%s] %s: %s\n' "$ts" "$lvl" "$line" >> "$LOGFILE"
            done <<< "$msg"
        fi
        __should_mirror_console && __console_print "$ts" "$lvl" "$msg"
        ;;
        file)
        while IFS= read -r line; do
            printf '[%s] %s: %s\n' "$ts" "$lvl" "$line" >> "$LOGFILE"
        done <<< "$msg"
        __should_mirror_console && __console_print "$ts" "$lvl" "$msg"
        ;;
        console|*)
        if __should_mirror_file; then
            while IFS= read -r line; do
                printf '[%s] %s: %s\n' "$ts" "$lvl" "$line" | tee -a "$LOGFILE"
            done <<< "$msg"
        else
            __console_print "$ts" "$lvl" "$msg"
        fi
        ;;
    esac

    # Optional mirrors may legitimately be disabled. Logging still succeeded
    # when the selected backend accepted the message.
    return 0
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

log DEBUG "📁 Using temp workspace: $TMPDIR"
log INFO "🚀 Script started, input dir: $INPUT_DIR"
[[ "$RECURSIVE" == true ]] && log INFO "📂 Recursive mode enabled — scanning subdirectories"
[[ "$DRY_RUN" == true ]] && log INFO "🧪 Dry-run mode: no files will be written, moved, or deleted"
[[ "$ALLOW_UNVERIFIED_CUE_AUDIO" == true ]] && log WARN "⚠️ Allowing unverified/lossy CUE audio tracks — conversion may succeed from non-preservation-grade sources"

is_in_list() {
  local needle="$1"; shift
  local x
  for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
  return 1
}

required_commands=(chdman unzip unrar 7z stat awk stdbuf)
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
        if [[ "$DRY_RUN" == true ]]; then
            log WARN "🧪 (dry-run) '$cmd' not found — would be required for a real run"
        else
            log ERROR "❌ Error: Required command '$cmd' not found. Please install it and ensure it's in your PATH."
            exit 1
        fi
    fi
done

if command -v chdman >/dev/null 2>&1; then
    chdman_version="$(chdman --help 2>&1 | head -n 1 || true)"
    log INFO "ℹ️ Using $chdman_version"
else
    if [[ "$DRY_RUN" == true ]]; then
        log WARN "🧪 (dry-run) 'chdman' not found — would be required for a real run"
    else
        log ERROR "❌ 'chdman' not found in PATH"
        exit 1
    fi
fi

# Detect 'createdvd' capability (newer chdman versions)
CHDMAN_HAS_CREATEDVD=false
if command -v chdman >/dev/null 2>&1; then
    if chdman help createdvd >/dev/null 2>&1; then
        CHDMAN_HAS_CREATEDVD=true
        log DEBUG "ℹ️ chdman createdvd support: true (via 'chdman help createdvd')"
    else
        CHDMAN_HAS_CREATEDVD=false
        log DEBUG "ℹ️ chdman createdvd support: false (no 'createdvd' help topic)"
    fi
else
    [[ "$DRY_RUN" == true ]] && log DEBUG "ℹ️ chdman not present (dry-run); assuming no createdvd"
fi

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

check_temp_storage() {
    local tmp_dir="$1"
    local fs_type
    fs_type=$(df -T "$tmp_dir" | awk 'NR==2 {print $2}')

    if [[ "$fs_type" == "tmpfs" ]]; then
        local tmp_limit
        tmp_limit=$(df -h "$tmp_dir" | awk 'NR==2 {print $4}')
        log WARN "⚠️ $tmp_dir is a RAM disk (tmpfs). Extracted ISOs will consume physical RAM!"
        log WARN "💡 Available space in RAM disk: $tmp_limit"

    fi
}

archive_entry_to_chd_name() {
  # $1 = path inside archive, e.g. "CD1/Game.cue"
  local entry="$1"
  local stem="${entry%.*}"
  # preserve subdir info to avoid collisions, but keep it filename-safe
  stem="${stem//\// - }"
  stem="$(sanitize_filename "$stem")"
  printf '%s.chd' "$stem"
}

select_preferred_disc_candidates() {
    local candidates=("$@")
    local -a cues=() gdis=() ccds=() isos=()
    local candidate ext

    for candidate in "${candidates[@]}"; do
        ext="${candidate##*.}"
        ext="${ext,,}"
        case "$ext" in
            cue) cues+=("$candidate") ;;
            gdi) gdis+=("$candidate") ;;
            ccd) ccds+=("$candidate") ;;
            iso) isos+=("$candidate") ;;
        esac
    done

    if (( ${#cues[@]} > 0 )); then
        printf '%s\n' "${cues[@]}"
    elif (( ${#gdis[@]} > 0 )); then
        printf '%s\n' "${gdis[@]}"
    elif (( ${#ccds[@]} > 0 )); then
        printf '%s\n' "${ccds[@]}"
    else
        printf '%s\n' "${isos[@]}"
    fi
}

is_safe_relative_path() {
    local path="${1//\\//}"
    [[ -n "$path" && "$path" != /* && ! "$path" =~ ^[[:alpha:]]: && "$path" != //* ]] || return 1
    local part
    IFS='/' read -r -a _path_parts <<< "$path"
    for part in "${_path_parts[@]}"; do
        [[ "$part" != ".." ]] || return 1
    done
}

# Resolve each path component independently. This preserves safe subdirectories,
# permits case-insensitive media layouts, and rejects ambiguous case-fold matches.
resolve_descriptor_reference() {
    local base_dir="$1" ref="${2//\\//}" current="$1" part match
    is_safe_relative_path "$ref" || return 1
    IFS='/' read -r -a _ref_parts <<< "$ref"
    for part in "${_ref_parts[@]}"; do
        [[ -n "$part" && "$part" != "." ]] || continue
        if [[ -e "$current/$part" ]]; then
            current="$current/$part"
            continue
        fi
        local -a matches=()
        while IFS= read -r -d '' match; do matches+=("$match"); done < <(
            find "$current" -mindepth 1 -maxdepth 1 -iname "$part" -print0 2>/dev/null
        )
        (( ${#matches[@]} == 1 )) || return 1
        current="${matches[0]}"
    done
    [[ -f "$current" ]] || return 1
    printf '%s\n' "$current"
}

DESCRIPTOR_SOURCE_SET=()

validate_descriptor_file() {
    local descriptor="$1" ext="${1##*.}" base_dir stem line ref resolved
    ext="${ext,,}"
    base_dir="$(dirname "$descriptor")"
    stem="${descriptor%.*}"
    DESCRIPTOR_SOURCE_SET=("$descriptor")

    case "$ext" in
        cue)
            local unsupported_audio=0
            while IFS= read -r line; do
                if [[ "$line" =~ ^[[:space:]]*FILE[[:space:]]+\"([^\"]+)\" ]]; then
                    ref="${BASH_REMATCH[1]}"
                    if ! is_safe_relative_path "$ref"; then
                        log ERROR "❌ Unsafe path in CUE: $ref (required by $descriptor)"
                        return 1
                    fi
                    if ! resolved="$(resolve_descriptor_reference "$base_dir" "$ref")"; then
                        log ERROR "❌ Missing or ambiguous referenced file in CUE: $ref (required by $descriptor)"
                        return 1
                    fi
                    DESCRIPTOR_SOURCE_SET+=("$resolved")
                    case "${ref,,}" in
                        *.mp3|*.ogg|*.opus|*.m4a|*.flac)
                            if [[ "$ALLOW_UNVERIFIED_CUE_AUDIO" != true ]]; then
                                log ERROR "❌ CUE references unsupported audio format: $ref"
                                unsupported_audio=1
                            fi ;;
                    esac
                fi
            done < "$descriptor"
            (( unsupported_audio == 0 )) || return 1
            ;;
        gdi)
            local track_count=0
            while IFS= read -r line; do
                [[ "$line" =~ ^[[:space:]]*[0-9]+[[:space:]] ]] || continue
                # GDI track filenames are the fifth field; quoted names may contain spaces.
                ref="$(awk 'match($0,/^([^[:space:]]+[[:space:]]+){4}("[^"]+"|[^[:space:]]+)/){v=substr($0,RSTART,RLENGTH); sub(/^([^[:space:]]+[[:space:]]+){4}/,"",v); gsub(/^"|"$/,"",v); print v}' <<< "$line")"
                [[ -n "$ref" ]] || { log ERROR "❌ Invalid GDI track entry: $line"; return 1; }
                is_safe_relative_path "$ref" || { log ERROR "❌ Unsafe path in GDI: $ref"; return 1; }
                resolved="$(resolve_descriptor_reference "$base_dir" "$ref")" || { log ERROR "❌ Missing or ambiguous GDI track: $ref"; return 1; }
                DESCRIPTOR_SOURCE_SET+=("$resolved"); track_count=$((track_count + 1))
            done < "$descriptor"
            (( track_count > 0 )) || { log ERROR "❌ GDI contains no valid track entries: $descriptor"; return 1; }
            ;;
        ccd)
            local companion
            for companion in img sub; do
                ref="$(basename "$stem").$companion"
                resolved="$(resolve_descriptor_reference "$base_dir" "$ref")" || { log ERROR "❌ Missing CCD companion file: $ref"; return 1; }
                DESCRIPTOR_SOURCE_SET+=("$resolved")
            done
            ;;
        *) return 0 ;;
    esac
    log DEBUG "✅ Descriptor source-set validation passed: $descriptor"
}

validate_archive_member_paths() {
    local member normalized part
    for member in "$@"; do
        normalized="${member//\\//}"
        [[ "$normalized" == */ ]] && normalized="${normalized%/}"
        [[ -z "$normalized" ]] && continue
        if ! is_safe_relative_path "$normalized"; then
            log ERROR "❌ Unsafe archive member path: $member"
            return 1
        fi
    done
}

validate_archive_output_names() {
    declare -A seen=()
    local entry output key
    for entry in "$@"; do
        output="$(archive_entry_to_chd_name "$entry")"
        key="${output,,}"
        if [[ -n "${seen[$key]:-}" ]]; then
            log ERROR "❌ Archive entries collide after output-name sanitisation: ${seen[$key]} and $entry -> $output"
            return 1
        fi
        seen["$key"]="$entry"
    done
}

validate_extracted_tree() {
    local root="$1" link target
    while IFS= read -r -d '' link; do
        target="$(readlink -- "$link" 2>/dev/null || true)"
        log ERROR "❌ Unsafe archive link rejected: ${link#"$root/"} -> $target"
        return 1
    done < <(find "$root" -type l -print0)
}

[[ "$DRY_RUN" == true ]] || check_temp_storage "$TMPDIR"

# ---------- chdman progress handling ----------
# Config: PROGRESS_STYLE=auto|bar|line|none ; default: auto (TTY -> bar, non-TTY -> none)
PROGRESS_STYLE_DEFAULT="auto"
PROGRESS_THROTTLE_MS=250   # reduce flicker
PROGRESS_MARGIN=28         # spare columns to avoid wrap (emoji-width safety)

# Print N copies of a char
_repeat_char() { local n=$1 c=$2 out=""; while (( n-- > 0 )); do out+="$c"; done; printf "%s" "$out"; }

# Draw a single-line status (bar or line) to stderr, staying on one row.
PROGRESS_BAR_MAX=${PROGRESS_BAR_MAX:-40}

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

# Generic chdman progress filter
# Use with: PHASE_DEFAULT="Converting" chdman createcd … | _chdman_progress_filter
#        or: PHASE_DEFAULT="Verifying"  chdman verify … | _chdman_progress_filter
_chdman_progress_filter() {
    # Invoked indirectly by the traps below.
    # shellcheck disable=SC2317
    _restore_wrap() { _term_print "\033[?7h"; }
    trap '_restore_wrap; return 130' INT TERM
    trap _restore_wrap EXIT

    local last_draw=0 phase="${PHASE_DEFAULT:-Compressing}" ratio="" progress_active=0 ms

    # Read from a process-substitution so the while-loop stays in THIS shell
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

        if [[ "$line" =~ ^[[:space:]]*([A-Za-z]+,)?[[:space:]]*$ ]] || \
           [[ "$line" =~ ^[[:space:]]*[0-9]+([.][0-9]+)?[[:space:]]*$ ]]; then
            continue
        fi

        log "$CHDMAN_MSG_LEVEL" "$line"
    done < <(tr $'\r' $'\n' <&0)   # CR → NL normalisation happens here

    (( progress_active )) && _term_print "\r\033[2K\n"
}

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
    # ERE (bash) has no (?: ). Keep groups simple and predictable.
    local re_disc_labels='([Dd]isc|[Cc][Dd]|[Dd]isk|[Gg][Dd]|[Gg][Dd]-[Rr][Oo][Mm])'
    local re_num='([0-9]{1,3})'
    local re_sep='[[:space:]]*[-_.]?[[:space:]]*'
    # For the compact/union pattern, keep it a single capturing group:
    local re_label_union="(${re_disc_labels:1:-1}|[Vv]ol|[Vv]olume|[Pp]art|[Pp]t\\.?)"

    if [[ "$name_norm" =~ ^(.*?)[[:space:]._-]*\(?$re_disc_labels$re_sep$re_num\)?([[:space:]]*.*)?$ ]]; then
        local base="${BASH_REMATCH[1]}"
        local num="${BASH_REMATCH[3]}"   # (1=label,2=sep? depends on grouping; ensure index)
        # Because of our grouping above, indexes are:
        # 1=prefix, 2=label, 3=number, 4=tail
        base="$(tidy_base "$base")"
        [[ -n "$base" && -n "$num" ]] && { echo "$base|$num"; return 0; }
    fi

    # Pattern set 2: Vol/Volume, Part/Pt
    if [[ "$name_norm" =~ ^(.*?)[[:space:]._-]*\(?([Vv]ol|[Vv]olume|[Pp]art|[Pp]t\.?)$re_sep$re_num\)?([[:space:]]*.*)?$ ]]; then
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
    if [[ "$name_norm" =~ ^(.*?)[[:space:]._-]*\(?([0-9]+)[[:space:]]*([Oo][Ff]|/)[[:space:]]*[0-9]+\)?([[:space:]]*.*)?$ ]]; then
        local base="${BASH_REMATCH[1]}"
        local num="${BASH_REMATCH[2]}"
        base="$(tidy_base "$base")"
        [[ -n "$base" && -n "$num" ]] && { echo "$base|$num"; return 0; }
    fi

    # Pattern set 5: compact forms WITHOUT spaces/brackets:
    # "Title Disc02", "Title CD2", "Title Vol.2", "Title Pt.3"
    if [[ "$name_norm" =~ ^(.*?)[[:space:]._-]*$re_label_union$re_sep$re_num([[:space:]]*.*)?$ ]]; then
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
        done | LC_ALL=C sort -t'|' -k1,1n | cut -d'|' -f2
    )"
    mapfile -t members <<< "$sorted"

    # Write idempotently (relative file names in body)
    # inside generate_m3u_for_base, after computing safe_base
    local safe_base; safe_base="$(sanitize_filename "$base")"
    local legacy_path="$outdir/${base}.m3u"
    local m3u_path="$outdir/${safe_base}.m3u"

    # migrate legacy → sanitized (only if sanitized doesn't exist yet)
    if [[ -f "$legacy_path" && ! -f "$m3u_path" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            log INFO "🧪 (dry-run) Would rename legacy M3U → sanitized: $(basename "$legacy_path") → $(basename "$m3u_path")"
        else
            mv -f -- "$legacy_path" "$m3u_path"
            log INFO "🧹 Renamed legacy M3U → sanitized: $(basename "$legacy_path") → $(basename "$m3u_path")"
        fi
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log INFO "🧪 (dry-run) Would (re)write M3U: $m3u_path with ${#members[@]} lines"
    else
        local tmp_m3u="$m3u_path.tmp"
        track_temp_file "$tmp_m3u"
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
            mv -f -- "$tmp_m3u" "$m3u_path"
            if [[ "$_m3u_existed" == true ]]; then
                log INFO "📝 Updated M3U: $m3u_path"
            else
                log INFO "🆕 Created M3U: $m3u_path"
            fi
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

    if [[ "$DRY_RUN" == true ]]; then
        log INFO "🧪 (dry-run) Would generate/update M3U for base: $base"
    else
        generate_m3u_for_base "$outdir" "$base"
    fi
}
# ---------- end M3U helpers ----------
# --- Global interrupt + cleanup handling --------------------------------------
# Track temp dirs created during processing so we can clean them on SIGINT/TERM
declare -a TEMP_DIRS=()
declare -a TEMP_FILES=()

track_temp_dir()  { TEMP_DIRS+=("$1"); }
track_temp_file() { TEMP_FILES+=("$1"); }

untrack_temp_file() {
  local f="$1" i
  for i in "${!TEMP_FILES[@]}"; do
    [[ "${TEMP_FILES[$i]}" == "$f" ]] && unset 'TEMP_FILES[$i]'
  done
}

cleanup_temp_file_now() {
  local f="$1"
  if [[ -n "$f" && -f "$f" ]]; then
    rm -f -- "$f"
    log INFO "🗑️ Removed temp file: $f"
  fi
  untrack_temp_file "$f"
}

cleanup_temp_dir_now() {
  local d="$1"
  [[ -n "$d" && -d "$d" ]] || return 0
  rm -rf -- "$d"
  log INFO "🧹 Cleaned up temp dir: $d"
  # remove it from TEMP_DIRS so cleanup_all won't log it again
  local i
  for i in "${!TEMP_DIRS[@]}"; do
    [[ "${TEMP_DIRS[$i]}" == "$d" ]] && unset 'TEMP_DIRS[$i]'
  done
}

# Invoked indirectly through _on_interrupt's signal trap.
# shellcheck disable=SC2317
_restore_wrap_global() {
  # Make sure terminal autowrap is re-enabled and the progress line cleared
  # (safe to emit even if no progress was showing)
  _term_print "\r\033[2K\033[?7h\n"
}

# Invoked indirectly by the EXIT trap and the signal handler.
# shellcheck disable=SC2317
cleanup_all() {
    # Temp dirs
    for d in "${TEMP_DIRS[@]:-}"; do
        [[ -n "$d" && -d "$d" ]] || continue
        rm -rf -- "$d"
        log INFO "🧹 Cleaned up temp dir: $d"
    done

    # Temp files
    for f in "${TEMP_FILES[@]:-}"; do
        [[ -n "$f" && -f "$f" ]] || continue
        rm -f -- "$f"
        log INFO "🗑️ Removed temp file: $f"
    done
}

# Invoked indirectly by the INT and TERM traps.
# shellcheck disable=SC2317
_on_interrupt() {
  # One place to handle Ctrl-C/TERM: restore terminal, clean, then exit(130)
  _restore_wrap_global
  log WARN "🛑 Interrupted — cleaning up and exiting…"
  trap - EXIT
  cleanup_all
  exit 130
}

# Ctrl-C (INT) and TERM should both stop the whole script
trap _on_interrupt INT TERM
trap cleanup_all EXIT

verify_chds() {
    local outdir="$1"; shift
    local chds=("$@")
    local all_verified=true

    if [[ "$DRY_RUN" == true ]]; then
        for chd in "${chds[@]}"; do
            [[ -n "$outdir" ]] && chd="$outdir/$chd"
            log INFO "🧪 (dry-run) Would verify: $chd"
        done
        return 0
    fi

    for chd in "${chds[@]}"; do
        local chd_path="$chd"
        [[ -n "$outdir" ]] && chd_path="$outdir/$chd"
        if [[ ! -f "$chd_path" ]]; then
            all_verified=false
            break
        fi

        local verify_exit_code=0
        local tmpout
        tmpout="$(mktemp -p "$TMPDIR" chdverify_XXXXXX)"
        track_temp_file "$tmpout"

        log INFO "🔎 Verifying: $chd_path"
        if [[ -t 2 && "${PROGRESS_STYLE:-$PROGRESS_STYLE_DEFAULT}" != "none" ]]; then
            # TTY: show single-line progress, capture full output to tmp for analysis
            if PHASE_DEFAULT="Verifying" stdbuf -oL -eL "${CHDMAN_BIN:-chdman}" verify -i "$chd_path" 2>&1 \
                | tee "$tmpout" \
                | _chdman_progress_filter
            then
                verify_exit_code=0
            else
                verify_exit_code=$?
            fi
        else
            # Non-TTY: no progress UI, still capture output
            if "${CHDMAN_BIN:-chdman}" verify -i "$chd_path" 2>&1 | tee "$tmpout" >/dev/null
            then
                verify_exit_code=0
            else
                verify_exit_code=$?
            fi
        fi

        if [[ $verify_exit_code -ne 0 ]]; then
            # Summarize failure reasons (quietly)
            local failure_reasons
            failure_reasons="$(grep -iE 'error|fail|invalid|corrupt' "$tmpout" || true)"
            [[ -n "$failure_reasons" ]] && log DEBUG "   Failure details: $failure_reasons"

            log WARN "⚠️ Verification failed on first try for: $chd_path"
            log INFO "⏳ Retrying after delay..."
            sleep 2

            # Retry with a fresh capture file
            : > "$tmpout"
            log INFO "🔎 Verifying: $chd_path"
            if [[ -t 2 && "${PROGRESS_STYLE:-$PROGRESS_STYLE_DEFAULT}" != "none" ]]; then
                if PHASE_DEFAULT="Verifying" stdbuf -oL -eL "${CHDMAN_BIN:-chdman}" verify -i "$chd_path" 2>&1 \
                    | tee "$tmpout" \
                    | _chdman_progress_filter
                then
                    log INFO "✅ Verified on retry: $chd_path"
                    rm -f -- "$tmpout"
                    continue
                fi
            else
                if "${CHDMAN_BIN:-chdman}" verify -i "$chd_path" 2>&1 | tee "$tmpout" >/dev/null
                then
                    log INFO "✅ Verified on retry: $chd_path"
                    rm -f -- "$tmpout"
                    continue
                fi
            fi

            # Still failed: log concise reasons and clean up
            failure_reasons="$(grep -iE 'error|fail|invalid|corrupt' "$tmpout" || true)"
            [[ -n "$failure_reasons" ]] && log DEBUG "   Failure details: $failure_reasons"
            log ERROR "❌ Verification failed on retry for: $chd_path — deleting"
            rm -f -- "$chd_path"
            rm -f -- "$tmpout"
            all_verified=false
            break
        else
            log INFO "✅ Verified CHD: $chd_path"
            rm -f -- "$tmpout"
        fi
    done

    $all_verified && return 0 || return 1
}

detect_disc_type() {
    log DEBUG "DEBUG: Starting detection for: $1"
    local img="$1"
    local ext
    ext="${img##*.}"; ext="${ext,,}"
    local sz
    sz=$(get_file_size "$img" 2>/dev/null || echo 0)
    # --- DEBUGGING ---
    log DEBUG "sz value for $(basename "$img"): [${sz}]"
    # -----------------

    #1. Size-based "hard limits"
    # If it's > 1GB, it's a DVD/PS2 regardless of what the header says (some PS2 games have weird headers that look like CDs)
    local is_large_disc=false
    (( sz >= 1000000000 )) && is_large_disc=true
    # --- DEBUGGING ---
    log DEBUG "is_large_disc for $(basename "$img"): $is_large_disc (size: $sz bytes)"
    # -----------------

    # Sniff the header before checking extensions
    local sniff_target="$img"
    if [[ "$ext" == "cue" ]]; then
        local cue_dir
        cue_dir="$(dirname "$img")"

        # Prefer a likely DATA file (BIN/ISO/IMG/MDF) over audio tracks.
        local raw_ref=""
        raw_ref="$(
            awk -F'"' '
                BEGIN { IGNORECASE=1 }
                /^[[:space:]]*FILE[[:space:]]+"/ {
                    ref=$2
                    low=tolower(ref)
                    gsub(/\\/, "/", low)
                    # pick first "data-ish" file
                    if (low ~ /\.(bin|iso|img|mdf)$/) { print ref; selected=1; exit }
                    # otherwise remember first FILE as fallback
                    if (first == "") first = ref
                }
                END { if (!selected && first != "") print first }
            ' "$img"
        )"

        # Normalize Windows path separators
        raw_ref="${raw_ref//\\//}"

        local sniff_candidate=""
        sniff_candidate="$(resolve_descriptor_reference "$cue_dir" "$raw_ref" 2>/dev/null || true)"

        log DEBUG "DEBUG: CUE selected sniff candidate: [$raw_ref]"
        log DEBUG "DEBUG: Full resolved sniff path:     [$sniff_candidate]"

        if [[ -n "$raw_ref" && -f "$sniff_candidate" ]]; then
            log DEBUG "DEBUG: Found referenced file. Switching sniff_target."
            sniff_target="$sniff_candidate"
        else
            log DEBUG "DEBUG: FAILED to resolve referenced file from CUE."
            log DEBUG "DEBUG: Directory contents of $cue_dir: $(ls -m "$cue_dir")"
        fi
    fi

    #2. Console Fingerprinting
    # Reading the first 64KB covers Volume Descriptors and Boot Headers
    local header
    header="$(head -c 65535 -- "$sniff_target" 2>/dev/null | tr -d '\0' || true)"

    # Check for PS2 specifically in debug
    if [[ "$header" == *"PLAYSTATION 2"* ]]; then
        log DEBUG "DEBUG: 'PLAYSTATION 2' string found in header of $(basename "$sniff_target")"
    fi
    # ------------------------------------------

    case "$header" in
        *"PLAYSTATION 2"*|*"NTSC-U/C PS2 DVD"*) echo "ps2"; return 0 ;;
        *"PLAYSTATION  "*|*"NTSC-U/C PS1 CD"*)
            # If it says PS1 but it's >1GB, it's a mislabeled PS2 DVD
            if [[ "$is_large_disc" == true ]]; then
                log WARN "⚠️ Header indicates PS1 but size suggests PS2 DVD. Treating as PS2: $img"
                echo "ps2"
            else
                echo "ps1"
            fi
            return 0 ;;
        *"SEGA MEGA-CD"*) echo "segacd"; return 0 ;;
        *"SEGA SEGAKATANA"*) echo "dreamcast"; return 0 ;;
        *"SEGA SEGASATURN"*) echo "saturn"; return 0 ;;
        *"PSP GAME"*|*"UMD VIDEO"*) echo "psp"; return 0 ;;
    esac

    #3. Immediate CD extensions - CUE/CCD/GDI are CD-type by definition
    case "$ext" in
        cue|ccd|gdi) echo "cd"; return 0 ;;
    esac

    #4. UDF/ISO logic fallback
    if [[ "$ext" == "iso" ]]; then
        if command -v file >/dev/null 2>&1; then
            local sig
            sig="$(file -b -- "$img" 2>/dev/null || true)"
            [[ "$sig" == *"UDF filesystem"* ]] && { echo "dvd"; return 0; }
        else
            if dd if="$img" bs=2048 skip=256 count=32 status=none 2>/dev/null \
                | tr -d '\0' | grep -qE 'NSR0(2|3)?'; then
                echo "dvd"; return 0
            fi
        fi

        # Size heuristic: ≥ ~1 GB → likely DVD; otherwise CD
        [[ "$is_large_disc" == true ]] && { echo "dvd"; return 0; }
    fi

    #5 Final fallback: Unknown extension → default to CD (safe for createcd)
    [[ "$is_large_disc" == true ]] && echo "dvd" || echo "cd"
}

convert_disc_file() {
    local file="$1"
    local outdir="$2"
    local base_override="${3:-}"
    local result_var="${4:-}"

    [[ -n "$result_var" ]] && printf -v "$result_var" '%s' ""

    local file_ext="${file##*.}"; file_ext="${file_ext,,}"
    if [[ "$file_ext" == "cue" || "$file_ext" == "gdi" || "$file_ext" == "ccd" ]]; then
        if ! validate_descriptor_file "$file"; then
            log ERROR "❌ Descriptor validation failed: $file"
            return 1
        fi
    fi

    local base
    if [[ -n "$base_override" ]]; then
        base="$base_override"
    else
        base="$(get_chd_basename "$file")"
    fi

    local chd_path="$outdir/$base.chd"

    # If a CHD already exists, verify it and skip if good
    if [[ -f "$chd_path" ]]; then
        log INFO "🔎 Verifying existing CHD before conversion: $chd_path"
        if verify_chds "$outdir" "$base.chd"; then
            log INFO "✅ Existing CHD verified, skipping conversion: $chd_path"
            return 0
        else
            log WARN "❌ Existing CHD verification failed, will convert and replace"
        fi
    fi

    # Decide CD vs DVD and pick subcommand + icon
    local disc_type
    disc_type="$(detect_disc_type "$file")"
    local subcmd icon
    case "$disc_type" in
        ps2)
            log DEBUG "PS2 image detected, checking size to determine if DVD structure is likely"
            local sz
            sz=$(get_file_size "$file")
            if (( sz >= 1000000000 )); then
                log DEBUG "Large PS2 image suggests DVD structure, CHDMAN_HAS_CREATEDVD=$CHDMAN_HAS_CREATEDVD"
                if [[ "$CHDMAN_HAS_CREATEDVD" == true ]]; then
                    log DEBUG "Using createdvd for large PS2 image"
                    subcmd="createdvd"
                    icon="📀"
                else
                    log WARN "⚠️ PS2 DVD detected but chdman lacks 'createdvd'. Skipping $file."
                    return 1
                fi
            else
                log DEBUG "Smaller PS2 image suggests CD structure, using createcd"
                subcmd="createcd"
                icon="💿"
            fi
            ;;
        psp|dvd)
            log DEBUG "DVD detected, CHDMAN_HAS_CREATEDVD=$CHDMAN_HAS_CREATEDVD"
            if [[ "$CHDMAN_HAS_CREATEDVD" == true ]]; then
                subcmd="createdvd"
                icon="📀"
            else
                log WARN "⚠️ Detected DVD image but this chdman lacks 'createdvd'. Skipping: $file"
                return 1
            fi
            ;;
        ps1|dreamcast|segacd|saturn|cd)
            log DEBUG "CD-type image detected, using createcd"
            subcmd="createcd"
            icon="💿"
            ;;
        *)
            log WARN "⚠️ Unknown disc type detected, defaulting to CD settings: $file"
            subcmd="createcd"
            icon="💿"
            ;;
    esac

    log INFO "$icon Detected $disc_type image → using chdman $subcmd"

    # Base concurrency on currently available physical memory. Swap is not
    # interchangeable with RAM for compression and can cause severe thrashing.
    local available_ram
    available_ram=$(( $(awk '/^MemAvailable:/{print $2; found=1} END{if(!found) print 0}' /proc/meminfo 2>/dev/null) / 1024 ))
    (( available_ram < 1 )) && available_ram=1024
    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || echo 1)
    (( cpu_cores < 1 )) && cpu_cores=1
    local ram_per_thread=2048   # Default for CDs

    if [[ "$subcmd" == "createdvd" ]]; then
        ram_per_thread=4096  # 4GB floor for DVDs (LZMA is a beast here)
    fi

    # Calculate threads from available RAM, then apply the explicit override.
    local threads=$(( available_ram / ram_per_thread ))
    (( threads < 1 )) && threads=1
    (( threads > cpu_cores )) && threads=$cpu_cores
    if [[ -n "${CHDMAN_THREADS:-}" ]]; then
        [[ "$CHDMAN_THREADS" =~ ^[1-9][0-9]*$ ]] || { log ERROR "❌ CHDMAN_THREADS must be a positive integer"; return 1; }
        threads="$CHDMAN_THREADS"
        (( threads > cpu_cores )) && threads=$cpu_cores
    fi

    local -a chdman_args=("$subcmd" -np "$threads")
    if [[ -n "${CHDMAN_HUNK_SIZE:-}" ]]; then
        [[ "$CHDMAN_HUNK_SIZE" =~ ^[1-9][0-9]*$ ]] || { log ERROR "❌ CHDMAN_HUNK_SIZE must be a positive integer"; return 1; }
        chdman_args+=(-hs "$CHDMAN_HUNK_SIZE")
    fi
    chdman_args+=(-i "$file")

    if [[ "$DRY_RUN" == true ]]; then
        local command_preview
        printf -v command_preview '%q ' "${CHDMAN_BIN:-chdman}" "${chdman_args[@]}" -o "<unique temporary CHD beside $chd_path>"
        log INFO "🧪 (dry-run) Would run: ${command_preview% }"
        return 0
    fi

    # Reserve a unique location in the destination filesystem. Keeping the
    # reservation directory until finalisation prevents concurrent runs from
    # ever allocating or writing the same temporary path.
    local tmp_dir tmp_chd
    tmp_dir="$(mktemp -d -p "$outdir" ".${base}.chd.tmp.${RUN_ID}.XXXXXX")" || {
        log ERROR "❌ Could not allocate temporary CHD path for: $chd_path"
        return 1
    }
    track_temp_dir "$tmp_dir"
    tmp_chd="$tmp_dir/$base.chd"
    track_temp_file "$tmp_chd"
    [[ -n "$result_var" ]] && printf -v "$result_var" '%s' "$tmp_chd"
    log INFO "🔧 Converting: $file -> $tmp_chd"
    local -a command=("${CHDMAN_BIN:-chdman}" "${chdman_args[@]}" -o "$tmp_chd")

    if [[ -t 2 && "${PROGRESS_STYLE:-$PROGRESS_STYLE_DEFAULT}" != "none" ]]; then
        if ! PHASE_DEFAULT="Converting" stdbuf -oL -eL "${command[@]}" 2>&1 | _chdman_progress_filter; then
            log ERROR "❌ chdman $subcmd failed for: $file"
            cleanup_temp_file_now "$tmp_chd"
            cleanup_temp_dir_now "$tmp_dir"
            return 1
        fi
    else
        if ! "${command[@]}"; then
            log ERROR "❌ chdman $subcmd failed for: $file"
            cleanup_temp_file_now "$tmp_chd"
            cleanup_temp_dir_now "$tmp_dir"
            return 1
        fi
    fi

    return 0
}

process_input() {
    local input_failed=false
    local input_file="$1"
    local ext="${input_file##*.}"; ext="${ext,,}"
    local outdir
    outdir="$(dirname "$input_file")"
    local archive_entries=()
    local archive_all_entries=()
    local archive_listing=""
    local archive_listing_exit=0
    local disc_files=()
    local expected_chds=()
    local archive_size_bytes
    archive_size_bytes=$(get_file_size "$input_file")
    local ext_regex
    ext_regex="$(build_ext_regex "${disc_exts[@]}")"
    local temp_dir=""
    declare -A output_states=()
    declare -A output_temps=()
    local direct_source_set=()

    _all_outputs_complete() {
        local expected state
        for expected in "${expected_chds[@]}"; do
            state="${output_states[$expected]:-missing}"
            [[ "$state" == "already_verified" || "$state" == "finalised" ]] || return 1
        done
        return 0
    }

    _return_failed_input() {
        failures=$((failures + 1))
        return 1
    }

    _remove_input_if_allowed() {
        if [[ "$KEEP_ORIGINALS" == true ]]; then
            log INFO "📦 Keeping original input file due to KEEP_ORIGINALS=true"
            return 0
        fi

        if [[ "$DRY_RUN" == true ]]; then
            log INFO "🧪 (dry-run) Would remove original input file: $input_file"
            return 0
        fi

        if (( ${#direct_source_set[@]} > 0 )); then
            local source
            for source in "${direct_source_set[@]}"; do
                log INFO "🗑️ Removing validated descriptor source: $source"
                rm -f -- "$source"
            done
        else
            log INFO "🗑️ Removing original input file: $input_file"
            rm -f -- "$input_file"
        fi
    }

    if is_in_list "$ext" "${archive_exts[@]}"; then
        archives_processed=$((archives_processed + 1))
        case "$ext" in
            zip)
                if archive_listing="$(unzip -Z1 -- "$input_file")"; then :; else archive_listing_exit=$?; fi
                ;;
            rar)
                if archive_listing="$(unrar lb -- "$input_file")"; then :; else archive_listing_exit=$?; fi
                ;;
            7z|7zip)
                if archive_listing="$(7z l -slt -- "$input_file")"; then :; else archive_listing_exit=$?; fi
                ;;
        esac

        if [[ $archive_listing_exit -ne 0 ]]; then
            log ERROR "❌ Archive listing failed for $input_file (Exit code: $archive_listing_exit). Skipping."
            _return_failed_input
            return 1
        fi

        case "$ext" in
            zip|rar) mapfile -t archive_all_entries <<< "$archive_listing" ;;
            # The first Path field describes the archive itself. Member records
            # begin after the separator in 7z's technical listing.
            7z|7zip) mapfile -t archive_all_entries < <(awk 'seen && /^Path = /{print substr($0,8)} /^----------$/{seen=1}' <<< "$archive_listing") ;;
        esac
        if ! validate_archive_member_paths "${archive_all_entries[@]}"; then
            log ERROR "❌ Archive path preflight failed: $input_file"
            _return_failed_input
            return 1
        fi

        case "$ext" in
            zip|rar) mapfile -t archive_entries < <(grep -Ei "$ext_regex" <<< "$archive_listing" || true) ;;
            7z|7zip) mapfile -t archive_entries < <(awk -v IGNORECASE=1 -v re="$ext_regex" 'seen && /^Path = /{p=substr($0,8); if(p~re) print p} /^----------$/{seen=1}' <<< "$archive_listing") ;;
        esac

        if [[ ${#archive_entries[@]} -gt 0 ]]; then
            mapfile -t archive_entries < <(select_preferred_disc_candidates "${archive_entries[@]}")
            if ! validate_archive_output_names "${archive_entries[@]}"; then
                _return_failed_input
                return 1
            fi
            log DEBUG "📀 Selected ${#archive_entries[@]} preferred disc descriptor(s) from archive: $(basename "$input_file")"
            for entry in "${archive_entries[@]}"; do
                local expected_chd
                expected_chd="$(archive_entry_to_chd_name "$entry")"
                log DEBUG "   Selected archive entry: $entry"
                log DEBUG "   Expected CHD: $expected_chd"
                expected_chds+=("$expected_chd")
            done
        fi
    fi

    if is_in_list "$ext" "${disc_exts[@]}"; then
        disc_files+=("$input_file")
        expected_chds+=("$(get_chd_basename "$input_file").chd")
    fi

    if [[ ${#expected_chds[@]} -eq 0 ]]; then
        log WARN "⏭️ Skipping $input_file - no disc files found (not a supported archive or disc format)"
        return 0
    fi

    # Direct descriptors own a complete validated source set. On success, all
    # members are removed together; on any failure, every source is retained.
    if [[ "$ext" == "cue" || "$ext" == "gdi" || "$ext" == "ccd" ]]; then
        if ! validate_descriptor_file "$input_file"; then
            log ERROR "❌ Descriptor validation failed (input considered failed): $input_file"
            input_failed=true
        else
            direct_source_set=("${DESCRIPTOR_SOURCE_SET[@]}")
        fi
    fi
    if [[ "$input_failed" == true ]]; then
        _return_failed_input
        return 1
    fi

    # Establish one authoritative state for every expected output.
    local expected_chd
    for expected_chd in "${expected_chds[@]}"; do
        if [[ -f "$outdir/$expected_chd" ]] && verify_chds "$outdir" "$expected_chd"; then
            output_states["$expected_chd"]="already_verified"
        else
            output_states["$expected_chd"]="missing"
        fi
    done

    # If all expected CHDs already exist and verify, generate the complete-set
    # playlist before treating source removal as the final action.
    if [[ "$input_failed" != true ]] && _all_outputs_complete; then
        log INFO "✅ All expected CHDs verified for $input_file"
        if [[ ${#expected_chds[@]} -gt 0 ]]; then
            local chd_base
            chd_base="$(basename "${expected_chds[0]}" .chd)"
            log DEBUG "🔤 Raw base name: $chd_base"
            maybe_generate_m3u_for "$chd_base" "$outdir"
        fi
        _remove_input_if_allowed
        return 0
    fi

    # Extract archive to temp and discover disc files
    if is_in_list "$ext" "${archive_exts[@]}"; then
        if [[ "$DRY_RUN" == true ]]; then
            # No mktemp in dry-run — just show intent
            local _dry_temp="(tempdir)"
            log INFO "🧪 (dry-run) Would extract $input_file to $_dry_temp"
            # We also skip scanning extracted files in dry-run (no filesystem changes exist).
            # But keep expected_chds populated from archive listing (already done above).
        else
            temp_dir="$(mktemp -d -p "$TMPDIR" "chdconv_$(basename "$input_file" ".${ext}")_XXXX")"
            track_temp_dir "$temp_dir"
            log INFO "📦 Extracting $input_file to $temp_dir"
            local extraction_exit=0
            case "$ext" in
                zip)
                    unzip -qq "$input_file" -d "$temp_dir"
                    extraction_exit=$?
                    ;;
                rar)
                    unrar x -o+ "$input_file" "$temp_dir" >/dev/null
                    extraction_exit=$?
                    ;;
                7z|7zip)
                    7z x -y -o"$temp_dir" "$input_file" >/dev/null
                    extraction_exit=$?
                    ;;
            esac

            # Strict validation: Abort if the extraction tool retrned an error code, which likely means the archive is corrupted or password-protected.
            if [[ $extraction_exit -ne 0 ]]; then
                log ERROR "❌ Extraction failed for $input_file (Exit code: $extraction_exit). Skipping."
                input_failed=true
                cleanup_temp_dir_now "$temp_dir"
                _return_failed_input
                return 1
            fi

            if ! validate_extracted_tree "$temp_dir"; then
                input_failed=true
                cleanup_temp_dir_now "$temp_dir"
                _return_failed_input
                return 1
            fi

            read -r -a disc_find_expr <<< "$(build_find_expr "${disc_exts[@]}")"
            mapfile -d '' -t disc_files < <(find "$temp_dir" -type f \( "${disc_find_expr[@]}" \) -print0)

            if [[ ${#disc_files[@]} -gt 0 ]]; then
                mapfile -t disc_files < <(select_preferred_disc_candidates "${disc_files[@]}")
                log DEBUG "📀 Selected ${#disc_files[@]} preferred extracted disc file(s) from: $temp_dir"
                for disc in "${disc_files[@]}"; do
                    log DEBUG "   Selected extracted file: $disc"
                done
            elif [[ ${#archive_entries[@]} -gt 0 ]]; then
                for entry in "${archive_entries[@]}"; do
                    local full_path="$temp_dir/$entry"
                    [[ -f "$full_path" ]] && disc_files+=("$full_path")
                done
                log DEBUG "📀 Falling back to archive-selected extracted entries: ${#disc_files[@]}"
            fi
        fi

        # In dry-run, also show which members would be converted
        if [[ "$DRY_RUN" == true && ${#archive_entries[@]} -gt 0 ]]; then
            for entry in "${archive_entries[@]}"; do
                # Mirror the naming used later: basename without extension + .chd
                log INFO "🧪 (dry-run) Would convert: $entry -> $outdir/$(archive_entry_to_chd_name "$entry")"
            done
        fi
    fi

    local archive_chd_size=0
    local tmp_chds=()
    local final_chds=()

    if [[ "$DRY_RUN" == true ]]; then
        for disc in "${disc_files[@]}"; do
            convert_disc_file "$disc" "$outdir" || input_failed=true
        done

        # Dry-run: also show M3U intent (if this looks like a multi-disc set)
        if [[ ${#expected_chds[@]} -gt 0 ]]; then
            local chd_base
            chd_base="$(basename "${expected_chds[0]}" .chd)"
            maybe_generate_m3u_for "$chd_base" "$outdir"
        fi
        
        [[ "$input_failed" == true ]] && { _return_failed_input; return 1; }
        return 0
    fi

    # Real conversion
    if is_in_list "$ext" "${archive_exts[@]}"; then
        # Drive conversion from archive_entries so output naming matches expected_chds
        for entry in "${archive_entries[@]}"; do
            local extracted="$temp_dir/$entry"
            [[ -f "$extracted" ]] || continue

            local extracted_ext="${extracted##*.}"; extracted_ext="${extracted_ext,,}"
            if [[ "$extracted_ext" == "cue" || "$extracted_ext" == "gdi" || "$extracted_ext" == "ccd" ]]; then
                if ! validate_descriptor_file "$extracted"; then
                    log ERROR "❌ Extracted descriptor validation failed: $entry"
                    input_failed=true
                    continue
                fi
            fi

            local chd_name chd_base
            chd_name="$(archive_entry_to_chd_name "$entry")"   # e.g. "CD1 - Game.chd"
            chd_base="${chd_name%.chd}"                        # e.g. "CD1 - Game"

            [[ "${output_states[$chd_name]:-missing}" == "already_verified" ]] && continue

            local converted_tmp=""
            if convert_disc_file "$extracted" "$outdir" "$chd_base" converted_tmp; then
                if [[ -n "$converted_tmp" ]]; then
                    tmp_chds+=("$converted_tmp")
                    final_chds+=("$outdir/$chd_name")
                    output_temps["$chd_name"]="$converted_tmp"
                    output_states["$chd_name"]="converted_pending_verification"
                fi
            else
                output_states["$chd_name"]="failed"
                input_failed=true
            fi
        done

        # We no longer need the extracted archive contents at this point
        cleanup_temp_dir_now "$temp_dir"
        temp_dir=""

    else
        # Non-archive inputs keep the old behaviour
        for disc in "${disc_files[@]}"; do
            local chd_name
            chd_name="$(get_chd_basename "$disc").chd"
            [[ "${output_states[$chd_name]:-missing}" == "already_verified" ]] && continue

            local converted_tmp=""
            if convert_disc_file "$disc" "$outdir" "" converted_tmp; then
                if [[ -n "$converted_tmp" ]]; then
                    tmp_chds+=("$converted_tmp")
                    final_chds+=("$outdir/$chd_name")
                    output_temps["$chd_name"]="$converted_tmp"
                    output_states["$chd_name"]="converted_pending_verification"
                fi
            else
                output_states["$chd_name"]="failed"
                input_failed=true
            fi
        done
    fi

    # Verify and finalise pending outputs independently. Existing verified
    # outputs are never added to this temporary-output verification pass.
    if [[ "$DRY_RUN" != true && ${#tmp_chds[@]} -gt 0 ]]; then
        local chd_name tmp_chd final_chd
        for chd_name in "${expected_chds[@]}"; do
            [[ "${output_states[$chd_name]:-missing}" == "converted_pending_verification" ]] || continue
            tmp_chd="${output_temps[$chd_name]}"
            final_chd="$outdir/$chd_name"
            if verify_chds "" "$tmp_chd"; then
                mv -f -- "$tmp_chd" "$final_chd"
                untrack_temp_file "$tmp_chd"
                cleanup_temp_dir_now "$(dirname "$tmp_chd")"
                log INFO "🔄 Replaced old CHD with new verified CHD: $final_chd"
                chds_created=$((chds_created + 1))
                output_states["$chd_name"]="finalised"
            else
                cleanup_temp_file_now "$tmp_chd"
                cleanup_temp_dir_now "$(dirname "$tmp_chd")"
                output_states["$chd_name"]="failed"
                input_failed=true
                log WARN "⚠️ CHD verification failed after conversion for $chd_name"
            fi
        done
    fi

    if [[ "$input_failed" == true ]] || ! _all_outputs_complete; then
        log WARN "⚠️ Not all expected members converted successfully for $input_file, keeping original"
        _return_failed_input
        return 1
    fi

    # Source deletion, accounting, and M3U generation all consume the same
    # complete manifest rather than independently inferring success.
    for chd_name in "${expected_chds[@]}"; do
        archive_chd_size=$((archive_chd_size + $(get_file_size "$outdir/$chd_name")))
    done
    if [[ $archive_size_bytes -gt 0 ]]; then
        local saving=$((archive_size_bytes - archive_chd_size))
        local saving_percent=$((100 * saving / archive_size_bytes))
        log INFO "📉 Space saving for $(basename "$input_file"): $(human_readable "$archive_size_bytes") → $(human_readable "$archive_chd_size"), saved $(human_readable "$saving") (${saving_percent}%)"
        total_original_size=$((total_original_size + archive_size_bytes))
        total_chd_size=$((total_chd_size + archive_chd_size))
    fi

    if [[ ${#expected_chds[@]} -gt 0 ]]; then
        local chd_base
        chd_base="$(basename "${expected_chds[0]}" .chd)"
        log DEBUG "🔤 Raw base name: $chd_base"
        maybe_generate_m3u_for "$chd_base" "$outdir"
    fi

    _remove_input_if_allowed

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
    process_input "$input" || log ERROR "⚠️ Failed to process $input"
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
if [[ $failures -gt 0 ]]; then
    log ERROR "⚠️ Completed with failures ($failures input(s) failed)."
    exit 2
fi

log INFO "✅ Completed successfully."
exit 0
