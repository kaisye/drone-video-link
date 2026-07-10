#!/usr/bin/env bash
#
# Sender: simulated camera -> H.264 -> RTP -> UDP.
# Stands in for the companion computer (Jetson) on a real airframe.
#
# Usage:
#   ./sender.sh                    # tuned for low latency (default), runs forever
#   PROFILE=default ./sender.sh    # untuned, for the latency comparison in T1.4
#   NUM_BUFFERS=300 ./sender.sh    # send exactly 300 frames, then stop
#   QUIET=1 ./sender.sh            # no per-element caps dump
#   PATTERN=ball ./sender.sh       # moving picture instead of the static bars
#   STREAM=x.h264 ./sender.sh      # replay a frozen bitstream, no encoder at all
#
set -euo pipefail
source "$(dirname "$0")/common.sh"

PROFILE="${PROFILE:-tuned}"

# -1 = never stop. A fixed count makes the packet-loss experiment reproducible:
# the receiver's frame total can then be compared against a number we chose.
NUM_BUFFERS="${NUM_BUFFERS:--1}"

# smpte is a still image. That is fine for latency, but it flatters the decoder
# during packet loss: concealment copies the missing block from the previous
# picture, which on a still image is the correct block. A real camera moves.
PATTERN="${PATTERN:-smpte}"

# Replaying a file instead of encoding live takes x264enc out of the experiment.
# It has to come out: two encodes of identical input differ bit for bit, so a
# clean run and a lossy run would not share a reference. See make-stream.sh.
STREAM="${STREAM:-}"

case "$PROFILE" in
  tuned)   ENC="$ENC_TUNED" ;;
  default) ENC="$ENC_DEFAULT" ;;
  *)
    echo "unknown PROFILE: $PROFILE (expected 'tuned' or 'default')" >&2
    exit 1
    ;;
esac

if [[ "${QUIET:-0}" == "1" ]]; then GST_FLAG="-q"; else GST_FLAG="-v"; fi

if [[ -n "$STREAM" ]]; then
  # h264parse recovers access-unit boundaries and, given the framerate in caps,
  # stamps each one with a PTS. udpsink then paces on that PTS -- without it the
  # whole file leaves in a burst, netem's 1000-packet queue overflows, and the
  # experiment measures queue overflow instead of the loss rate we asked for.
  SRC="filesrc location=${STREAM} ! h264parse !
       video/x-h264,stream-format=byte-stream,alignment=au,framerate=${FPS}/1"
  echo "sender: replaying ${STREAM} -> ${HOST}:${PORT}" >&2
else
  SRC="videotestsrc is-live=true pattern=${PATTERN} num-buffers=${NUM_BUFFERS} !
       video/x-raw,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1 !
       timeoverlay halignment=left valignment=top !
       videoconvert ! ${ENC}"
  echo "sender: profile=${PROFILE} pattern=${PATTERN} -> ${HOST}:${PORT}" \
       "(${WIDTH}x${HEIGHT}@${FPS}, n=${NUM_BUFFERS})" >&2
fi

# config-interval=1 re-sends SPS/PPS every second. Without it a receiver that
# starts after the sender never learns the stream parameters and shows nothing.
exec gst-launch-1.0 "$GST_FLAG" \
  ${SRC} ! \
  rtph264pay config-interval=1 pt=${PT} ! \
  udpsink host="${HOST}" port="${PORT}" sync=true
