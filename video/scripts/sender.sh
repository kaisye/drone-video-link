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

# smpte is fine for latency. For packet loss the pattern decides whether the
# damage can be seen at all -- not whether it happened. Measured at 0.15% loss
# over 600 pictures, median mean-absolute pixel error across the damaged
# pictures (of 255):
#
#   pinwheel   0.01     does not move at all
#   smpte      0.34
#   ball       0.58
#   zone-plate 4.22     73% of its pixels move between frames
#
# All four are damaged on 110-155 of those 600 pictures. Only the last one shows
# it. See results/packet-loss.md and scripts/pattern-damage.sh.
PATTERN="${PATTERN:-smpte}"

# Further videotestsrc properties, e.g. SRC_EXTRA="kx2=20 ky2=20 kt2=1" for the
# animated zone plate the demo clip uses.
SRC_EXTRA="${SRC_EXTRA:-}"

# Replaying a file instead of encoding live takes x264enc out of the experiment.
# It has to come out: two encodes of identical input differ bit for bit, so a
# clean run and a lossy run would not share a reference. See make-stream.sh.
STREAM="${STREAM:-}"

# A real, arbitrary video file (mp4/mov/mkv/...) for the dashboard demo -- as
# opposed to STREAM, which is a raw H.264 byte-stream for the measurement path.
# It is decoded live, normalised to WIDTH x HEIGHT @ FPS, and re-encoded, so the
# receiver's frame/fps counters mean the same thing they do for the test pattern.
# This deliberately does NOT touch the packet-loss experiment.
VIDEO="${VIDEO:-}"
# Loop the clip so the demo never runs dry. We loop by restarting the whole
# pipeline (fresh PTS from zero each pass) rather than looping inside it: an
# in-pipeline loop rewinds the timestamps, and udpsink sync=true then stalls on
# the backward jump. LOOP=0 plays the clip once.
LOOP="${LOOP:-1}"

# Optionally duplicate the RTP to a second UDP port, so a second consumer -- the
# dashboard's MJPEG preview pipeline -- can read the same stream without
# contending with the first receiver for the port. Empty = single sink, as
# before, so the measurement scripts are unaffected.
TEE_PORT="${TEE_PORT:-}"

case "$PROFILE" in
  tuned)   ENC="$ENC_TUNED" ;;
  default) ENC="$ENC_DEFAULT" ;;
  *)
    echo "unknown PROFILE: $PROFILE (expected 'tuned' or 'default')" >&2
    exit 1
    ;;
esac

if [[ "${QUIET:-0}" == "1" ]]; then GST_FLAG="-q"; else GST_FLAG="-v"; fi

if [[ -n "$VIDEO" ]]; then
  if [[ ! -f "$VIDEO" ]]; then
    echo "sender: VIDEO file not found: $VIDEO" >&2
    exit 1
  fi
  # decodebin picks the right demuxer + decoder for whatever container/codec the
  # file is. A container usually carries an audio track too; if we leave its pad
  # unlinked the demuxer errors the whole pipeline with "not-linked". So the audio
  # branch drains it into a fakesink (async=false so a file *without* audio still
  # reaches PLAYING). The caps filters -- audio/x-raw and video/x-raw -- are what
  # route each decoded stream to the right branch: without them both branches
  # begin with a caps-agnostic queue and gst-launch links the pads by order, which
  # can send the video into the fakesink and audio into the encoder. videoscale +
  # videorate then force our standard resolution and framerate before re-encoding.
  # The path is double-quoted inside the pipeline string so gst-launch keeps it
  # as one value even when it contains spaces: SRC is expanded unquoted below and
  # word-split, but gst-launch rejoins the tokens and honours the embedded quotes.
  VPATH="$(readlink -f "$VIDEO")"
  SRC="filesrc location=\"${VPATH}\" ! decodebin name=d
       d. ! audio/x-raw ! queue ! fakesink async=false sync=false
       d. ! video/x-raw ! queue ! videoconvert ! videoscale ! videorate !
       video/x-raw,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1 !
       videoconvert ! ${ENC}"
  echo "sender: real video ${VIDEO} -> ${HOST}:${PORT}" \
       "(${WIDTH}x${HEIGHT}@${FPS}, loop=${LOOP})" >&2
elif [[ -n "$STREAM" ]]; then
  # h264parse recovers access-unit boundaries and, given the framerate in caps,
  # stamps each one with a PTS. udpsink then paces on that PTS -- without it the
  # whole file leaves in a burst, netem's 1000-packet queue overflows, and the
  # experiment measures queue overflow instead of the loss rate we asked for.
  SRC="filesrc location=${STREAM} ! h264parse !
       video/x-h264,stream-format=byte-stream,alignment=au,framerate=${FPS}/1"
  echo "sender: replaying ${STREAM} -> ${HOST}:${PORT}" >&2
else
  SRC="videotestsrc is-live=true pattern=${PATTERN} ${SRC_EXTRA} num-buffers=${NUM_BUFFERS} !
       video/x-raw,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1 !
       timeoverlay halignment=left valignment=top !
       videoconvert ! ${ENC}"
  echo "sender: profile=${PROFILE} pattern=${PATTERN} ${SRC_EXTRA} -> ${HOST}:${PORT}" \
       "(${WIDTH}x${HEIGHT}@${FPS}, n=${NUM_BUFFERS})" >&2
fi

# config-interval=1 re-sends SPS/PPS every second. Without it a receiver that
# starts after the sender never learns the stream parameters and shows nothing.
if [[ -n "$TEE_PORT" ]]; then
  SINK="tee name=t \
        t. ! queue ! udpsink host=${HOST} port=${PORT} sync=true \
        t. ! queue ! udpsink host=${HOST} port=${TEE_PORT} sync=true"
  echo "sender: teeing RTP to ${PORT} and ${TEE_PORT}" >&2
else
  SINK="udpsink host=${HOST} port=${PORT} sync=true"
fi

PAY="rtph264pay config-interval=1 pt=${PT}"

if [[ -n "$VIDEO" && "$LOOP" == "1" ]]; then
  # Loop the clip by restarting the pipeline: each pass starts from PTS 0 with a
  # fresh sink, which sidesteps the backward-timestamp stall an in-pipeline loop
  # causes with sync=true. The seam costs one small jitterbuffer gap per pass.
  echo "sender: looping clip (restart per pass) -- Ctrl-C to stop" >&2
  while true; do
    gst-launch-1.0 "$GST_FLAG" ${SRC} ! ${PAY} ! ${SINK} || break
    sleep 0.2
  done
else
  exec gst-launch-1.0 "$GST_FLAG" ${SRC} ! ${PAY} ! ${SINK}
fi
