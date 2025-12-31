#!/usr/bin/env bash
set -euo pipefail

readonly RST=$'\033[0m'
readonly BOLD=$'\033[1m'
readonly DIM=$'\033[2m'
readonly ITAL=$'\033[3m'

#colors
readonly RED=$'\033[38;5;203m'
readonly GREEN=$'\033[38;5;114m'
readonly YELLOW=$'\033[38;5;221m'
readonly BLUE=$'\033[38;5;74m'
readonly PURPLE=$'\033[38;5;176m'
readonly CYAN=$'\033[38;5;80m'
readonly ORANGE=$'\033[38;5;215m'
readonly GRAY=$'\033[38;5;245m'
readonly WHITE=$'\033[38;5;255m'

#background
readonly BG_GREEN=$'\033[48;5;22m'
readonly BG_RED=$'\033[48;5;52m'
readonly BG_BLUE=$'\033[48;5;24m'

#progbar
readonly BAR_FULL="="
readonly BAR_EMPTY="-"

REQUIRED_CMDS=(metaflac convert wslpath identify mktemp stat)
REQUIRED_PKGS=(flac imagemagick coreutils)

TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
(( TERM_WIDTH > 100 )) && TERM_WIDTH=100


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

# progress bar
draw_progress_bar() {
  local current=$1
  local total=$2
  local width=$((TERM_WIDTH - 35))
  local pct=0
  (( total > 0 )) && pct=$((current * 100 / total))
  local filled=$((width * current / total))
  (( filled > width )) && filled=$width
  local empty=$((width - filled))
  
  local bar=""
  (( filled > 0 )) && bar+="${GREEN}$(printf -- "${BAR_FULL}%.0s" $(seq 1 $filled))${RST}"
  (( empty > 0 )) && bar+="${DIM}${GRAY}$(printf -- "${BAR_EMPTY}%.0s" $(seq 1 $empty))${RST}"
  
  printf "\r    ${DIM}[${RST}%s${DIM}]${RST} ${BOLD}${WHITE}%3d%%${RST}  ${GRAY}%d/%d${RST}  " \
    "$bar" "$pct" "$current" "$total"
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

print_section "Cache"

declare -A CACHE
if [[ -f "$CACHE_FILE" ]] && (( FORCE_MODE == 0 )); then
  while IFS=$'\t' read -r cached_path cached_mtime cached_status; do
    [[ -n "$cached_path" ]] && CACHE["$cached_path"]="$cached_mtime|$cached_status"
  done < "$CACHE_FILE"
  success "Loaded ${BOLD}${#CACHE[@]}${RST}${WHITE} cached entries"
else
  if (( FORCE_MODE == 1 )); then
    info "Force mode: ignoring cache"
  else
    info "No cache found, starting fresh"
  fi
fi

# stats
SKIPPED_CACHED=0
SKIPPED_OK=0
FIXED=0
NO_COVER=0

CACHE_TMP="$(mktemp)"
trap 'rm -f "$CACHE_TMP" 2>/dev/null || true; printf "\033[?25h"' EXIT

declare -a FIXED_FILES=()

process_file() {
  local f="$1"
  local mtime status

  mtime="$(stat -c '%Y' "$f" 2>/dev/null)" || return

  if [[ -v CACHE["$f"] ]]; then
    local cached="${CACHE["$f"]}"
    local cached_mtime="${cached%%|*}"
    local cached_status="${cached##*|}"
    if [[ "$cached_mtime" == "$mtime" ]]; then
      ((++SKIPPED_CACHED))
      printf '%s\t%s\t%s\n' "$f" "$mtime" "$cached_status" >> "$CACHE_TMP"
      return
    fi
  fi

  local dir tmp_base tmpdir tmp_cover fixed_cover
  dir="$(dirname "$f")"
  tmp_base="$dir/.hiby_tmp"
  mkdir -p "$tmp_base"
  tmpdir="$(mktemp -d "$tmp_base/tmp.XXXXXX")"

  tmp_cover="$tmpdir/cover_tmp.jpg"
  fixed_cover="$tmpdir/cover_fixed.jpg"

  if ! metaflac --export-picture-to="$tmp_cover" "$f" </dev/null 2>/dev/null; then
    rm -rf "$tmpdir"
    rmdir "$tmp_base" 2>/dev/null || true
    ((++NO_COVER))
    printf '%s\t%s\t%s\n' "$f" "$mtime" "NOCOV" >> "$CACHE_TMP"
    return
  fi

  local ident_output interlace width height
  interlace="unknown"
  width=0
  height=0

  if ident_output="$(identify -quiet -format '%[interlace] %w %h' "$tmp_cover" </dev/null 2>/dev/null)"; then
    read -r interlace width height <<<"$ident_output"
    interlace="${interlace,,}"
  fi

  if [[ "$interlace" == "none" ]] && (( width <= 1000 )) && (( height <= 1000 )); then
    ((++SKIPPED_OK))
    printf '%s\t%s\t%s\n' "$f" "$mtime" "OK" >> "$CACHE_TMP"
    rm -rf "$tmpdir"
    rmdir "$tmp_base" 2>/dev/null || true
    return
  fi

  local basename
  basename="$(basename "$f")"
  FIXED_FILES+=("${basename}|${interlace}|${width}x${height}")

  convert "$tmp_cover" \
    -resize 1000x1000\> \
    -interlace none \
    -strip \
    "$fixed_cover" </dev/null

  metaflac --remove --block-type=PICTURE "$f" </dev/null
  metaflac --import-picture-from="$fixed_cover" "$f" </dev/null

  local new_mtime
  new_mtime="$(stat -c '%Y' "$f" 2>/dev/null)" || new_mtime="$mtime"

  ((++FIXED))
  printf '%s\t%s\t%s\n' "$f" "$new_mtime" "OK" >> "$CACHE_TMP"

  rm -rf "$tmpdir"
  rmdir "$tmp_base" 2>/dev/null || true
}

print_section "Scanning"
info "Target: ${BOLD}${WHITE}$ROOT${RST}"

printf "\033[?25l"

TOTAL_FILES=$(find "$ROOT" -type f -iname "*.flac" 2>/dev/null | wc -l)
CURRENT=0

if (( TOTAL_FILES == 0 )); then
  warn "No FLAC files found"
else
  info "Found ${BOLD}${WHITE}$TOTAL_FILES${RST}${GRAY} FLAC files"
  echo

  while IFS= read -r -d '' f; do
    ((++CURRENT))
    draw_progress_bar "$CURRENT" "$TOTAL_FILES"
    process_file "$f"
  done < <(find "$ROOT" -type f -iname "*.flac" -print0 2>/dev/null)

  printf '\r%*s\r' "$TERM_WIDTH" ""
fi

printf "\033[?25h"

mv "$CACHE_TMP" "$CACHE_FILE" 2>/dev/null || true

# end summary
print_section "Results"

if (( ${#FIXED_FILES[@]} > 0 )); then
  echo
  printf "    ${ORANGE}Fixed files:${RST}\n"
  count=0
  for entry in "${FIXED_FILES[@]}"; do
    IFS='|' read -r fname finterlace fsize <<<"$entry"
    printf "      ${DIM}${GRAY}|${RST} ${WHITE}%s${RST} ${DIM}(${YELLOW}%s${DIM}, ${CYAN}%s${DIM})${RST}\n" \
      "$fname" "$finterlace" "$fsize"
    ((++count))
    if (( count >= 10 && ${#FIXED_FILES[@]} > 10 )); then
      printf "      ${DIM}${GRAY}+ ... and %d more${RST}\n" $(( ${#FIXED_FILES[@]} - 10 ))
      break
    fi
  done
  echo
fi

#statbox
printf "\n"
printf "    ${ORANGE}Fixed:${RST}            %4d\n" "$FIXED"
printf "    ${GREEN}Already OK:${RST}       %4d\n" "$SKIPPED_OK"
printf "    ${CYAN}From cache:${RST}       %4d\n" "$SKIPPED_CACHED"
printf "    ${GRAY}No cover:${RST}         %4d\n" "$NO_COVER"
printf "    ${DIM}-------------------------${RST}\n"
printf "    ${WHITE}Total processed:${RST}  %4d\n" "$CURRENT"

echo
if (( FIXED > 0 )); then
  printf "  ${BOLD}${WHITE}Complete!${RST} ${GREEN}%d covers optimized for HiBY.${RST}\n\n" "$FIXED"
else
  printf "  ${BOLD}${WHITE}Complete!${RST} ${GRAY}All covers are already optimized.${RST}\n\n"
fi
