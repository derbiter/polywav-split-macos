#!/usr/bin/env bash
# PolySplit (formerly polywav-split-macos)
# Split polywav/AIFF into per-channel mono WAVs with clean, sortable names.
# macOS 15.5 compatible (Bash 3.2 safe)
#
# Key features
# - Safe overwrite flow: backup, overwrite (typed confirm), new (auto-rename), resume
# - pan-based splitting for wide FFmpeg compatibility
# - Auto-matches source bit depth/format (16/24/32/f32/f64)
# - Channel labels from channels.txt (comments OK)
# - Non-interactive flags for CI, interactive prompts when flags omitted
# - Parallel processing with simple worker limiter
#
# Quick start
#   ./polysplit.sh --src "/in" --out "/out" --channels "/in/channels.txt" --layout flat --mode new --workers 4
#
set -euo pipefail

# ---------- Tool checks ----------
command -v ffmpeg >/dev/null || { echo "ffmpeg not found. Install with: brew install ffmpeg"; exit 1; }
command -v ffprobe >/dev/null || { echo "ffprobe not found. Install with: brew install ffmpeg"; exit 1; }
command -v sysctl  >/dev/null || true

# ---------- Defaults ----------
SRC_DIR=""
OUT_ROOT=""
CHANNELS_FILE=""
MODE="new"          # backup|overwrite|new|resume
YES="0"
DRYRUN="0"
PAD_WIDTH="2"
LAYOUT="flat"       # flat|folders
WORKERS="0"         # 0 -> auto
LOGLEVEL="info"

# ---------- Helpers ----------
timestamp() { date +%Y%m%d-%H%M%S; }
log() { printf '%s\n' "$*" >&2; }
die() { log "Error: $*"; exit 1; }
is_tty() { [ -t 0 ] && [ -t 1 ]; }

unique_dir() {
  local base="${1%/}"
  if [ ! -e "$base" ]; then echo "$base"; return; fi
  local n=2
  while [ -e "${base}_$n" ]; do n=$((n+1)); done
  echo "${base}_$n"
}

supports_wav_opt() { ffmpeg -hide_banner -h muxer=wav 2>&1 | grep -q "$1"; }
WAV_MUX_OPTS=()
supports_wav_opt "write_bext" && WAV_MUX_OPTS+=( -write_bext 1 )
supports_wav_opt "write_iXML" && WAV_MUX_OPTS+=( -write_iXML 1 )

sanitize() {
  echo "$1" \
  | tr '[:lower:]' '[:upper:]' \
  | sed -E 's/[[:space:]]+/_/g; s/[^A-Z0-9_+=.-]/_/g; s/_+/_/g; s/^_//; s/_$//'
}

get_channel_count() {
  ffprobe -v error -select_streams a:0 -show_entries stream=channels -of default=nw=1:nk=1 "$1"
}

detect_codec() {
  local f="$1" fmt bps codec
  fmt="$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_fmt -of default=nw=1:nk=1 "$f" || true)"
  bps="$(ffprobe -v error -select_streams a:0 -show_entries stream=bits_per_raw_sample -of default=nw=1:nk=1 "$f" || true)"
  if [ -z "${bps}" ] || [ "${bps}" = "N/A" ]; then
    bps="$(ffprobe -v error -select_streams a:0 -show_entries stream=bits_per_sample -of default=nw=1:nk=1 "$f" || true)"
  fi
  codec="pcm_s32le"
  case "${fmt}" in *s16*) codec="pcm_s16le";; *s24*) codec="pcm_s24le";; *s32*) codec="pcm_s32le";; *flt*) codec="pcm_f32le";; *dbl*) codec="pcm_f64le";; esac
  case "${bps}" in
    16) codec="pcm_s16le" ;;
    24) codec="pcm_s24le" ;;
    32) if echo "${fmt}" | grep -q flt; then codec="pcm_f32le"; else codec="pcm_s32le"; fi ;;
  esac
  echo "${codec}"
}

# Load channel labels into CHANNEL_NAMES[]
declare -a CHANNEL_NAMES
load_channel_names() {
  CHANNEL_NAMES=()
  [ -f "${CHANNELS_FILE}" ] || die "Missing channel list: ${CHANNELS_FILE}"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|\#*) continue ;; esac
    CHANNEL_NAMES+=( "$(sanitize "$line")" )
  done < "${CHANNELS_FILE}"
}

