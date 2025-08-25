#!/usr/bin/env bash
# polywav-split-macos.sh
# Split polywav files into per-channel mono WAVs with clean, sortable names.
# macOS 15.5 compatible (Bash 3.2 safe)

set -euo pipefail

# CONFIG
SRC_DIR="/Volumes/AUDIO/recovery6_001_freespace_paranoid_bf_bs32768.1"
OUT_ROOT="/Volumes/AUDIO/polywav_split_8-25-25"
GLOBAL_CHANNELS_FILE="$SRC_DIR/channels.txt"   # applies to ALL polywavs in SRC_DIR
PAD_WIDTH=2                                    # 2 => 01,02,... for stable sort

command -v ffmpeg >/dev/null || { echo "ffmpeg not found. Install with: brew install ffmpeg"; exit 1; }
command -v ffprobe >/dev/null || { echo "ffprobe not found. Install with: brew install ffmpeg"; exit 1; }

mkdir -p "$OUT_ROOT"

# Uppercase, spaces -> underscores, strip odd chars
sanitize() {
  echo "$1" \
  | tr '[:lower:]' '[:upper:]' \
  | sed -E 's/[[:space:]]+/_/g; s/[^A-Z0-9_+=.-]/_/g; s/_+/_/g; s/^_//; s/_$//'
}

# Return channel count for first audio stream
get_channel_count() {
  ffprobe -v error -select_streams a:0 -show_entries stream=channels \
          -of default=nw=1:nk=1 "$1"
}

# Detect best-fit WAV codec to match source bit depth / format
detect_codec() {
  f="$1"
  fmt="$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_fmt -of default=nw=1:nk=1 "$f" || true)"
  bps="$(ffprobe -v error -select_streams a:0 -show_entries stream=bits_per_raw_sample -of default=nw=1:nk=1 "$f" || true)"
  if [ -z "$bps" ] || [ "$bps" = "N/A" ]; then
    bps="$(ffprobe -v error -select_streams a:0 -show_entries stream=bits_per_sample -of default=nw=1:nk=1 "$f" || true)"
  fi

  codec="pcm_s32le"  # default
  case "$fmt" in
    *s16*) codec="pcm_s16le" ;;
    *s24*) codec="pcm_s24le" ;;
    *s32*) codec="pcm_s32le" ;;
    *flt*) codec="pcm_f32le" ;;  # 32-bit float
    *dbl*) codec="pcm_f64le" ;;  # 64-bit float
  esac

  case "$bps" in
    16) codec="pcm_s16le" ;;
    24) codec="pcm_s24le" ;;
    32) if echo "$fmt" | grep -q flt; then codec="pcm_f32le"; else codec="pcm_s32le"; fi ;;
  esac

  echo "$codec"
}

# Load and sanitize channel names from the global file
load_channel_names() {
  CHANNEL_NAMES=()
  if [ ! -f "$GLOBAL_CHANNELS_FILE" ]; then
    echo "Missing channel list: $GLOBAL_CHANNELS_FILE"
    exit 1
  fi

  # Bash 3.2-safe read loop, skip blank and comment lines, strip CR
  while IFS= read -r line || [ -n "$line" ]; do
    # strip trailing CR if present
    line="${line%$'\r'}"
    # skip blank and comments
    case "$line" in
      ''|\#*) continue ;;
    esac
    CHANNEL_NAMES+=( "$(sanitize "$line")" )
  done < "$GLOBAL_CHANNELS_FILE"
}

load_channel_names

# Walk all WAV/AIFF files in source
# macOS/BSD find supports -print0
find "$SRC_DIR" -type f \( -iname "*.wav" -o -iname "*.aif" -o -iname "*.aiff" \) -print0 | \
while IFS= read -r -d '' wav; do
  base="$(basename "$wav")"
  stem="${base%.*}"
  outdir="$OUT_ROOT/$stem"
  mkdir -p "$outdir"

  ch_count="$(get_channel_count "$wav")"
  if [ -z "$ch_count" ]; then
    echo "Could not determine channel count for: $base" >&2
    continue
  fi

  # Strict check to prevent mislabeling
  if [ ${#CHANNEL_NAMES[@]} -ne "$ch_count" ]; then
    echo "Channel name count (${#CHANNEL_NAMES[@]}) does not match source channel count ($ch_count) for: $base" >&2
    echo "Update $GLOBAL_CHANNELS_FILE to have exactly $ch_count non-comment lines." >&2
    exit 2
  fi

  codec="$(detect_codec "$wav")"

  # Build ffmpeg args: one mapping per channel, with metadata and wav mux opts
  ARGS=()
  i=0
  while [ $i -lt $ch_count ]; do
    num=$(printf "%0${PAD_WIDTH}d" $((i+1)))
    chname="${CHANNEL_NAMES[$i]}"
    outfile="$outdir/${num}_${chname}_${stem}.wav"
    ARGS+=( -map_channel "0.0.$i" -c:a "$codec" -map_metadata 0 -write_bext 1 -write_iXML 1 "$outfile" )
    i=$((i+1))
  done

  echo "Splitting ($ch_count ch, $codec): $base -> $outdir"
  ffmpeg -hide_banner -nostdin -y -i "$wav" "${ARGS[@]}"

done

