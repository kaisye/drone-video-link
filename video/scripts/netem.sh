#!/usr/bin/env bash
#
# Impair the loopback interface, so a stream that has never left the machine can
# be made to look like one that crossed a radio link.
#
# Needs root, because tc does:
#   wsl -d Ubuntu-22.04 -u root bash scripts/netem.sh on
#
# Usage:
#   ./netem.sh on                     # the default impairment, below
#   ./netem.sh on loss 5%             # anything netem accepts
#   ./netem.sh on loss 2% delay 20ms 5ms
#   ./netem.sh off
#   ./netem.sh status                 # and the kernel's drop count
#
# The default is `loss 2%` and nothing else, which is not the obvious choice --
# adding `delay 20ms 5ms` would model a radio more honestly. It is left out
# because the receiver runs `rtpjitterbuffer latency=0`, and under jitter that
# buffer discards three quarters of a *perfectly delivered* stream for arriving
# out of order: 67 pictures of 300, with the kernel dropping nothing at all
# (results/packet-loss.md). The picture freezes rather than breaks. Loss alone
# delivers every picture and corrupts the pixels, which is the failure this
# demo is about. Add the delay back to see the other one.
#
# What this does NOT model: netem's `loss X%` drops packets independently. A
# radio loses them in bursts, and twenty consecutive packets do far more damage
# than twenty scattered ones. `loss gemodel` would model that; nothing in this
# repo has measured it.
#
set -euo pipefail

IFACE="${IFACE:-lo}"
DEFAULT_NETEM="loss 2%"

# Print the comment block above, without hardcoding a line range that will rot
# the next time a line is added to it.
usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
  exit 1
}

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "tc needs root: wsl -d Ubuntu-22.04 -u root bash $0 $*" >&2
    exit 1
  fi
}

# Deleting a qdisc that is not there is an error, and it is never a problem.
netem_off() { tc qdisc del dev "$IFACE" root 2>/dev/null || true; }

case "${1:-}" in
  on)
    need_root "$@"
    shift
    args="${*:-$DEFAULT_NETEM}"
    netem_off                                   # idempotent: replace, don't stack
    tc qdisc add dev "$IFACE" root netem $args
    echo "netem ON  dev=$IFACE  $args"
    ;;

  off)
    need_root "$@"
    netem_off
    echo "netem OFF dev=$IFACE"
    ;;

  status)
    # -s adds the statistics line. `dropped` is the kernel's own count of what
    # netem ate: the one number in this project that cannot be argued with.
    tc -s qdisc show dev "$IFACE"
    ;;

  *) usage ;;
esac