confirm_delete() {
  local target="$1"
  if [ "${YES}" = "1" ]; then return 0; fi
  if is_tty; then
    printf "About to DELETE permanently:\n  %s\nType 'DELETE' to confirm: " "${target}" >&2
    read -r ans || true
    [ "${ans}" = "DELETE" ] || die "Overwrite aborted."
  else
    die "Refusing to delete '${target}' without --yes in non-interactive mode."
  fi
}

safe_rm_rf() {
  local target="$1"
  [ -n "${target}" ] || die "rm -rf got empty path"
  [ "${target}" != "/" ] || die "Refusing to remove /"
  [ "${target}" != "." ] || die "Refusing to remove ."
  if [ -d "${target}" ]; then
    if [ "${DRYRUN}" = "1" ]; then
      log "[DRY-RUN] rm -rf \"${target}\""
    else
      rm -rf "${target}"
    fi
  fi
}

mkout() {
  local dir="$1"
  if [ "${DRYRUN}" = "1" ]; then log "[DRY-RUN] mkdir -p \"${dir}\""; else mkdir -p "${dir}"; fi
}

# ---------- Processing ----------
build_filter_complex() {
  local ch_count="$1" i lbl fc=""
  i=0
  while [ $i -lt $ch_count ]; do
    lbl=$(printf "ch%02d" "$i")
    [ -n "$fc" ] && fc="${fc};"
    fc="${fc}[0:a]pan=mono|c0=c${i}[${lbl}]"
    i=$((i+1))
  done
  echo "${fc}"
}

process_one() {
  local wav="$1" base stem outdir prefix ch_count codec fc i num chname lbl outfile
  base="$(basename "$wav")"; stem="${base%.*}"
  if [ "${LAYOUT}" = "folders" ]; then outdir="${OUT_ROOT}/${stem}"; prefix="${stem}"; else outdir="${OUT_ROOT}"; prefix="${stem}"; fi

  mkout "${outdir}"

  ch_count="$(get_channel_count "${wav}")"
  [ -n "${ch_count}" ] || { log "Cannot read channels for: ${base}"; return 0; }
  if [ ${#CHANNEL_NAMES[@]} -ne "${ch_count}" ]; then
    die "Channel name count (${#CHANNEL_NAMES[@]}) != source channels (${ch_count}) for: ${base}"
  fi

  codec="$(detect_codec "${wav}")"
  fc="$(build_filter_complex "${ch_count}")"

  # Construct ffmpeg args
  local args=( -hide_banner -nostdin -loglevel "${LOGLEVEL}" -y -threads 0 -i "${wav}" -filter_complex "${fc}" )
  local missing=0
  i=0
  while [ $i -lt $ch_count ]; do
    num=$(printf "%0${PAD_WIDTH}d" $((i+1)))
    chname="${CHANNEL_NAMES[$i]}"
    lbl=$(printf "ch%02d" "$i")
    if [ "${LAYOUT}" = "folders" ]; then
      outfile="${outdir}/${num}_${chname}_${prefix}.wav"
    else
      outfile="${outdir}/${prefix}_${num}_${chname}.wav"
    fi
    if [ -s "${outfile}" ] && [ "${MODE}" = "resume" ]; then
      i=$((i+1)); continue
    fi
    missing=$((missing+1))
    if [ "${DRYRUN}" = "1" ]; then
      log "[DRY-RUN] would write: ${outfile}"
    else
      args+=( -map "[${lbl}]" -c:a "${codec}" -map_metadata 0 "${WAV_MUX_OPTS[@]}" "${outfile}" )
    fi
    i=$((i+1))
  done

  if [ "${DRYRUN}" = "1" ]; then
    log "[DRY-RUN] ffmpeg (pan split) -> ${outdir}"
    return 0
  fi

  if [ $missing -eq 0 ]; then
    log "[${stem}] nothing to do."
    return 0
  fi

  ffmpeg "${args[@]}"
}

# ---------- Arg parsing ----------
print_help() {
  cat <<EOF
PolySplit - Split polywav files into labeled mono WAVs.

Required (if not provided interactively):
  --src PATH            Source root to scan for .wav/.aif/.aiff
  --out PATH            Output root (per-file folders created when --layout folders)
  --channels PATH       Channel labels file

Options:
  --layout L            flat (default) or folders
  --mode M              backup | overwrite | new (default) | resume
  --workers N           files to process in parallel (default: auto from CPU)
  --yes                 Skip destructive prompts (required for non-interactive overwrite)
  --dry-run             Print planned actions without writing
  --pad N               Zero pad width (default: 2)
  --help                Show this help

Examples:
  ./polysplit.sh --src "/in" --out "/out" --channels "/in/channels.txt"
  ./polysplit.sh --src "/in" --out "/out" --channels "./channels.txt" --mode overwrite --yes
  ./polysplit.sh --src "/in" --out "/out" --channels "./channels.txt" --mode resume --layout folders --workers 4
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --src) SRC_DIR="${2-}"; shift 2 ;;
    --out) OUT_ROOT="${2-}"; shift 2 ;;
    --channels) CHANNELS_FILE="${2-}"; shift 2 ;;
    --layout) LAYOUT="${2-}"; shift 2 ;;
    --mode) MODE="${2-}"; shift 2 ;;
    --workers) WORKERS="${2-}"; shift 2 ;;
    --yes) YES="1"; shift ;;
    --dry-run) DRYRUN="1"; shift ;;
    --pad) PAD_WIDTH="${2-}"; shift 2 ;;
    --help|-h) print_help; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# Interactive fallbacks
