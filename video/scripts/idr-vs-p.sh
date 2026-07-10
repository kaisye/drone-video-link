#!/usr/bin/env bash
#
# Does it matter whether the lost packet belonged to a keyframe?
#
#   bash scripts/idr-vs-p.sh [pattern] [src-extra]     # no root, no netem
#
# The obvious way to ask is to run netem and sort the damage by where it began.
# That does not work: netem chooses the victim, and a keyframe is 15% of the
# packets, so a 600-picture run yields one or two keyframe losses. Two runs of
# that experiment disagreed by a factor of 60 -- the sample was the result.
#
# So do not let netem choose. Take the frozen bitstream, delete exactly one
# slice NAL, decode, and diff against the clean decode. Losing any RTP packet of
# a NAL loses the whole NAL, because rtph264depay discards an incomplete one, so
# deleting the NAL is a faithful model of losing one of its packets -- and it
# lets us pick the victim.
#
# Given a bitstream this is deterministic and repeats exactly. It re-encodes on
# every invocation, though, and x264enc is not bit-reproducible, so figures move
# in the third decimal between runs. Do not read anything into a third decimal.
#
# The victims are chosen so that both have a previous picture available to the
# decoder's concealment:
#
#   picture 30, an IDR   -- but an IDR flushes the reference list
#   picture 15, a P      -- which may copy from picture 14
#
# If concealment for a lost slice copies from the previous picture, then on a
# still image the P case must be near zero. What the IDR case does is the
# question: an IDR is coded without reference to anything, but the decoder still
# holds the previous picture in memory. Does it use it?
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/common.sh"

# Three GOPs, not two. The victim IDR is picture 30, so with 60 pictures its
# damage runs to 59 and the capture ends before the keyframe that heals it --
# the heal would be assumed rather than seen. 90 pictures puts it at 60, inside.
PICS="${PICS:-90}"
W="${W:-/tmp/idr-vs-p}"
PATTERN="${1:-pinwheel}"
SRC_EXTRA="${2:-${SRC_EXTRA:-}}"   # positional, or the env var the other scripts use

rm -rf "$W"; mkdir -p "$W"
trap 'rm -rf "$W"' EXIT

PATTERN="$PATTERN" SRC_EXTRA="$SRC_EXTRA" bash "$HERE/make-stream.sh" "$W/s.h264" "$PICS"
echo

python3 - "$W" "$KEY_INT_MAX" <<'PY'
import os, glob, subprocess, sys, statistics

W, gop = sys.argv[1], int(sys.argv[2])
data = open(f"{W}/s.h264", "rb").read()
n = len(data)

# ---- index the Annex-B NALs -------------------------------------------------
# start code 00 00 01; nal_unit_type = byte & 0x1F; 1 = P slice, 5 = IDR slice.
# A slice is not a picture: a picture begins at the slice whose first_mb_in_slice
# is 0, and ue(v) codes 0 as a single 1 bit, so it is the top bit of the byte
# after the NAL header.
nals = []
i = 0
while i < n - 3:
    if data[i] == 0 and data[i+1] == 0 and data[i+2] == 1:
        p = i + 3
        j = p
        while j < n - 3 and not (data[j] == 0 and data[j+1] == 0 and data[j+2] == 1):
            j += 1
        nals.append((i, data[p] & 0x1F, bool(data[p+1] & 0x80) if p + 1 < n else False))
        i = j
    else:
        i += 1

pics = []
for idx, (_, t, first_mb0) in enumerate(nals):
    if t in (1, 5):
        if first_mb0 or not pics:
            pics.append([idx])
        else:
            pics[-1].append(idx)

print(f"pictures {len(pics)}, slices per picture {len(pics[0])}")
idr_pic, p_pic = gop, gop // 2
print(f"victim pictures: {idr_pic} (IDR, type "
      f"{nals[pics[idr_pic][0]][1]}), {p_pic} (P, type {nals[pics[p_pic][0]][1]})")
print()

