#!/usr/bin/env bash
#
# Report the GOP structure of an Annex-B H.264 file.
#
# The packet-loss write-up claims corruption survives until the next keyframe,
# and that the wait is about one second. Both halves depend on the encoder
# really emitting an IDR every 30 pictures. `key-int-max=30` is a request, not a
# guarantee -- x264 may insert extra keyframes on scene cuts. So measure it, and
# measure it on the same file the sender transmits (see make-stream.sh).
#
# Usage:  ./gop-stats.sh <stream.h264> [loss_fraction]
#
# Given a loss fraction (e.g. 0.0021), it also simulates that loss against this
# stream's real packet layout and predicts how much of a GOP gets damaged. That
# prediction is what results/packet-loss.md checks the measurement against.
#
set -euo pipefail
source "$(dirname "$0")/common.sh"

STREAM="${1:?usage: gop-stats.sh <stream.h264> [loss_fraction]}"
LOSS="${2:-0}"
[[ -f "$STREAM" ]] || { echo "no such file: $STREAM" >&2; exit 1; }

python3 - "$STREAM" "$FPS" "$LOSS" <<'PY'
import sys, random

data = open(sys.argv[1], 'rb').read()
fps = float(sys.argv[2])
loss = float(sys.argv[3])

# Split on Annex-B start codes. Three-byte 00 00 01 is the general form; the
# four-byte version is the same code with one leading zero byte, which the scan
# below absorbs into the previous NAL's trailing bytes. Sizes are therefore
# accurate to +/-1 byte, which does not matter at this scale. Emulation
# prevention guarantees the payload never contains 00 00 01 by accident.
starts = []
i, n = 0, len(data)
while True:
    j = data.find(b'\x00\x00\x01', i)
    if j < 0:
        break
    starts.append(j + 3)
    i = j + 3
starts.append(n)

# A slice NAL is NOT a picture. tune=zerolatency turns on sliced threads, so one
# picture is cut into several slices and each slice is its own NAL. Counting
# slices as pictures gives 3300 "pictures" out of 300 -- 11 slices each.
#
# The picture boundary is the slice whose first_mb_in_slice == 0. That field is
# the first ue(v) of the slice header, immediately after the one-byte NAL header,
# and ue(v) encodes 0 as a single 1 bit. So: top bit of the byte after the header.
def is_first_slice_of_picture(off):
    return (data[off + 1] & 0x80) != 0

SLICE_P, SLICE_IDR = 1, 5

# rtph264pay puts one NAL in one RTP packet when it fits, and fragments it into
# FU-A packets when it does not. mtu=1400 is the whole packet, of which 12 bytes
# are the RTP header and 2 more the FU indicator/header.
MTU_PAYLOAD = 1400 - 12 - 2

