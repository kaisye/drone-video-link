#!/usr/bin/env bash
#
# Drives the netem timeline for the demo recording, so the interesting moment
# happens at a known second instead of whenever someone finishes typing.
#
# Run it in a third terminal while sender and receiver sit side by side:
#
#   term 1:  PATTERN=zone-plate SRC_EXTRA="kx2=20 ky2=20 kt2=1" ./scripts/sender.sh
#   term 2:  ./scripts/receiver.sh
#   term 3:  wsl -d Ubuntu-22.04 -u root bash scripts/demo.sh
#
# Timeline, 45 seconds:
#
#   0-15 s   clean link
#  15-30 s   netem on, `loss 2%`   -- horizontal bands rot and stay rotten,
#                                     because a P picture copies the wrong
#                                     block forward unchanged
#  30-45 s   netem off             -- the picture repairs itself at the next
#                                     keyframe, so within 1000 ms (GOP is 30
#                                     pictures at 30 fps), not immediately
#
# The pattern decides whether the damage can be *seen*, not whether it happened.
# At 0.15% loss every pattern tested has 110-155 of its 600 pictures altered,
# while the median error ranges from 0.01 of 255 (pinwheel) to 4.22 (the animated
# zone plate). Run this with the default `smpte` and the link will look perfectly
# healthy while it is losing packets. See scripts/pattern-damage.sh.
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

CLEAN_S="${CLEAN_S:-15}"     # before the impairment
LOSSY_S="${LOSSY_S:-15}"     # with it
RECOVER_S="${RECOVER_S:-15}" # after it
NETEM="${NETEM:-loss 2%}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "tc needs root: wsl -d Ubuntu-22.04 -u root bash $0" >&2
  exit 1
fi

# Never leave the loopback impaired, whatever happens -- including Ctrl-C.
trap 'bash "$HERE/netem.sh" off >/dev/null 2>&1 || true' EXIT

countdown() {  # countdown <seconds> <label>
  local n="$1" label="$2"
  while [[ "$n" -gt 0 ]]; do
    printf '\r  %-28s %2ds ' "$label" "$n"
    sleep 1
    n=$((n - 1))
  done
  printf '\r  %-28s done\n' "$label"
}

echo
countdown "$CLEAN_S" "clean link"

bash "$HERE/netem.sh" on $NETEM
countdown "$LOSSY_S" "impaired: $NETEM"

# Read the drop count while the qdisc still exists. Deleting it takes the
# counters with it, so `netem.sh status` after `netem.sh off` reports nothing.
dropped="$(tc -s qdisc show dev lo | grep -oP 'dropped \K\d+' || echo '?')"

bash "$HERE/netem.sh" off
countdown "$RECOVER_S" "recovering"

echo
echo "kernel dropped ${dropped} packets during the impaired window."
echo "Count the pictures the receiver reports: at this loss rate it will have"
echo "decoded all of them. The damage is in the pixels, not in the count --"
echo "which is the whole point of results/packet-loss.md."
