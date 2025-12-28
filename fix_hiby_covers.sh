set -euo pipefail

REQUIRED_CMDS=(ffmpeg metaflac convert wslpath identify mktemp)
REQUIRED_PKGS=(ffmpeg flac imagemagick)

err() {
  echo "Error: $*" >&2
  exit 1
}

info() {
  echo "→ $*"
}

check_command() {
  command -v "$1" >/dev/null 2>&1
}

if [[ $# -ne 1 ]]; then
  echo "Usage:"
  echo "  fix_hiby_covers.sh <folder>"
  echo
  echo "Examples:"
  echo "  fix_hiby_covers.sh \"C:\\Users\\(username)\\Music\""
  echo "  fix_hiby_covers.sh /mnt/d/FLAC"
  exit 1
fi

INPUT="$1"

if [[ "$INPUT" =~ ^[A-Za-z]:\\ ]]; then
  ROOT="$(wslpath "$INPUT")"
else
  ROOT="$INPUT"
fi

[[ -d "$ROOT" ]] || err "'$ROOT' is not a directory"


info "Checking dependencies..."

MISSING_PKGS=()

for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! check_command "$cmd"; then
    case "$cmd" in
      metaflac) MISSING_PKGS+=(flac) ;;
      convert|identify) MISSING_PKGS+=(imagemagick) ;;
      mktemp) MISSING_PKGS+=(coreutils) ;;
      *) MISSING_PKGS+=("$cmd") ;;
    esac
  fi
done

MISSING_PKGS=($(printf "%s\n" "${MISSING_PKGS[@]}" | sort -u))

if (( ${#MISSING_PKGS[@]} > 0 )); then
  info "Installing missing packages: ${MISSING_PKGS[*]}"
  sudo apt update
  sudo apt install -y "${MISSING_PKGS[@]}"
else
  info "All dependencies present."
fi

if command -v nproc >/dev/null 2>&1; then
  MAX_JOBS="$(nproc)"
else
  MAX_JOBS=1
fi


process_file() {
  f="$1"

  DIR="$(dirname "$f")"
  TMP_BASE="$DIR/.hiby_tmp"
  mkdir -p "$TMP_BASE"

  TMPDIR="$(mktemp -d "$TMP_BASE/tmp.XXXXXX")"
  trap 'rm -rf "$TMPDIR"; rmdir "$TMP_BASE" 2>/dev/null || true' EXIT

  TMP_COVER="$TMPDIR/cover_tmp.jpg"
  FIXED_COVER="$TMPDIR/cover_fixed.jpg"

# get current artwork
  if ! ffmpeg -y -i "$f" -an -frames:v 1 "$TMP_COVER" 2>/dev/null; then
    if ! metaflac --export-picture-to="$TMP_COVER" "$f" 2>/dev/null; then
      rm -f "$TMP_COVER"
      return
    fi
  fi

  local INTERLACE="unknown"
  if INTERLACE="$(identify -quiet -format '%[interlace]' "$TMP_COVER" 2>/dev/null)"; then
    INTERLACE="${INTERLACE,,}"
  fi

  echo "Fixing: $f (interlace: $INTERLACE)"

  # convert to baseline JPEG
  convert "$TMP_COVER" \
    -resize 1000x1000\> \
    -interlace none \
    -strip \
    "$FIXED_COVER"

  metaflac --remove --block-type=PICTURE "$f"
  metaflac --import-picture-from="$FIXED_COVER" "$f"

  rm -f "$TMP_COVER" "$FIXED_COVER"
}

export -f process_file

info "Scanning:"
echo "  $ROOT"
echo "Using $MAX_JOBS parallel jobs"
echo

find "$ROOT" -type f -iname "*.flac" -print0 |
  xargs -0 -n 1 -P "$MAX_JOBS" bash -c 'process_file "$@"' _

info "All done."