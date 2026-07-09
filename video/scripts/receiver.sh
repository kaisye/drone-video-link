#!/usr/bin/env bash
#
# Reference receiver built from gst-launch. This exists to understand the
# pipeline before implementing it in C++ (see ../src/receiver.cpp).
#
# Usage:
#   ./receiver.sh                  # low latency: jitterbuffer 0, sync off
#   PROFILE=default ./receiver.sh  # 200ms jitterbuffer, clock sync on
#   HEADLESS=1 ./receiver.sh       # no window; prints fps only (works over SSH/WSL)
#
set -euo pipefail
source "$(dirname "$0")/common.sh"

PROFILE="${PROFILE:-tuned}"
HEADLESS="${HEADLESS:-0}"

case "$PROFILE" in
  tuned)
    # latency=0: hand packets on immediately. Trades tolerance of network jitter
    # for responsiveness -- the right trade for FPV, the wrong one for Netflix.
    JITTER="rtpjitterbuffer latency=0"
    # sync=false: render on arrival instead of waiting for the buffer's PTS.
    # There is no audio to stay in sync with, so that wait is pure added delay.
    SYNC="sync=false"
    ;;
  default)
    JITTER="rtpjitterbuffer latency=200"
    SYNC="sync=true"
    ;;
  *)
    echo "unknown PROFILE: $PROFILE" >&2
    exit 1
    ;;
esac

if [[ "$HEADLESS" == "1" ]]; then
  SINK="fpsdisplaysink video-sink=fakesink text-overlay=false signal-fps-measurements=true ${SYNC}"
else
  SINK="fpsdisplaysink ${SYNC}"
fi

echo "receiver: profile=${PROFILE} headless=${HEADLESS} listening on :${PORT}" >&2

# udpsrc needs caps declared by hand: RTP headers carry a payload-type number,
# not a description of the format. The number 96 is meaningless without this
# out-of-band agreement -- in production SDP carries it.
exec gst-launch-1.0 -v \
  udpsrc port="${PORT}" caps="${RTP_CAPS}" ! \
  ${JITTER} ! \
  rtph264depay ! \
  avdec_h264 ! \
  videoconvert ! \
  ${SINK}