def decode(path, outdir):
    os.makedirs(outdir, exist_ok=True)
    for f in glob.glob(outdir + "/g-*.rgb"):
        os.remove(f)
    subprocess.run(
        ["gst-launch-1.0", "-q", "filesrc", f"location={path}", "!", "h264parse", "!",
         "avdec_h264", "!", "videoconvert", "!", "videoscale", "!",
         "video/x-raw,width=320,height=180,format=RGB", "!",
         "multifilesink", f"location={outdir}/g-%04d.rgb"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)

def load(d):
    return {int(os.path.basename(p)[2:-4]): open(p, 'rb').read()
            for p in glob.glob(d + "/g-*.rgb")}

decode(f"{W}/s.h264", f"{W}/ref")
ref = load(f"{W}/ref")
print(f"reference decoded: {len(ref)} pictures")
print()

def drop_and_measure(nal_idx, label):
    a = nals[nal_idx][0]
    b = nals[nal_idx + 1][0] if nal_idx + 1 < len(nals) else n
    open(f"{W}/x.h264", "wb").write(data[:a] + data[b:])
    decode(f"{W}/x.h264", f"{W}/x")
    t = load(f"{W}/x")
    peak, hit, mae = 0.0, [], {}
    for k in sorted(set(ref) & set(t)):
        x, y = ref[k], t[k]
        if len(x) != len(y):
            continue
        m = sum(abs(p - q) for p, q in zip(x, y)) / len(x)
        if m > 0:
            hit.append(k)
            mae[k] = m
            peak = max(peak, m)
    # Report the extent, not just the count: a count of 15 says nothing about
    # whether the damage was contiguous, and reading an episode out of a count is
    # how the earlier netem experiment fooled itself.
    #
    # Report the impact too. "peak" is the worst of a whole episode, so it mixes
    # the concealment error with 15-30 pictures of drift on top. The MAE of the
    # first altered picture is the concealment error alone.
    if hit:
        span = f"{hit[0]}..{hit[-1]}"
        gaps = len(hit) != hit[-1] - hit[0] + 1
        ends_at_idr = (hit[-1] + 1) % gop == 0
        mark = ("*" if gaps else " ") + ("=" if ends_at_idr else " ")
        impact = mae[hit[0]]
    else:
        span, mark, impact = "-", "  ", 0.0
    print(f"  {label:<22} decoded {len(t):>3}   altered {len(hit):>3}"
          f"   pictures {span:<9}{mark}   MAE at impact {impact:7.3f}   peak {peak:7.3f}")
    return impact, peak

print(f"one slice NAL of picture {idr_pic} (IDR) removed, one at a time:")
idr = [drop_and_measure(k, f"IDR slice {s}") for s, k in enumerate(pics[idr_pic])]
print(f"\none slice NAL of picture {p_pic} (P) removed, one at a time:")
pp = [drop_and_measure(k, f"P slice {s}") for s, k in enumerate(pics[p_pic])]

def summarise(rows, label):
    imp = [r[0] for r in rows]
    pk = [r[1] for r in rows]
    print(f"{label} : median impact {statistics.median(imp):7.3f}"
          f"   median peak {statistics.median(pk):7.3f}   max peak {max(pk):7.3f}")

print()
summarise(idr, "IDR slice lost")
summarise(pp,  "P   slice lost")
print("\n(MAE is of 255. 'impact' is the picture the loss lands on; 'peak' is the")
print(" worst picture of the episode, i.e. impact plus accumulated drift.)")
print(f"(= damage ends exactly at a keyframe;  * the altered pictures are not contiguous)")

last, heal = len(pics) - 1, 2 * gop
if heal <= last:
    print(f"(last picture {last}: the IDR victim's heal at picture {heal} is inside "
          f"the capture, so every '=' above was observed, not assumed)")
else:
    print(f"(last picture {last} < {heal}: the IDR victim's heal is NOT in this "
          f"capture -- its '=' is an artifact of the capture ending. Use PICS={heal + gop}.)")
PY
