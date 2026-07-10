#!/usr/bin/env bash
#
# T1.5 -- what packet loss does to an H.264 stream.
#
# Needs root, because tc does:   wsl -d Ubuntu-22.04 -u root bash packet-loss.sh
#
# Two independent instruments, because one counter is never enough:
#
#   tc -s qdisc     what the kernel actually threw away. Ground truth.
#   jitterbuffer    `stats`, read by the C++ receiver at shutdown. The last
#                   element that sees RTP sequence numbers.
#
# On a plain lossy link the two agree to the packet. Under reordering they do
# not: `num-lost` climbs to 3680 while 4541 packets are pushed and every picture
# decodes. So num-lost counts *gap detections*, not undelivered packets, and the
# `net drop` column is the one to read. This disagreement is the reason both
# columns are printed instead of the prettier one.
#
# What is NOT an instrument, though it looks like one: the buffer flags. Neither
# DISCONT nor CORRUPTED is set on a decoded picture that lost slices -- see the
# `corrupt` column, which stays 0 up to 20% loss. avdec_h264 conceals in silence.
#
# Table 1 -- impairment vs. delivery, concealing (the default failure mode).
# Table 2 -- conceal vs. drop-until-keyframe, which is where the GOP shows up.
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/common.sh"

RECEIVER="$HERE/../build/receiver"
RESULTS="$HERE/../results"
FRAMES="${FRAMES:-300}"

# Table 2's last row needs loss events that do not overlap inside one GOP, so it
# runs long and lossless enough for each event to be countable on its own.
FRAMES_RARE="${FRAMES_RARE:-900}"
LOSS_RARE="${LOSS_RARE:-0.1%}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "tc needs root: wsl -d Ubuntu-22.04 -u root bash $0" >&2
  exit 1
fi
if [[ ! -x "$RECEIVER" ]]; then
  echo "receiver not built: cmake -B build && cmake --build build" >&2
  exit 1
fi

mkdir -p "$RESULTS"

netem_off() { tc qdisc del dev lo root 2>/dev/null || true; }
trap netem_off EXIT   # never leave the loopback impaired

# run <logname> <netem args> <jitter ms> <pictures> [extra receiver args...]
# Sets the qdisc, streams the pictures, stops, leaves the numbers in globals.
# netem args are given even for the clean case (`loss 0%`) so that the qdisc
# counters exist in every row and the rows stay comparable.
run() {
  local name="$1" netem_args="$2" jitter="$3" pics="$4"; shift 4
  local log="$RESULTS/loss-$name.log"

  netem_off
  tc qdisc add dev lo root netem $netem_args

  "$RECEIVER" --port "$PORT" --jitter-latency "$jitter" "$@" >"$log" 2>&1 &
  local rx=$!
  sleep 1
  QUIET=1 NUM_BUFFERS="$pics" "$HERE/sender.sh" >/dev/null 2>&1 || true
  sleep 2   # let the tail of the stream arrive before we stop counting
  kill -INT "$rx" 2>/dev/null || true
  wait "$rx" 2>/dev/null || true

  # Kernel's own count, read before the qdisc goes away. `Sent ... N pkt` is what
  # got through; `dropped` is what netem ate. Both cover all loopback traffic,
  # but the machine is idle and the stream is thousands of packets.
  local stat; stat="$(tc -s qdisc show dev lo)"
  netem_off

  R_NETPASS="$(grep -oP 'Sent \d+ bytes \K\d+' <<<"$stat" || echo 0)"
  R_NETDROP="$(grep -oP 'dropped \K\d+' <<<"$stat" || echo 0)"
  R_PUSHED="$(grep -oP 'num-pushed=\(guint64\)\K\d+' "$log" || echo 0)"
  R_LOST="$(grep -oP 'num-lost=\(guint64\)\K\d+' "$log" || echo 0)"
  R_LATE="$(grep -oP 'num-late=\(guint64\)\K\d+' "$log" || echo 0)"
  R_PICS="$(grep -oP '\[summary\] frames=\K\d+' "$log" || echo 0)"
  R_DISCONT="$(grep -oP '\[summary\].*discont=\K\d+' "$log" || echo 0)"
  R_CORRUPT="$(grep -oP '\[summary\].*corrupt=\K\d+' "$log" || echo 0)"

  local offered=$(( R_NETPASS + R_NETDROP ))
  R_NETPCT="0.00"
  [[ "$offered" -gt 0 ]] &&
    R_NETPCT="$(awk -v d="$R_NETDROP" -v o="$offered" 'BEGIN{printf "%.2f", 100*d/o}')"
}

