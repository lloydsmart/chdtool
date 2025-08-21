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
LOGFILE="logs/chd_conversion_$(date +%Y%m%d_%H%M%S).log"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

log "🚀 Script started, input dir: $INPUT_DIR"
[[ "$RECURSIVE" == true ]] && log "📂 Recursive mode enabled — scanning subdirectories"

verify_output_log() {
    while IFS= read -r line; do
        printf "[%s] %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$line" >> "$LOGFILE"
    done
}

is_in_list() {
    local value="$1"; shift
    local list=("$@")
    [[ " ${list[*]} " =~ (^|[[:space:]])"$value"([[:space:]]|$) ]]
}

required_commands=(chdman unzip unrar 7z stat)
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
    unset 'expr[${#expr[@]}-1]'   # Remove trailing -o
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
        log "❌ Error: Required command '$cmd' not found. Please install it and ensure it's in your PATH."
        exit 1
    fi
done

chdman_version="$(chdman --help 2>&1 | head -n 1 || true)"
log "ℹ️ Using $chdman_version"
# Detect 'createdvd' capability (newer chdman versions)
CHDMAN_HAS_CREATEDVD=false
if chdman -help 2>&1 | grep -qiE '(^|[[:space:]])createdvd([[:space:]]|$)'; then
    CHDMAN_HAS_CREATEDVD=true
fi
log "ℹ️ chdman createdvd support: $CHDMAN_HAS_CREATEDVD"


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

# ---------- M3U (per-iteration) helpers ----------
# Trim leading/trailing spaces/dots/underscores/dashes
trim() {
    local s="$*"
    s="${s##+([[:space:]._-])}"
    s="${s%%+([[:space:]._-])}"
    printf "%s" "$s"
}

# Parse disc info from a base name (no extension).
# On success, echoes "<base>|<disc_num>" and returns 0; else returns 1.
parse_disc_info() {
    local name="$1"
    # A) "… Disc 2", "… CD3", "… Disk 1", "… GD-ROM 2"
    local re_a='^(.*?)[[:space:]._-]*\(?([Dd][Ii][Ss][Cc]|[Cc][Dd]|[Dd][Ii][Ss][Kk]|[Gg][Dd](?:-[Rr][Oo][Mm])?)[[:space:]]*([0-9]+)\)?([[:space:]]*.*)?$'
    # B) "… (1 of 2)" / "… 1 of 2" / "… 1/2"
    local re_b='^(.*?)[[:space:]._-]*\(?([0-9]+)[[:space:]]*(?:of|/)[[:space:]]*[0-9]+\)?([[:space:]]*.*)?$'

    if [[ "$name" =~ $re_a ]]; then
        local base="${BASH_REMATCH[1]}"; local num="${BASH_REMATCH[3]}"
        base="$(trim "$base")"
        [[ -n "$base" && -n "$num" ]] && echo "$base|$num" && return 0
    fi
    if [[ "$name" =~ $re_b ]]; then
        local base="${BASH_REMATCH[1]}"; local num="${BASH_REMATCH[2]}"
        base="$(trim "$base")"
        [[ -n "$base" && -n "$num" ]] && echo "$base|$num" && return 0
    fi
    return 1
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
        log "ℹ️ Not generating M3U - fewer than two CHDs found for base: $base"
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
    local m3u_path="$outdir/${base}.m3u"
    local tmp_m3u="$m3u_path.tmp"
    : > "$tmp_m3u"
    for f in "${members[@]}"; do
        printf '%s\n' "$(basename "$f")" >> "$tmp_m3u"
    done
    if [[ -f "$m3u_path" ]] && cmp -s "$tmp_m3u" "$m3u_path"; then
        rm -f "$tmp_m3u"
        log "🧾 M3U up-to-date: $m3u_path"
    else
        mv -f "$tmp_m3u" "$m3u_path"
        [[ -f "$m3u_path" ]] && log "📝 Updated M3U: $m3u_path" || log "🆕 Created M3U: $m3u_path"
    fi
}

