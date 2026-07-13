#!/usr/bin/env bash
#
# Inject or clear packet loss on the loopback, for the live loss demo. Needs
# root because tc does:   wsl -d Ubuntu-22.04 -u root bash dashboard/loss.sh on
#
# Watch the dashboard's "Gói mất · RTP" counter climb while this is on, and the
# video tile break up -- then clear it and watch the picture heal at the next
# keyframe. This is the same instrument (jitterbuffer num-lost) the receiver
# reports; the decoder's own "corrupt" flag stays 0, because it conceals loss in
# silence (results/packet-loss.md).
#
set -uo pipefail
DEV="${IFACE:-lo}"

if [ "$(id -u)" -ne 0 ]; then
  echo "tc needs root: wsl -d Ubuntu-22.04 -u root bash $0 ${*:-on}" >&2
  exit 1
fi

case "${1:-on}" in
  on)
    tc qdisc del dev "$DEV" root 2>/dev/null || true
    tc qdisc add dev "$DEV" root netem loss "${2:-10%}"
    echo "packet loss ${2:-10%} ON  (dev=$DEV)"
    ;;
  off)
    tc qdisc del dev "$DEV" root 2>/dev/null || true
    echo "packet loss OFF (dev=$DEV)"
    ;;
  *)
    echo "usage: loss.sh on [pct] | off" >&2; exit 1 ;;
esac