echo "${WIDTH}x${HEIGHT}@${FPS}, key-int-max=${KEY_INT_MAX}, ${FRAMES} pictures per case"
echo
echo "Table 1 -- impairment vs. delivery.  On loss the decoder conceals."
echo
echo '| case        | netem                  | jbuf | net drop | net % | rtp pushed | jb lost | jb late | pictures | discont | corrupt |'
echo '|-------------|------------------------|------|----------|-------|------------|---------|---------|----------|---------|---------|'

row() {  # row <label> <netem> <jitter>
  run "$1" "$2" "$3" "$FRAMES"
  printf '| %-11s | %-22s | %4s | %8d | %5s | %10d | %7d | %7d | %8d | %7d | %7d |\n' \
    "$1" "$2" "$3" "$R_NETDROP" "$R_NETPCT" "$R_PUSHED" "$R_LOST" "$R_LATE" \
    "$R_PICS" "$R_DISCONT" "$R_CORRUPT"
}

row clean       "loss 0%"                0
row loss2       "loss 2%"                0
row loss2+jit   "loss 2% delay 20ms 5ms" 0
row loss2+jit+b "loss 2% delay 20ms 5ms" 200

echo
echo "Table 2 -- what one lost packet costs, by failure mode"
echo
echo '| on loss            | netem  | pics sent | net drop | delivered | never shown | lost per event |'
echo '|--------------------|--------|-----------|----------|-----------|-------------|----------------|'

mode_row() {  # mode_row <label> <logname> <netem> <pics> [extra receiver args...]
  local label="$1" name="$2" netem="$3" pics="$4"; shift 4
  run "$name" "$netem" 0 "$pics" "$@"
  local missing=$(( pics - R_PICS ))
  local per="n/a"
  # Only meaningful when losses are rare enough to sit in separate GOPs: at 2%
  # several land in one GOP and the recoveries merge.
  [[ "$R_NETDROP" -gt 0 ]] &&
    per="$(awk -v m="$missing" -v l="$R_NETDROP" 'BEGIN{printf "%.1f", m/l}')"
  printf '| %-18s | %-6s | %9d | %8d | %9d | %11d | %14s |\n' \
    "$label" "$netem" "$pics" "$R_NETDROP" "$R_PICS" "$missing" "$per"
}

mode_row "conceal"           loss2-conceal "loss 2%"      "$FRAMES"
mode_row "drop until IDR"    loss2-waitkey "loss 2%"      "$FRAMES"      --wait-for-keyframe
mode_row "drop until IDR"    rare-waitkey  "loss $LOSS_RARE" "$FRAMES_RARE" --wait-for-keyframe

echo
echo "GOP is ${KEY_INT_MAX} pictures. A loss at picture k costs the ${KEY_INT_MAX}-k pictures up"
echo "to the next IDR, which looks like $(( (KEY_INT_MAX + 1) / 2 )) pictures for one isolated loss. That"
echo "number is wrong: loss is uniform over *packets*, not pictures, and the keyframe"
echo "holds 15% of the packets. gop-stats.sh weights by the real packet layout and"
echo "gets 17.6; the measured mean is 24.1. See results/packet-loss.md."
echo
echo "raw receiver logs: $RESULTS/loss-*.log"
