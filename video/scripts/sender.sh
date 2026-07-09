#!/usr/bin/env bash
#
# Sender: simulated camera -> H.264 -> RTP -> UDP.
# Stands in for the companion computer (Jetson) on a real airframe.
#
# Usage:
#   ./sender.sh                 # tuned for low latency (default)
#   PROFILE=default ./sender.sh # untuned, for the latency comparison in T1.4
#
set -euo pipefail
source "$(dirname "$0")/common.sh"

PROFILE="${PROFILE:-tuned}"

case "$PROFILE" in
  tuned)
    # tune=zerolatency disables B-frames and lookahead: the encoder never waits
    # for a future frame before emitting the current one.
    ENC="x264enc tune=zerolatency speed-preset=ultrafast bitrate=${BITRATE} key-int-max=${KEY_INT_MAX}"
    ;;
  default)
    # x264enc defaults. B-frames and lookahead are on, so the encoder buffers
    # several frames before output. This is the baseline row of the latency table.
    ENC="x264enc bitrate=${BITRATE}"
    ;;
  *)
    echo "unknown PROFILE: $PROFILE (expected 'tuned' or 'default')" >&2
    exit 1
    ;;
esac

echo "sender: profile=${PROFILE} -> ${HOST}:${PORT} (${WIDTH}x${HEIGHT}@${FPS})" >&2

# config-interval=1 re-sends SPS/PPS every second. Without it a receiver that
# starts after the sender never learns the stream parameters and shows nothing.
exec gst-launch-1.0 -v \
  videotestsrc is-live=true pattern=smpte ! \
  "video/x-raw,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1" ! \
  timeoverlay halignment=left valignment=top ! \
  videoconvert ! \
  ${ENC} ! \
  rtph264pay config-interval=1 pt=${PT} ! \
  udpsink host="${HOST}" port="${PORT}"
