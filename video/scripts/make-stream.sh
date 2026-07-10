#!/usr/bin/env bash
#
# Encode once, to a file. Everything in the packet-loss experiment then replays
# this one bitstream.
#
# The reason is that x264enc is not bit-reproducible: encoding the same
# deterministic videotestsrc input twice gives two different files (verified by
# md5). Comparing a clean run against a lossy run would therefore compare two
# different encodes, and every pixel would differ before a single packet was
# dropped. Freezing the bitstream removes the encoder from the experiment, which
# is exactly where it belongs -- the subject here is the network.
#
# Usage:  PATTERN=ball ./make-stream.sh <out.h264> [pictures]
#         PATTERN=zone-plate SRC_EXTRA="kx2=20 ky2=20 kt2=1" ./make-stream.sh out.h264
#
# SRC_EXTRA passes further videotestsrc properties. It exists because the
# patterns that are worth testing are the ones that move, and the only
# videotestsrc pattern whose whole frame moves needs three parameters to say so.
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/common.sh"

OUT="${1:?usage: make-stream.sh <out.h264> [pictures]}"
FRAMES="${2:-300}"
PATTERN="${PATTERN:-smpte}"
SRC_EXTRA="${SRC_EXTRA:-}"

mkdir -p "$(dirname "$OUT")"

# is-live=false: encode as fast as the CPU allows, there is no network yet.
gst-launch-1.0 -q \
  videotestsrc is-live=false pattern="${PATTERN}" ${SRC_EXTRA} num-buffers="${FRAMES}" ! \
  "video/x-raw,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1" ! \
  timeoverlay halignment=left valignment=top ! \
  videoconvert ! \
  ${ENC_TUNED} ! \
  h264parse ! "video/x-h264,stream-format=byte-stream,alignment=au" ! \
  filesink location="${OUT}"

echo "wrote ${OUT}: $(stat -c%s "$OUT") bytes, ${FRAMES} pictures, pattern=${PATTERN} ${SRC_EXTRA}"