def rtp_packets(nal_size):
    return max(1, -(-nal_size // MTU_PAYLOAD))   # ceiling division

pictures = []            # (kind, access_unit_bytes, n_slices, n_rtp_packets)
kind = None
au_bytes = au_slices = au_pkts = pending = pending_pkts = 0  # SPS/PPS/SEI precede

for k in range(len(starts) - 1):
    beg, end = starts[k], starts[k + 1]
    size = (end - beg) + 3           # include the start code
    nal_type = data[beg] & 0x1F

    if nal_type not in (SLICE_P, SLICE_IDR):
        pending += size
        pending_pkts += rtp_packets(size)
        continue

    if is_first_slice_of_picture(beg):
        if kind is not None:
            pictures.append((kind, au_bytes, au_slices, au_pkts))
        kind = 'IDR' if nal_type == SLICE_IDR else 'P'
        au_bytes, au_slices, au_pkts = pending, 0, pending_pkts
        pending = pending_pkts = 0

    au_bytes += size
    au_slices += 1
    au_pkts += rtp_packets(size)

if kind is not None:
    pictures.append((kind, au_bytes, au_slices, au_pkts))

idr = [i for i, p in enumerate(pictures) if p[0] == 'IDR']
gaps = [b - a for a, b in zip(idr, idr[1:])]
isz = [p[1] for p in pictures if p[0] == 'IDR']
psz = [p[1] for p in pictures if p[0] == 'P']
slices = [p[2] for p in pictures]

def mean(v):
    return sum(v) / len(v) if v else 0.0

au_mean = mean([p[1] for p in pictures])
sl_mean = mean(slices)

print(f"stream bytes       : {n}")
print(f"pictures           : {len(pictures)}  ({len(isz)} IDR, {len(psz)} P, 0 B)")
print(f"slices per picture : min={min(slices)} max={max(slices)}   <- sliced threads")
print(f"IDR at picture     : {idr[:8]}{' ...' if len(idr) > 8 else ''}")
if gaps:
    print(f"IDR interval       : min={min(gaps)} max={max(gaps)} mean={mean(gaps):.1f} pictures")
    print(f"worst-case recovery: {max(gaps) / fps * 1000:.0f} ms at {fps:g} fps")
print(f"mean IDR size      : {mean(isz):8.0f} B")
print(f"mean P size        : {mean(psz):8.0f} B")
if psz and mean(psz):
    print(f"IDR / P ratio      : {mean(isz) / mean(psz):.1f}x")
print(f"mean picture size  : {au_mean:8.0f} B")
print(f"mean slice size    : {au_mean / sl_mean:8.0f} B")

pkts = [p[3] for p in pictures]
total_pkts = sum(pkts)
print(f"RTP packets (model): {total_pkts}  ({total_pkts/len(pictures):.1f} per picture)")

# What one lost packet costs, in pictures.
#
# The textbook answer is "half a GOP on average": a loss lands at a uniformly
# random picture, and everything from there to the next IDR inherits the error.
# That is wrong, and the reason is in the numbers above. A loss lands at a
# uniformly random *packet*, not picture, and the keyframe holds many times more
# packets than a P picture does. Weight by where the bits actually are.
if gaps:
    g = gaps[0] if len(set(gaps)) == 1 else round(mean(gaps))
    naive = (g + 1) / 2
    cost = num = 0
    for i, p in enumerate(pictures):
        pos = i - max(j for j in idr if j <= i)   # position within its GOP
        cost += p[3] * (g - pos)                  # pictures damaged, this one included
        num += p[3]
    print()
    print(f"one lost packet damages (uniform over pictures) : {naive:.1f} pictures"
          f"  ({naive * 1000 / fps:.0f} ms)   <- the textbook answer")
    print(f"one lost packet damages (uniform over packets)  : {cost/num:.1f} pictures"
          f"  ({cost / num * 1000 / fps:.0f} ms)   <- weighted by the keyframe")
    idr_pkts = sum(p[3] for p in pictures if p[0] == 'IDR')
    print(f"share of packets that belong to a keyframe      : {100*idr_pkts/num:.0f}%"
          f"   -- losing one of those costs the whole GOP")

    # Both figures above are for a single isolated loss. A real link does not
    # oblige: at a loss rate of about one packet per GOP, a damaged GOP usually
    # contains more than one loss, and the damage starts at the earliest of them.
    # Averaging over damaged GOPs therefore reports *more* than the isolated-loss
    # cost. Simulate the stream's real packet layout rather than argue about it.
    if loss > 0:
        random.seed(1)
        trials, hit_gops, damaged_total = 2000, 0, 0
        n_gops = len(pictures) // g
        for _ in range(trials):
            for gi in range(n_gops):
                first_bad = None
                for pos in range(g):
                    p = pictures[gi * g + pos]
                    if any(random.random() < loss for _ in range(p[3])):
                        first_bad = pos
                        break
                if first_bad is not None:
                    hit_gops += 1
                    damaged_total += g - first_bad
        total_gops = trials * n_gops
        print()
        print(f"simulating loss={loss:.4%} against this stream's packet layout:")
        print(f"  GOPs damaged                       : {100*hit_gops/total_gops:.0f}%")
        print(f"  mean pictures damaged per hit GOP  : {damaged_total/hit_gops:.1f}"
              f"  ({damaged_total/hit_gops*1000/fps:.0f} ms)")
PY
