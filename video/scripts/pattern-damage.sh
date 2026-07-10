#!/usr/bin/env bash
#
# Does the test pattern decide whether packet loss is visible?
#
#   wsl -d Ubuntu-22.04 -u root bash scripts/pattern-damage.sh
#
# This exists because of a wrong conclusion. The first pixel experiment used
# pattern=smpte, saw no damage, and blamed the stillness of the picture:
# concealment copies the block from the previous picture, and on a still image
# that block is correct. The experiment was then "rerun with motion" using
# pattern=pinwheel -- which, measured here, does not move at all.
#
# So the rerun changed something, but not motion. This script measures both
# halves for each pattern, on the same frozen bitstream and the same loss, and
# prints them next to each other:
#
#   moving%   share of pixels changing by more than 8 of 255 between frames
#   detail    mean absolute horizontal gradient of the first frame
#   altered   pictures differing from the reference at all
#   median    median mean-absolute-difference over the altered pictures
#
# The answer is that `altered` barely depends on the pattern and the amplitude
# depends on it enormously. Loss damages every pattern; only some patterns show
# it.
#
# Two choices that are not arbitrary:
#
#   LOSS defaults to 0.15%, not 2%. At 2% this stream takes about one drop per
#   GOP, damage never stops, and the 300 pictures collapse into a single episode
#   -- there is nothing left to count. Rare, separable losses are what make
#   "every episode ends at a keyframe" a testable statement.
#
#   The amplitude column is a median, not a maximum. The maximum is decided by
#   whether one keyframe slice happened to be hit, and it swings by 6x between
#   two runs of the same command. It looked like a result. It was a coin toss.
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/common.sh"

PICS="${PICS:-600}"
LOSS="${LOSS:-0.15%}"
W="${W:-/tmp/pattern-damage}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "tc needs root: wsl -d Ubuntu-22.04 -u root bash $0" >&2
  exit 1
fi

trap 'tc qdisc del dev lo root 2>/dev/null || true' EXIT
tc qdisc del dev lo root 2>/dev/null || true
rm -rf "$W"; mkdir -p "$W"

# ---- how much does this pattern move, and how detailed is it? ---------------
motion_of() {  # motion_of <pattern> [extra videotestsrc props]
  local pat="$1"; shift
  local d="$W/motion"; rm -rf "$d"; mkdir -p "$d"
  gst-launch-1.0 -q videotestsrc pattern="$pat" "$@" num-buffers=30 \
    ! video/x-raw,width=320,height=180,framerate=30/1,format=GRAY8 \
    ! multifilesink location="$d/f-%02d.gray" 2>/dev/null
  python3 - "$d" <<'PY'
import sys, glob, statistics
fr = [open(f, 'rb').read() for f in sorted(glob.glob(sys.argv[1] + "/f-*.gray"))]
n = len(fr[0])
fracs = []
for i in range(1, len(fr)):
    a, b = fr[i-1], fr[i]
    fracs.append(100.0 * sum(1 for j in range(n) if abs(a[j]-b[j]) > 8) / n)
f0 = fr[0]
detail = sum(abs(f0[j]-f0[j-1]) for j in range(1, n)) / n
print(f"{statistics.mean(fracs):.1f} {detail:.1f}")
PY
  rm -rf "$d"
}

# ---- what does 2% loss do to it? -------------------------------------------
damage_of() {  # damage_of <label> <pattern> [extra]
  local label="$1" pat="$2" extra="${3:-}"
  local stream="$W/$label.h264"

  PATTERN="$pat" SRC_EXTRA="$extra" bash "$HERE/make-stream.sh" "$stream" "$PICS" >/dev/null

  tc qdisc del dev lo root 2>/dev/null || true
  STREAM="$stream" bash "$HERE/capture-frames.sh" "$W/$label-ref" "$PICS" >/dev/null 2>&1

  tc qdisc add dev lo root netem loss "$LOSS"
  STREAM="$stream" bash "$HERE/capture-frames.sh" "$W/$label-lossy" "$PICS" >/dev/null 2>&1
  local dropped; dropped="$(tc -s qdisc show dev lo | grep -oP 'dropped \K\d+')"
  tc qdisc del dev lo root 2>/dev/null || true

  # A capture that came up short shifts the last picture off a GOP boundary and
  # turns a perfectly good episode into one that "did not end at a keyframe".
  # Never let that pass silently -- it is indistinguishable from a real result.
  local nref nlossy
  nref="$(find "$W/$label-ref"   -name 'g-*.rgb' | wc -l)"
  nlossy="$(find "$W/$label-lossy" -name 'g-*.rgb' | wc -l)"
  if [[ "$nref" -ne "$PICS" || "$nlossy" -ne "$PICS" ]]; then
    echo "SHORT CAPTURE on $label: ref=$nref lossy=$nlossy, expected $PICS" >&2
  fi

  local out; out="$(bash "$HERE/frame-diff.sh" "$W/$label-ref" "$W/$label-lossy" "$KEY_INT_MAX" 2>&1)"
  local altered med idr
  altered="$(grep -oP 'pictures altered\s+: \K\d+' <<<"$out" || echo '?')"
  med="$(grep -oP 'damage amplitude\s+: median \K[0-9.]+' <<<"$out" || echo '?')"
  # first "ending exactly at an IDR" line is the threshold-free grouping
  idr="$(grep -oP 'ending exactly at an IDR: \K[0-9]+/[0-9]+' <<<"$out" | head -1 || echo '?')"

  local ratio
  ratio="$(bash "$HERE/gop-stats.sh" "$stream" 2>/dev/null | grep -oP 'IDR / P ratio\s+: \K[0-9.]+x' || echo '?')"

  rm -rf "$W/$label-ref" "$W/$label-lossy" "$stream"
  echo "$dropped $altered $med $idr $ratio"
}

echo "${PICS} pictures, netem loss ${LOSS}, GOP ${KEY_INT_MAX}, ${WIDTH}x${HEIGHT}@${FPS}"
echo
printf '%-30s %8s %7s %8s %10s %9s %9s %7s\n' \
  pattern moving% detail dropped altered median 'ends@IDR' 'IDR/P'
printf -- '---------------------------------------------------------------------------------------------\n'

row() {  # row <label> <pattern> [extra]
  local m; m="$(motion_of "$2" ${3:-})"
  local d; d="$(damage_of "$1" "$2" "${3:-}")"
  printf '%-30s %7s%% %7s %8s %6s/%-3s %9s %9s %7s\n' \
    "$2 ${3:-}" $(cut -d' ' -f1 <<<"$m") $(cut -d' ' -f2 <<<"$m") \
    $(cut -d' ' -f1 <<<"$d") $(cut -d' ' -f2 <<<"$d") "$PICS" \
    $(cut -d' ' -f3 <<<"$d") $(cut -d' ' -f4 <<<"$d") $(cut -d' ' -f5 <<<"$d")
}

row smpte     smpte
row pinwheel  pinwheel
row ball      ball       "motion=sweep"
row zoneplate zone-plate "kx2=20 ky2=20 kt2=1"

rm -rf "$W"
echo
echo "altered  = pictures differing from the reference at all (no threshold)"
echo "median   = median mean-absolute pixel difference over those, of 255"
echo "ends@IDR = damage episodes that stop exactly at a keyframe"
echo
echo "Loss damages every pattern. Only some patterns show it."
