#!/usr/bin/env bash
#
# Compare two capture directories picture by picture and report where, and for
# how long, they differ.
#
# videotestsrc is deterministic: picture k is the same image on every run. So
# running the reference against a second clean capture must give zero difference
# on every picture -- that is the control, and it is what makes a non-zero
# difference in the lossy run attributable to the network rather than to noise.
#
# Damage is reported as mean absolute pixel difference (0-255) over a 320x180
# RGB copy of each picture. What matters is not the absolute value but where the
# non-zero runs start and where they stop: they stop at a keyframe.
#
# Usage:  ./frame-diff.sh <reference-dir> <test-dir> [gop]
#
set -euo pipefail

REF="${1:?usage: frame-diff.sh <reference-dir> <test-dir> [gop]}"
TEST="${2:?usage: frame-diff.sh <reference-dir> <test-dir> [gop]}"
GOP="${3:-30}"

python3 - "$REF" "$TEST" "$GOP" <<'PY'
import sys, os, glob

ref_dir, test_dir, gop = sys.argv[1], sys.argv[2], int(sys.argv[3])

def frames(d):
    out = {}
    for p in glob.glob(os.path.join(d, 'g-*.rgb')):
        out[int(os.path.basename(p)[2:-4])] = p
    return out

ref, test = frames(ref_dir), frames(test_dir)
common = sorted(set(ref) & set(test))
if not common:
    sys.exit('no overlapping pictures -- was the capture written?')

mae = {}
for k in common:
    a, b = open(ref[k], 'rb').read(), open(test[k], 'rb').read()
    if len(a) != len(b):
        mae[k] = float('nan')
        continue
    mae[k] = sum(abs(x - y) for x, y in zip(a, b)) / len(a)

print(f"pictures compared   : {len(common)}  (ref {len(ref)}, test {len(test)})")
print(f"pictures bit-exact  : {sum(1 for k in common if mae[k] == 0)}")

def episodes_of(pred, label):
    """Group pictures satisfying pred into runs of consecutive indices."""
    hit = [k for k in common if pred(k)]
    eps = []
    for k in hit:
        if eps and k == eps[-1][-1] + 1:
            eps[-1].append(k)
        else:
            eps.append([k])
    return eps

# Two definitions of damage, on purpose.
#
# `any`     -- the picture is not bit-exact. Threshold-free. An IDR is coded
#              without reference to anything, so every such run MUST end at an
#              IDR. If one did not, the error-propagation story would be wrong.
# `visible` -- mean absolute difference above 0.5 of 255. Most lost slices on
#              this pattern carry flat background, and concealing them is
#              exactly right, so they never become visible.
any_eps = episodes_of(lambda k: mae[k] > 0, 'any')
vis_eps = episodes_of(lambda k: mae[k] > 0.5, 'visible')

print(f"pictures altered    : {sum(len(e) for e in any_eps)}   (any difference at all)")
print(f"pictures visibly bad: {sum(len(e) for e in vis_eps)}   (mean abs diff > 0.5 of 255)")
if not any_eps:
    print("no damage -- either the link was clean, or the decoder concealed it perfectly")
    raise SystemExit

worst = max(common, key=lambda k: mae[k])
print(f"worst picture       : {worst}  (mean abs diff {mae[worst]:.1f})")

# `worst` is a maximum over hundreds of pictures, so it is decided by whether one
# keyframe slice happened to be hit. It swings by 6x between runs of the same
# command. Quote the distribution over the damaged pictures instead.
dmg = sorted(mae[k] for k in common if mae[k] > 0)
if dmg:
    med = dmg[len(dmg) // 2]
    p90 = dmg[min(len(dmg) - 1, int(len(dmg) * 0.90))]
    print(f"damage amplitude    : median {med:.2f}  p90 {p90:.2f}  "
          f"mean {sum(dmg)/len(dmg):.2f}   (of 255, over altered pictures)")

def report(eps, title):
    if not eps:
        print(f"\n{title}: none")
        return
    print(f"\n{title}")
    print(f"{'#':>3}  {'starts':>6}  {'ends':>5}  {'pictures':>8}  {'ms':>5}  "
          f"{'ends at IDR?':>12}  {'GOPs':>4}")
    for i, ep in enumerate(eps, 1):
        beg, end = ep[0], ep[-1]
        # An episode ends at *an* IDR, not necessarily the first one after it
        # started: a fresh loss inside a damaged stretch carries it into the
        # next GOP. `GOPs` counts how many keyframes it survived that way.
        at_idr = 'yes' if (end + 1) % gop == 0 else 'no'
        spans = (end // gop) - (beg // gop) + 1
        print(f"{i:>3}  {beg:>6}  {end:>5}  {len(ep):>8}  {len(ep)*1000/30:>5.0f}  "
              f"{at_idr:>12}  {spans:>4}")
    lens = [len(e) for e in eps]
    # The last run may be cut off by the end of the capture rather than by an
    # IDR. Such an episode cannot end at a keyframe and must not be counted
    # against the claim -- nor for it. Score it separately, do not silently
    # include it: that turned a 27/27 into a 7/8 between two runs of the same
    # command, and the difference was the capture, not the codec.
    truncated = eps[-1][-1] == common[-1] and (common[-1] + 1) % gop != 0
    scored = eps[:-1] if truncated else eps
    at_idr = sum(1 for e in scored if (e[-1] + 1) % gop == 0)
    print(f"    episodes {len(eps)}   mean {sum(lens)/len(lens):.1f} pictures "
          f"({sum(lens)/len(lens)*1000/30:.0f} ms)   longest {max(lens)} "
          f"({max(lens)*1000/30:.0f} ms)")
    print(f"    ending exactly at an IDR: {at_idr}/{len(scored)}"
          f"{'  (1 episode excluded: cut off by the end of the capture)' if truncated else ''}")
    print(f"    expected for one isolated loss: {(gop + 1) / 2:.1f} pictures "
          f"({(gop + 1) / 2 * 1000 / 30:.0f} ms)")

report(any_eps, "Any difference from the reference -- must end at an IDR")
report(vis_eps, "Visible corruption")

# Per-GOP view. This is the statistic to compare against the simulation in
# gop-stats.sh, because it does not care whether two damaged GOPs happened to be
# adjacent and got merged into one episode by the run-length grouping above.
print("\nPer-GOP damage")
n_gops = (max(common) + 1 + gop - 1) // gop
hit = []
for gi in range(n_gops):
    pics = [k for k in common if k // gop == gi]
    bad = [k for k in pics if mae[k] > 0]
    if bad:
        hit.append((gi, len(bad), min(bad) % gop))
print(f"    GOPs damaged: {len(hit)}/{n_gops}")
if hit:
    dmg = [h[1] for h in hit]
    print(f"    mean pictures damaged per hit GOP: {sum(dmg)/len(dmg):.1f} "
          f"({sum(dmg)/len(dmg)*1000/30:.0f} ms)")
    print(f"    total pictures damaged: {sum(dmg)}")
    full = sum(1 for h in hit if h[2] == 0)
    print(f"    GOPs damaged from their very first picture (the keyframe was hit): "
          f"{full}/{len(hit)}")
PY