if [ -z "${SRC_DIR}" ]; then
  echo "Enter the source directory containing your polywavs:"; read -r SRC_DIR
fi
[ -d "${SRC_DIR}" ] || die "Source not found: ${SRC_DIR}"

if [ -z "${OUT_ROOT}" ]; then
  SRC_PARENT="$(cd "${SRC_DIR}/.." && pwd)"
  OUT_ROOT="${SRC_PARENT}/polywav_split_$(date +%Y-%m-%d)"
fi

# Conflict policy for OUT_ROOT (top-level only)
if [ -e "${OUT_ROOT}" ]; then
  case "${MODE}" in
    backup)
      BACKUP="${OUT_ROOT}__backup_$(timestamp)"
      log "Moving existing directory to: ${BACKUP}"; [ "${DRYRUN}" = "1" ] || mv "${OUT_ROOT}" "${BACKUP}"
      ;;
    overwrite)
      confirm_delete "${OUT_ROOT}"
      safe_rm_rf "${OUT_ROOT}"
      ;;
    resume)
      # keep as-is
      ;;
    new|"" )
      OUT_ROOT="$(unique_dir "${OUT_ROOT}")"
      log "Using new directory: ${OUT_ROOT}"
      ;;
    *)
      die "Unknown --mode '${MODE}'"
      ;;
  esac
fi

mkout "${OUT_ROOT}"

# Channels file
if [ -z "${CHANNELS_FILE}" ]; then
  if [ -f "./channels.txt" ]; then CHANNELS_FILE="./channels.txt"
  elif [ -f "${SRC_DIR}/channels.txt" ]; then CHANNELS_FILE="${SRC_DIR}/channels.txt"
  else die "--channels is required (channels.txt not found)"
  fi
fi
load_channel_names

# Layout sanity
case "${LAYOUT}" in flat|folders) ;; *) log "Unknown --layout '${LAYOUT}', using 'flat'"; LAYOUT="flat";; esac

# Workers default
if [ "${WORKERS}" = "0" ]; then
  CPU="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  WORKERS=$(( CPU / 2 ))
  [ "${WORKERS}" -lt 1 ] && WORKERS=1
  [ "${WORKERS}" -gt 8 ] && WORKERS=8
fi

log "Source:   ${SRC_DIR}"
log "Output:   ${OUT_ROOT}"
log "Layout:   ${LAYOUT}"
log "Mode:     ${MODE}"
log "Workers:  ${WORKERS}"
log "Channels: ${#CHANNEL_NAMES[@]}"

# ---------- Scan and enqueue ----------
pids=()
while IFS= read -r -d '' wav; do
  (
    process_one "${wav}"
  ) &
  pids+=( $! )
  # throttle to WORKERS
  while :; do
    running="$(jobs -pr | wc -l | tr -d ' ')"
    [ "${running}" -lt "${WORKERS}" ] && break
    sleep 0.2
  done
done < <(find "${SRC_DIR}" -type f \( -iname "*.wav" -o -iname "*.aif" -o -iname "*.aiff" \) -print0)

# wait for all
wait

log "Done."
