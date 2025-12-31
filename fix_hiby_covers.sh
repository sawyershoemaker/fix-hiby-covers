#!/usr/bin/env bash
set -euo pipefail

readonly RST=$'\033[0m'
readonly BOLD=$'\033[1m'
readonly DIM=$'\033[2m'

#colors
readonly RED=$'\033[38;5;203m'
readonly GREEN=$'\033[38;5;114m'
readonly YELLOW=$'\033[38;5;221m'
readonly BLUE=$'\033[38;5;74m'
readonly CYAN=$'\033[38;5;80m'
readonly ORANGE=$'\033[38;5;215m'
readonly GRAY=$'\033[38;5;245m'
readonly WHITE=$'\033[38;5;255m'

REQUIRED_CMDS=(metaflac wslpath mktemp stat parallel)
REQUIRED_PKGS=(flac coreutils parallel)

# prefer vips over imagemagick if available
USE_VIPS=0
if command -v vipsthumbnail >/dev/null 2>&1; then
  USE_VIPS=1
else
  REQUIRED_CMDS+=(convert identify)
  REQUIRED_PKGS+=(imagemagick)
fi

JOBS=$(nproc 2>/dev/null || echo 4)
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
(( TERM_WIDTH > 100 )) && TERM_WIDTH=100

# use RAM disk if available for temp files
if [[ -d /dev/shm && -w /dev/shm ]]; then
  TMPBASE="/dev/shm/hiby_$$"
else
  TMPBASE="/tmp/hiby_$$"
fi

# ui funcs
print_section() {
  local title="$1"
  echo
  printf "  ${BOLD}${WHITE}[${RST}${CYAN}%s${RST}${BOLD}${WHITE}]${RST}\n" "$title"
  printf "  ${DIM}${GRAY}%s${RST}\n" "$(printf -- '-%.0s' $(seq 1 $((${#title} + 2))))"
}

err() {
  printf "\n  ${RED}${BOLD}Error:${RST} ${WHITE}%s${RST}\n\n" "$*" >&2
  exit 1
}

info() {
  printf "    ${BLUE}>${RST} ${GRAY}%s${RST}\n" "$*"
}

success() {
  printf "    ${GREEN}+${RST} ${WHITE}%s${RST}\n" "$*"
}

warn() {
  printf "    ${YELLOW}!${RST} ${YELLOW}%s${RST}\n" "$*"
}

check_command() {
  command -v "$1" >/dev/null 2>&1
}

print_usage() {
  printf "  ${BOLD}${WHITE}Usage:${RST}\n"
  printf "    ${CYAN}fix_hiby_covers.sh${RST} ${GRAY}<folder>${RST} ${DIM}[--force]${RST}\n\n"
  printf "  ${BOLD}${WHITE}Options:${RST}\n"
  printf "    ${YELLOW}--force${RST}    Re-check all files, ignoring cache\n\n"
  printf "  ${BOLD}${WHITE}Examples:${RST}\n"
  printf "    ${DIM}${GRAY}# Windows path${RST}\n"
  printf "    ${CYAN}fix_hiby_covers.sh${RST} ${WHITE}\"C:\\Users\\(username)\\Music\"${RST}\n\n"
  printf "    ${DIM}${GRAY}# WSL/Linux path${RST}\n"
  printf "    ${CYAN}fix_hiby_covers.sh${RST} ${WHITE}/mnt/d/FLAC${RST}\n\n"
  printf "    ${DIM}${GRAY}# Force re-scan${RST}\n"
  printf "    ${CYAN}fix_hiby_covers.sh${RST} ${WHITE}/mnt/d/FLAC${RST} ${YELLOW}--force${RST}\n\n"
  exit 1
}

if [[ $# -lt 1 ]]; then
  print_usage
fi

INPUT="$1"
FORCE_MODE=0
[[ "${2:-}" == "--force" ]] && FORCE_MODE=1

if [[ "$INPUT" =~ ^[A-Za-z]:\\ ]]; then
  ROOT="$(wslpath "$INPUT")"
else
  ROOT="$INPUT"
fi

[[ -d "$ROOT" ]] || err "'$ROOT' is not a directory"

CACHE_FILE="$ROOT/.hiby_covers.cache"

# main
print_section "Dependencies"

MISSING_PKGS=()

for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! check_command "$cmd"; then
    case "$cmd" in
      metaflac) MISSING_PKGS+=(flac) ;;
      convert|identify) MISSING_PKGS+=(imagemagick) ;;
      mktemp|stat) MISSING_PKGS+=(coreutils) ;;
      parallel) MISSING_PKGS+=(parallel) ;;
      *) MISSING_PKGS+=("$cmd") ;;
    esac
  fi
done