# Decide if $chd_base looks like a multi-disc title and (re)generate its M3U now.
maybe_generate_m3u_for() {
    local chd_base="$1"   # e.g. "Virtua Fighter (Disc 2)"
    local outdir="$2"     # directory where CHDs live
    local parsed
    if ! parsed="$(parse_disc_info "$chd_base")"; then
        log "ℹ️ Not generating M3U - CHD not part of multi-disc set: $chd_base"
        return 0
    fi
    local base="${parsed%%|*}"
    log "🔎 M3U check — base: $base"
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

        log "🔎 Verifying: $chd_path"
        verify_output=$(chdman verify -i "$chd_path" 2>&1)
        verify_exit_code=$?
        echo "$verify_output" | verify_output_log

        if [[ $verify_exit_code -ne 0 ]] || ! echo "$verify_output" | grep -qi "verification successful"; then
            local failure_reasons
            failure_reasons=$(echo "$verify_output" | grep -iE 'error|fail|invalid|corrupt' || true)
            log "⚠️ Verification failed on first try for: $chd_path"
            [[ -n "$failure_reasons" ]] && log "   Failure details: $failure_reasons"
            log "⏳ Retrying after delay..."
            sleep 2

            log "🔎 Verifying: $chd_path"
            verify_output=$(chdman verify -i "$chd_path" 2>&1)
            verify_exit_code=$?
            echo "$verify_output" | verify_output_log

            if [[ $verify_exit_code -ne 0 ]] || ! echo "$verify_output" | grep -qi "verification successful"; then
                failure_reasons=$(echo "$verify_output" | grep -iE 'error|fail|invalid|corrupt' || true)
                failures=$((failures + 1))
                log "❌ Verification failed on retry for: $chd_path — deleting"
                [[ -n "$failure_reasons" ]] && log "   Failure details: $failure_reasons"
                rm -f "$chd_path"
                all_verified=false
                break
            else
                log "✅ Verified on retry: $chd_path"
            fi
        else
            log "✅ Verified CHD: $chd_path"
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

    mapfile -t actual_files < <(find "$cuedir" -maxdepth 1 -type f -printf "%f\n")
    declare -A file_map
    for f in "${actual_files[@]}"; do
        file_map["${f,,}"]="$f"
    done

    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*FILE[[:space:]]+\"([^\"]+)\" ]]; then
            local ref="${BASH_REMATCH[1]}"
            local ref_norm="${ref//\\//}"
            local ref_basename; ref_basename="$(basename "$ref_norm")"
            local ref_lower="${ref_basename,,}"

            [[ "$ref_lower" == "${cue_basename,,}" ]] && continue

            if [[ "$ref_lower" == *.mp3 || "$ref_lower" == *.wav ]]; then
                log "⚠️ CUE file references unsupported audio format: $ref_basename"
            fi
            if [[ "$ref_norm" == /* || "$ref_norm" == *".."* ]]; then
                log "⚠️ Skipping unsafe external path in CUE: $ref_basename"
                continue
            fi
            if [[ -z "${file_map["$ref_lower"]:-}" ]]; then
                log "❌ Missing referenced file in CUE: $ref_basename (required by $cue_file)"
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
            log "❌ Missing referenced file in CUE: $file"
            return 1
        fi
    fi

    local base
    base="$(get_chd_basename "$file")"
    local chd_path="$outdir/$base.chd"
    local tmp_chd="$outdir/$base.chd.tmp"

    # If a CHD already exists, verify it and skip if good
    if [[ -f "$chd_path" ]]; then
        log "🔎 Verifying existing CHD before conversion: $chd_path"
        if verify_chds "$outdir" "$base.chd"; then
            log "✅ Existing CHD verified, skipping conversion: $chd_path"
            return 0
        else
            failures=$((failures + 1))
            log "❌ Existing CHD verification failed, will convert and replace"
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
            log "⚠️ Detected DVD image but this chdman lacks 'createdvd'. Skipping: $file"
            failures=$((failures + 1))
            return 1
        fi
    else
        subcmd="createcd"
        icon="💿"      # CD
    fi

    log "$icon Detected $disc_type image → using chdman $subcmd"
    log "🔧 Converting: $file -> $tmp_chd"
    chdman "$subcmd" -i "$file" -o "$tmp_chd" | verify_output_log

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
        log "⏭️ Skipping $input_file - no disc files found (not a supported archive or disc format)"
        return 0
    fi

    # If all expected CHDs already exist and verify, remove original and done
    if verify_chds "$outdir" "${expected_chds[@]}"; then
        log "✅ All expected CHDs verified for $input_file"
        if [[ "$KEEP_ORIGINALS" != true ]]; then
            log "🗑️ Removing original input file: $input_file"
            rm -f "$input_file"
        else
            log "📦 Keeping original input file due to KEEP_ORIGINALS=true"
        fi
        # Per-iteration M3U generation for already-present sets
        if [[ ${#expected_chds[@]} -gt 0 ]]; then
            local chd_base
            chd_base="$(basename "${expected_chds[0]}" .chd)"
            log "🔤 Raw base name: $chd_base"
            maybe_generate_m3u_for "$chd_base" "$outdir"
        fi
        return 0
    fi

    # Extract archive to temp and discover disc files
    if is_in_list "$ext" "${archive_exts[@]}"; then
        local temp_dir
        temp_dir="$(mktemp -d -t "chdconv_$(basename "$input_file" ".${ext}")_XXXX")"
        log "📦 Extracting $input_file to $temp_dir"
        case "$ext" in
            zip) unzip -qq "$input_file" -d "$temp_dir" ;;
            rar) unrar x -o+ "$input_file" "$temp_dir" >/dev/null ;;
            7z|7zip) 7z x -y -o"$temp_dir" "$input_file" >/dev/null ;;
        esac

        read -r -a disc_find_expr <<< "$(build_find_expr "${disc_exts[@]}")"
        mapfile -t disc_files < <(find "$temp_dir" -type f \( "${disc_find_expr[@]}" \))

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
                log "🔄 Replaced old CHD with new verified CHD: $final_chd"
                chds_created=$((chds_created + 1))
            done

            if [[ "$KEEP_ORIGINALS" != true ]]; then
                log "🗑️ Removing original input file: $input_file"
                rm -f "$input_file"
            else
                log "📦 Keeping original input file due to KEEP_ORIGINALS=true"
            fi

            for chd in "${expected_chds[@]}"; do
                if [[ -f "$outdir/$chd" ]]; then
                    archive_chd_size=$((archive_chd_size + $(get_file_size "$outdir/$chd")))
                fi
            done
            if [[ $archive_size_bytes -gt 0 ]]; then
                local saving=$((archive_size_bytes - archive_chd_size))
                local saving_percent=$((100 * saving / archive_size_bytes))
                log "📉 Space saving for $(basename "$input_file"): $(human_readable "$archive_size_bytes") → $(human_readable "$archive_chd_size"), saved $(human_readable "$saving") (${saving_percent}%)"
                total_original_size=$((total_original_size + archive_size_bytes))
                total_chd_size=$((total_chd_size + archive_chd_size))
            fi
        else
            for tmp_chd in "${tmp_chds[@]}"; do
                if [[ -f "$tmp_chd" ]]; then
                    rm -f "$tmp_chd"
                    log "🗑️ Removed failed tmp CHD: $tmp_chd"
                fi
            done
            failures=$((failures + 1))
            log "⚠️ CHD verification failed after conversion for $input_file, keeping original"
        fi
    fi

    # Per-iteration M3U generation for newly written CHDs
    if [[ ${#expected_chds[@]} -gt 0 ]]; then
        local chd_base
        chd_base="$(basename "${expected_chds[0]}" .chd)"
        log "🔤 Raw base name: $chd_base"
        maybe_generate_m3u_for "$chd_base" "$outdir"
    fi

    # Per-iteration temp cleanup
    if [[ -n "$temp_dir" && -d "$temp_dir" ]]; then
        rm -rf "$temp_dir"
        log "🧹 Cleaned up temp dir: $temp_dir"
    fi

    return 0
}

# Main processing loop
read -r -a find_expr <<< "$(build_find_expr "${all_exts[@]}")"

if [[ -z "${find_expr[*]:-}" ]]; then
    log "⚠️ No valid file extensions found for searching, exiting."
    exit 1
fi

if [[ "$RECURSIVE" == true ]]; then
    mapfile -t all_inputs < <(find "$INPUT_DIR" \( -path '*/.*' -prune \) -o -type f \( "${find_expr[@]}" \) -print)
else
    mapfile -t all_inputs < <(find "$INPUT_DIR" -maxdepth 1 -type f \( "${find_expr[@]}" \))
fi
log "🔎 Found ${#all_inputs[@]} inputs"

for input in "${all_inputs[@]}"; do
    log "▶️ Processing file: $input"
    if ! process_input "$input"; then
        log "⚠️ Failed to process $input"
    fi
done

log "📊 Summary:"
if [[ $total_original_size -gt 0 ]]; then
    total_saved=$((total_original_size - total_chd_size))
    total_percent=$((100 * total_saved / total_original_size))
    log "📦 Total original size: $(human_readable $total_original_size)"
    log "💿 Total CHD size: $(human_readable $total_chd_size)"
    log "📉 Total space saved: $(human_readable $total_saved) (${total_percent}%)"
fi
log "📦 Archives processed: $archives_processed"
log "💿 CHDs created:       $chds_created"
log "❌ Failures:           $failures"
log "⏱️ Elapsed time: $(format_duration $(( $(date +%s) - script_start_time )))"
log "✅ Done!"