#!/usr/bin/env bash
#
# Dump every decoded picture, so corruption can be looked at rather than
# inferred. Whatever netem qdisc is on lo when this runs is what the stream goes
# through -- this script does not touch tc (see packet-loss.sh for that).
#
# Writes two things per run:
#   <outdir>/f-%04d.png    full-resolution picture, for the screenshots
#   <outdir>/g-%04d.rgb    the same picture at 320x180, raw RGB, for frame-diff.sh
#
# The raw copy exists because measuring damage needs arithmetic on pixels, and
# the difference between two runs is the only honest measure of it: videotestsrc
# is deterministic, so picture k of a clean run and picture k of a lossy run are
# the same image unless the network broke it.
#
# Usage:  PATTERN=ball ./capture-frames.sh <outdir> [num_pictures]
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/common.sh"

OUT="${1:?usage: capture-frames.sh <outdir> [num_pictures]}"
FRAMES="${2:-300}"

mkdir -p "$OUT"
rm -f "$OUT"/f-*.png "$OUT"/g-*.rgb "$OUT/sizes.csv"

# The capture pipeline must never be the bottleneck: a slow sink stalls udpsrc,
# the kernel socket buffer overflows, and we would be measuring our own PNG
# encoder instead of netem. Hence the enlarged socket buffer and the unbounded
# queues. The check that this worked is at the bottom: on a clean link the
# picture count must equal the number of pictures sent.
Q="queue max-size-buffers=0 max-size-bytes=0 max-size-time=0"

gst-launch-1.0 -q -e \
  udpsrc port="${PORT}" caps="${RTP_CAPS}" buffer-size=4194304 ! \
  rtpjitterbuffer latency=0 ! \
  rtph264depay ! \
  avdec_h264 ! \
  $Q ! tee name=t \
  t. ! $Q ! videoconvert ! "video/x-raw,format=RGB" ! \
       pngenc compression-level=1 ! multifilesink location="${OUT}/f-%04d.png" \
  t. ! $Q ! videoscale ! "video/x-raw,width=320,height=180" ! \
       videoconvert ! "video/x-raw,format=RGB" ! \
       multifilesink location="${OUT}/g-%04d.rgb" &
RX=$!

sleep 1
QUIET=1 NUM_BUFFERS="${FRAMES}" PATTERN="${PATTERN:-smpte}" STREAM="${STREAM:-}" \
  "$HERE/sender.sh" >/dev/null 2>&1 || true
sleep 2

kill -INT "$RX" 2>/dev/null || true
wait "$RX" 2>/dev/null || true

echo "index,bytes" >"$OUT/sizes.csv"
for f in "$OUT"/f-*.png; do
  idx="${f##*/f-}"; idx="${idx%.png}"
  printf '%d,%d\n' "$((10#$idx))" "$(stat -c%s "$f")" >>"$OUT/sizes.csv"
done

got=$(( $(wc -l <"$OUT/sizes.csv") - 1 ))
echo "captured ${got}/${FRAMES} pictures into ${OUT}  (${STREAM:-pattern=${PATTERN:-smpte}})"
[[ "$got" -eq "$FRAMES" ]] || echo "  note: capture is short of the count sent" >&2