if (( ${#MISSING_PKGS[@]} > 0 )); then
  MISSING_PKGS=($(printf "%s\n" "${MISSING_PKGS[@]}" | sort -u))
  warn "Installing: ${MISSING_PKGS[*]}"
  sudo apt update
  sudo apt install -y "${MISSING_PKGS[@]}"
  success "Packages installed"
else
  success "All dependencies present"
fi

if (( USE_VIPS )); then
  info "Using vips (faster)"
else
  info "Using ImageMagick"
fi
info "Parallel jobs: $JOBS"

print_section "Cache"

# setup work directory
mkdir -p "$TMPBASE"
trap 'rm -rf "$TMPBASE" 2>/dev/null || true; printf "\033[?25h"' EXIT

CACHE_EXPORT="$TMPBASE/cache_in.tsv"
RESULTS_DIR="$TMPBASE/results"
FIXED_LOG="$TMPBASE/fixed.log"
mkdir -p "$RESULTS_DIR"

# export cache for parallel workers to read
if [[ -f "$CACHE_FILE" ]] && (( FORCE_MODE == 0 )); then
  cp "$CACHE_FILE" "$CACHE_EXPORT"
  CACHE_COUNT=$(wc -l < "$CACHE_EXPORT")
  success "Loaded ${BOLD}${CACHE_COUNT}${RST}${WHITE} cached entries"
else
  touch "$CACHE_EXPORT"
  if (( FORCE_MODE == 1 )); then
    info "Force mode: ignoring cache"
  else
    info "No cache found, starting fresh"
  fi
fi

print_section "Scanning"
info "Target: ${BOLD}${WHITE}$ROOT${RST}"

# single find pass - collect all files into array
mapfile -d '' FILES < <(find "$ROOT" -type f -iname "*.flac" -print0 2>/dev/null)
TOTAL_FILES=${#FILES[@]}

if (( TOTAL_FILES == 0 )); then
  warn "No FLAC files found"
  printf "\033[?25h"
  exit 0
fi

info "Found ${BOLD}${WHITE}$TOTAL_FILES${RST}${GRAY} FLAC files"
info "Processing with $JOBS parallel workers..."
echo

# worker script for GNU parallel
WORKER_SCRIPT="$TMPBASE/worker.sh"
cat > "$WORKER_SCRIPT" << 'WORKER_EOF'
#!/usr/bin/env bash
set -euo pipefail

f="$1"
CACHE_FILE="$2"
RESULTS_DIR="$3"
FIXED_LOG="$4"
USE_VIPS="$5"
TMPBASE="$6"

# unique ID for this file
FILE_HASH=$(echo "$f" | md5sum | cut -c1-12)
RESULT_FILE="$RESULTS_DIR/$FILE_HASH"
WORK_DIR="$TMPBASE/work_$FILE_HASH"
mkdir -p "$WORK_DIR"

cleanup() {
  rm -rf "$WORK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

mtime="$(stat -c '%Y' "$f" 2>/dev/null)" || exit 0

# check cache
if [[ -f "$CACHE_FILE" ]]; then
  cached_line=$(grep -F "$f"$'\t' "$CACHE_FILE" 2>/dev/null | head -1) || true
  if [[ -n "$cached_line" ]]; then
    cached_mtime=$(echo "$cached_line" | cut -f2)
    cached_status=$(echo "$cached_line" | cut -f3)
    if [[ "$cached_mtime" == "$mtime" ]]; then
      printf '%s\t%s\t%s\tCACHED\n' "$f" "$mtime" "$cached_status" > "$RESULT_FILE"
      exit 0
    fi
  fi
fi

tmp_cover="$WORK_DIR/cover.jpg"
fixed_cover="$WORK_DIR/fixed.jpg"

# extract cover
if ! metaflac --export-picture-to="$tmp_cover" "$f" </dev/null 2>/dev/null; then
  printf '%s\t%s\tNOCOV\tNOCOV\n' "$f" "$mtime" > "$RESULT_FILE"
  exit 0
fi

# check image properties
if (( USE_VIPS )); then
  # vips gives dimensions, assume non-interlaced
  dims=$(vipsheader -f width -f height "$tmp_cover" 2>/dev/null | tr '\n' ' ') || dims="0 0"
  read -r width height <<< "$dims"
  interlace="none"
else
  ident_output="$(identify -quiet -format '%[interlace] %w %h' "$tmp_cover" </dev/null 2>/dev/null)" || ident_output="unknown 0 0"
  read -r interlace width height <<< "$ident_output"
  interlace="${interlace,,}"
fi

width=${width:-0}
height=${height:-0}

if [[ "$interlace" == "none" ]] && (( width <= 1000 )) && (( height <= 1000 )); then
  printf '%s\t%s\tOK\tOK\n' "$f" "$mtime" > "$RESULT_FILE"
  exit 0
fi

# needs fixing
basename="$(basename "$f")"

if (( USE_VIPS )); then
  vipsthumbnail "$tmp_cover" -s 1000x1000 -o "$fixed_cover" 2>/dev/null
else
  convert "$tmp_cover" -resize 1000x1000\> -interlace none -strip "$fixed_cover" </dev/null
fi

metaflac --remove --block-type=PICTURE "$f" </dev/null
metaflac --import-picture-from="$fixed_cover" "$f" </dev/null

new_mtime="$(stat -c '%Y' "$f" 2>/dev/null)" || new_mtime="$mtime"

printf '%s\t%s\tOK\tFIXED\n' "$f" "$new_mtime" > "$RESULT_FILE"
printf '%s|%s|%dx%d\n' "$basename" "$interlace" "$width" "$height" >> "$FIXED_LOG"
WORKER_EOF
chmod +x "$WORKER_SCRIPT"

# hide cursor
printf "\033[?25l"

# progress monitor in background
PROGRESS_PID=""
(
  while true; do
    completed=$(find "$RESULTS_DIR" -type f 2>/dev/null | wc -l)
    pct=0
    (( TOTAL_FILES > 0 )) && pct=$((completed * 100 / TOTAL_FILES))
    
    # build progress bar
    bar_width=50
    filled=$((bar_width * completed / TOTAL_FILES))
    (( filled > bar_width )) && filled=$bar_width
    empty=$((bar_width - filled))
    
    bar=""
    (( filled > 0 )) && bar+=$(printf '=%.0s' $(seq 1 $filled))
    (( empty > 0 )) && bar+=$(printf -- '-%.0s' $(seq 1 $empty))
    
    printf "\r    [%s] %3d%%  %d/%d  " "$bar" "$pct" "$completed" "$TOTAL_FILES"
    
    (( completed >= TOTAL_FILES )) && break
    sleep 0.2
  done
) &
PROGRESS_PID=$!

# run parallel (quiet, no bar)
printf '%s\0' "${FILES[@]}" | parallel --null -j "$JOBS" \
  "$WORKER_SCRIPT" {} "$CACHE_EXPORT" "$RESULTS_DIR" "$FIXED_LOG" "$USE_VIPS" "$TMPBASE" \
  2>/dev/null

# stop progress monitor
kill "$PROGRESS_PID" 2>/dev/null || true
wait "$PROGRESS_PID" 2>/dev/null || true

# clear progress line
printf '\r%*s\r' 80 ""

# show cursor
printf "\033[?25h"

# aggregate results
CACHE_TMP="$TMPBASE/cache_out.tsv"
FIXED=0
SKIPPED_OK=0
SKIPPED_CACHED=0
NO_COVER=0

for result_file in "$RESULTS_DIR"/*; do
  [[ -f "$result_file" ]] || continue
  while IFS=$'\t' read -r fpath fmtime fstatus faction; do
    printf '%s\t%s\t%s\n' "$fpath" "$fmtime" "$fstatus" >> "$CACHE_TMP"
    case "$faction" in
      CACHED) ((++SKIPPED_CACHED)) ;;
      OK) ((++SKIPPED_OK)) ;;
      FIXED) ((++FIXED)) ;;
      NOCOV) ((++NO_COVER)) ;;
    esac
  done < "$result_file"
done

# save new cache
mv "$CACHE_TMP" "$CACHE_FILE" 2>/dev/null || true

# end summary
print_section "Results"

if [[ -f "$FIXED_LOG" ]] && [[ -s "$FIXED_LOG" ]]; then
  echo
  printf "    ${ORANGE}Fixed files:${RST}\n"
  count=0
  while IFS='|' read -r fname finterlace fsize; do
    printf "      ${DIM}${GRAY}|${RST} ${WHITE}%s${RST} ${DIM}(${YELLOW}%s${DIM}, ${CYAN}%s${DIM})${RST}\n" \
      "$fname" "$finterlace" "$fsize"
    ((++count))
    if (( count >= 10 )); then
      remaining=$(( $(wc -l < "$FIXED_LOG") - 10 ))
      if (( remaining > 0 )); then
        printf "      ${DIM}${GRAY}+ ... and %d more${RST}\n" "$remaining"
      fi
      break
    fi
  done < "$FIXED_LOG"
  echo
fi

#statbox
printf "\n"
printf "    ${ORANGE}Fixed:${RST}            %4d\n" "$FIXED"
printf "    ${GREEN}Already OK:${RST}       %4d\n" "$SKIPPED_OK"
printf "    ${CYAN}From cache:${RST}       %4d\n" "$SKIPPED_CACHED"
printf "    ${GRAY}No cover:${RST}         %4d\n" "$NO_COVER"
printf "    ${DIM}-------------------------${RST}\n"
printf "    ${WHITE}Total processed:${RST}  %4d\n" "$TOTAL_FILES"

echo
if (( FIXED > 0 )); then
  printf "  ${BOLD}${WHITE}Complete!${RST} ${GREEN}%d covers optimized for HiBY.${RST}\n\n" "$FIXED"
else
  printf "  ${BOLD}${WHITE}Complete!${RST} ${GRAY}All covers are already optimized.${RST}\n\n"
fi
