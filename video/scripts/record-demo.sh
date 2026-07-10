#!/usr/bin/env bash
#
# Records the demo clip: what the ground station actually sees while the link is
# impaired half way through, and how it recovers.
#
#   wsl -d Ubuntu-22.04 -u root bash scripts/record-demo.sh
#
# This records the *received, decoded video*, not a screen capture of two
# terminals. It is the stronger artifact: a screencast shows a window, this
# shows the pixels the decoder produced. Both endpoints and the recorder run
# headless, so it works over SSH and in WSL without WSLg.
#
# Timeline, 30 seconds at 30 fps:
#
#    0-10 s  clean link
#   10-20 s  netem `loss 2%`   -- bands rot and stay rotten for up to a second
#   20-30 s  clean again       -- each rotten stretch ends at the next keyframe
#
# The pattern is chosen so that the damage is visible. That is a real choice, not
# a cosmetic one: measured at 0.15% loss over 600 pictures, the median mean
# absolute pixel error over the damaged pictures is 0.01 of 255 for `pinwheel`
# and 4.22 for this animated zone plate, while both have well over a hundred
# damaged pictures. The first cut of this clip used pinwheel and showed a link
# in perfect health. See scripts/pattern-damage.sh.
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/common.sh"

OUT="${1:-$HERE/../../docs/assets/demo.mp4}"
SECONDS_CLEAN="${SECONDS_CLEAN:-10}"
SECONDS_LOSSY="${SECONDS_LOSSY:-10}"
SECONDS_AFTER="${SECONDS_AFTER:-10}"
NETEM="${NETEM:-loss 2%}"
PATTERN="${PATTERN:-zone-plate}"
SRC_EXTRA="${SRC_EXTRA:-kx2=20 ky2=20 kt2=1}"

# 960x540 keeps the slice bands legible while holding the clip near 5 MB. The
# re-encode is deliberately generous: at a low bitrate x264 would smear the very
# artefacts the clip exists to show.
OUT_WIDTH="${OUT_WIDTH:-960}"
OUT_HEIGHT="${OUT_HEIGHT:-540}"
OUT_KBPS="${OUT_KBPS:-1500}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "tc needs root: wsl -d Ubuntu-22.04 -u root bash $0" >&2
  exit 1
fi

total=$(( SECONDS_CLEAN + SECONDS_LOSSY + SECONDS_AFTER ))
frames=$(( total * FPS ))
mkdir -p "$(dirname "$OUT")"

cleanup() {
  tc qdisc del dev lo root 2>/dev/null || true
  kill "${rec:-0}" "${tx:-0}" 2>/dev/null || true
}
trap cleanup EXIT

echo "recording ${total}s -> $OUT"

# -e is what makes this a valid MP4: on SIGINT gst-launch sends EOS instead of
# dying, so mp4mux gets to write the moov atom. Without it the file is a
# headerless carcass that no player will open.
gst-launch-1.0 -q -e \
  udpsrc port="${PORT}" caps="${RTP_CAPS}" buffer-size=4194304 ! \
  rtpjitterbuffer latency=0 ! \
  rtph264depay ! \
  avdec_h264 ! \
  videoconvert ! videoscale ! \
  "video/x-raw,width=${OUT_WIDTH},height=${OUT_HEIGHT}" ! \
  videorate ! "video/x-raw,framerate=${FPS}/1" ! \
  x264enc bitrate="${OUT_KBPS}" speed-preset=medium key-int-max="${KEY_INT_MAX}" ! \
  h264parse ! mp4mux ! filesink location="$OUT" &
rec=$!

sleep 1   # let udpsrc bind before the first packet is on the wire

QUIET=1 PATTERN="$PATTERN" SRC_EXTRA="$SRC_EXTRA" NUM_BUFFERS="$frames" \
  bash "$HERE/sender.sh" >/dev/null 2>&1 &
tx=$!

sleep "$SECONDS_CLEAN"
bash "$HERE/netem.sh" on $NETEM
sleep "$SECONDS_LOSSY"

# Read the counter before deleting the qdisc: `tc qdisc del` takes the
# statistics with it, and the clip's provenance is this number.
dropped="$(tc -s qdisc show dev lo | grep -oP 'dropped \K\d+' || echo '?')"
bash "$HERE/netem.sh" off
sleep "$SECONDS_AFTER"

wait "$tx" 2>/dev/null || true
sleep 1                      # let the tail of the stream reach the recorder
kill -INT "$rec" 2>/dev/null || true
wait "$rec" 2>/dev/null || true
trap - EXIT
tc qdisc del dev lo root 2>/dev/null || true

echo
echo "kernel dropped ${dropped} packets in the impaired window"
ls -lh "$OUT" | awk '{print "clip: " $5 "  " $9}'
