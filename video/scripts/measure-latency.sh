#!/usr/bin/env bash
#
# Latency measurement with GStreamer's built-in tracer.
#
# The tracer only sees inside one pipeline, but the real system splits at UDP
# into two. So we measure the encode->decode chain in a single pipeline and drop
# the loopback hop: every knob under test (encoder tuning, jitter buffer depth,
# sink clock sync) lives in that chain, and loopback contributes tens of
# microseconds. What this yields is pipeline latency, NOT glass-to-glass.
#
# Records collected per run:
#   latency          videotestsrc src pad -> fakesink sink pad   (whole chain)
#   element-latency  time inside one element, sampled on its src pad
#
# A sink has no src pad, so there is no element-latency for fakesink and the
# cost of sync=true cannot be read directly. It is obtained by differencing the
# pipeline latency of two runs that differ only in that flag.
#
# The `trend` column is mean(last quarter) - mean(first quarter). A pipeline in
# steady state reads ~0. A large positive value means the encoder is slower than
# the frame rate and the backlog is growing: the latency is a queue, not a
# constant, and quoting a single number for it would be meaningless.
#
# Usage:  ./measure-latency.sh [num_buffers]
#
set -euo pipefail
source "$(dirname "$0")/common.sh"

RESULTS="$(cd "$(dirname "$0")/../results" && pwd)"
NUM_BUFFERS="${1:-150}"
WARMUP=15   # first frames include encoder ramp-up, plugin load and page faults

export GST_DEBUG_NO_COLOR=1

# Pipeline records carry `src-element-id`; element records carry `element-id`.
# Note that `element=` is a substring of `src-element=` and `sink-element=`,
# so the element pattern must be anchored on the record name.
pipeline_ns() {
  grep -oP 'latency, src-element-id=\(string\)0x.*?time=\(guint64\)\K\d+' "$1" \
    | tail -n +$((WARMUP + 1)) || true
}
element_ns() {
  grep -oP "element-latency, element-id=\(string\)0x[0-9a-f]+, element=\(string\)$2,.*?time=\(guint64\)\K\d+" "$1" \
    | tail -n +$((WARMUP + 1)) || true
}

# mean median p95, in ms. Input is arrival-ordered; sort only for the quantiles.
stats_ms() {
  local v; v="$(cat)"
  [[ -z "$v" ]] && { printf "n/a n/a n/a"; return; }
  local mean med p95
  mean=$(printf '%s\n' "$v" | awk '{s+=$1} END {printf "%.1f", s/NR/1e6}')
  med=$(printf '%s\n'  "$v" | sort -n | awk '{a[NR]=$1} END {printf "%.1f", a[int((NR+1)/2)]/1e6}')
  p95=$(printf '%s\n'  "$v" | sort -n | awk '{a[NR]=$1} END {printf "%.1f", a[int(NR*0.95)]/1e6}')
  printf "%s %s %s" "$mean" "$med" "$p95"
}

# mean(last quarter) - mean(first quarter), in ms. Arrival order matters here.
trend_ms() {
  local v; v="$(cat)"
  [[ -z "$v" ]] && { printf "n/a"; return; }
  printf '%s\n' "$v" | awk '
    { a[NR] = $1 }
    END {
      if (NR < 8) { printf "n/a"; exit }
      q = int(NR / 4)
      for (i = 1; i <= q; i++)        first += a[i]
      for (i = NR - q + 1; i <= NR; i++) last += a[i]
      printf "%+.1f", (last/q - first/q) / 1e6
    }'
}

run_case() {
  local name="$1" enc="$2" jit="$3" sync="$4"
  local log="$RESULTS/trace-${name}.log"

  GST_DEBUG="GST_TRACER:7" GST_TRACERS="latency(flags=pipeline+element)" \
  gst-launch-1.0 -q \
    videotestsrc is-live=true pattern=smpte num-buffers="$NUM_BUFFERS" ! \
    "video/x-raw,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1" ! \
    timeoverlay ! videoconvert ! \
    ${enc} ! \
    rtph264pay config-interval=1 pt=${PT} ! \
    rtpjitterbuffer latency="${jit}" ! \
    rtph264depay ! avdec_h264 ! videoconvert ! \
    fakesink sync="${sync}" \
    > "$log" 2>&1 || true

  local pipe_vals
  pipe_vals="$(pipeline_ns "$log")"

  printf "%-14s | %-18s | %8s | %14s | %14s\n" \
    "$name" \
    "$(printf '%s\n' "$pipe_vals" | stats_ms)" \
    "$(printf '%s\n' "$pipe_vals" | trend_ms)" \
    "$(element_ns "$log" x264enc0        | stats_ms | cut -d' ' -f1-2)" \
    "$(element_ns "$log" rtpjitterbuffer0 | stats_ms | cut -d' ' -f1-2)"
}

header() {
  printf "%-14s | %-18s | %8s | %14s | %14s\n" \
    "config" "pipeline mean/med/p95" "trend" "x264enc mn/md" "jitterbuf mn/md"
  printf -- "---------------+--------------------+----------+----------------+---------------\n"
}

# ENC_TUNED and ENC_DEFAULT come from common.sh. They are not repeated here: the
# configuration this script measures has to be the configuration sender.sh
# transmits, and two copies of a string drift the moment one of them is edited.

echo "num_buffers=${NUM_BUFFERS}  warmup=${WARMUP}  resolution=${WIDTH}x${HEIGHT}@${FPS}  (ms)"
echo
echo "### Table 1 -- the four configurations"
header
run_case "1-default"     "$ENC_DEFAULT" 200 true
run_case "2-zerolatency" "$ENC_TUNED"   200 true
run_case "3-jitter0"     "$ENC_TUNED"   0   true
run_case "4-sync-off"    "$ENC_TUNED"   0   false

echo
echo "### Table 2 -- which encoder knob costs the latency"
echo "(jitter=0 and sync=false held fixed; only the encoder line changes)"
header
run_case "e-plain"       "$ENC_DEFAULT"                        0 false
run_case "e-lookahead0"  "$ENC_DEFAULT rc-lookahead=0"         0 false
run_case "e-sliced"      "$ENC_DEFAULT sliced-threads=true"    0 false
run_case "e-ultrafast"   "$ENC_DEFAULT speed-preset=ultrafast" 0 false
run_case "e-zerolatency" "$ENC_DEFAULT tune=zerolatency"       0 false
run_case "e-both"        "$ENC_TUNED"                          0 false
