# Packet loss: what one dropped RTP packet does to an H.264 stream

Measured on WSL2 Ubuntu 22.04, GStreamer 1.20.3, 16-core host, both ends on the
loopback interface with `tc netem` between them.

Reproduce:

```bash
cd video && cmake -B build && cmake --build build
sudo bash scripts/packet-loss.sh                    # the delivery tables
PATTERN=pinwheel bash scripts/make-stream.sh /tmp/s.h264 600
bash scripts/gop-stats.sh /tmp/s.h264 0.0021        # structure + prediction
# then two captures through netem, and:
bash scripts/frame-diff.sh /tmp/clean /tmp/lossy 30 # the pixel experiment
bash scripts/pattern-damage.sh                      # does the pattern hide it?
bash scripts/idr-vs-p.sh zone-plate "kx2=20 ky2=20 kt2=1"   # IDR vs P, no netem
```

## What is being measured, and what is not

The stream is `videotestsrc → x264enc (tune=zerolatency, ultrafast, 2 Mbit/s,
key-int-max=30) → rtph264pay → udpsink` at 1280×720/30. The receiver is
`src/receiver.cpp`.

This measures **loss on an idle loopback**, injected by netem at a rate we
choose. It is not a radio link: there is no burst loss, no fading, no
retransmission, no congestion. Real drone downlinks lose packets in bursts, and
a burst of 20 consecutive packets behaves quite differently from 20 packets lost
independently. Everything below assumes independent loss, because that is what
netem's `loss X%` produces.

## The stream, measured rather than assumed

`key-int-max=30` is a request, not a promise. `scripts/gop-stats.sh` reads the
actual bitstream the sender transmits:

```
pictures           : 600  (20 IDR, 580 P, 0 B)
slices per picture : 11               <- sliced threads, from tune=zerolatency
IDR interval       : min=30 max=30    <- exactly one keyframe per second
mean IDR size      : 84059 B
mean P size        :  5606 B
IDR / P ratio      : 15.0x
RTP packets        : 9081 modelled, 9510 counted by the kernel  (-4.5%)
```

Two things fall out of this that matter later.

**A picture is eleven slices, not one blob.** `tune=zerolatency` switches x264 to
sliced threads, so each picture is cut into 11 independently-decodable
horizontal bands, each its own NAL, each at least one RTP packet. A lost packet
destroys a band, not a frame. That is why the corrupted screenshot below shows
green stripes rather than a green screen.

**The keyframe holds 15% of the packets.** It is 15× the size of a P picture.
This wrecks the textbook answer to the question in the title, as shown below.

The IDR/P ratio is not a property of H.264, it is a property of the content. On
the same encoder settings: colour bars 2.8×, a ball on black 3.2×, a pinwheel
15.0×. Any claim that "an I-frame is ten times a P-frame" is a claim about a
particular video.

## Instruments

| instrument | what it sees | trustworthy? |
|---|---|---|
| `tc -s qdisc show dev lo` | packets the kernel discarded | yes — ground truth |
| `rtpjitterbuffer` `stats` → `num-lost` | gaps in RTP sequence numbers | only without reordering |
| `rtpjitterbuffer` `stats` → `num-pushed`, `num-late` | packets forwarded / arrived too late | yes |
| `GST_BUFFER_FLAG_DISCONT` on a decoded picture | nothing useful | **no** |
| `GST_BUFFER_FLAG_CORRUPTED` on a decoded picture | catastrophic damage only | **no** |

On a plain lossy link the first two agree to the packet: netem dropped 86,
`num-lost` reported 86. Under reordering they part company — `num-lost` climbs to
3644 while 4582 of the ~4700 packets are pushed and 270 of 300 pictures decode.
It counts *gap detections*, not undelivered packets. Both columns are printed in
the tables below for exactly that reason.

### The instrument that does not work

The C++ receiver counts `GST_BUFFER_FLAG_DISCONT` and `GST_BUFFER_FLAG_CORRUPTED`
on every picture leaving `appsink`. Both stay at zero, no matter how bad the link:

| netem loss | RTP pushed | RTP lost | pictures decoded | discont | corrupt |
|---|---|---|---|---|---|
| 0% | 2362 | 0 | 150 | 0 | 0 |
| 2% | 2310 | 45 | 150 | 0 | 0 |
| 5% | 2238 | 118 | 150 | 0 | 0 |
| 10% | 2132 | 233 | 150 | 0 | 0 |
| 20% | 1884 | 474 | 148 | 0 | 0 |

At 20% loss, 474 packets never arrived and the application still received 148 of
150 pictures with no flag raised on any of them. `avdec_h264` conceals the
missing slices and hands over a picture that looks, to the code, exactly like a
good one.

`CORRUPTED` is not always zero — it does trip when a picture loses *most* of its
slices, as in the reordering row of Table 1 below (19 of the 42 pictures that
survived). But by then the video is long unusable. As a link-health signal it is
worthless: it cannot distinguish a clean link from one dropping one packet in
five. `DISCONT` never trips at all, in any run in this document.

This is the single most useful thing here. **If a ground station wants to know
the video is unreliable, it has to count at the RTP layer.** Nothing downstream
will tell it. A "healthy video" indicator built on frame counts or decoder flags
would have read green while the operator stared at a wrecked picture.

## Table 1 — impairment vs. delivery

300 pictures sent per case. On loss, the decoder conceals (the default).

| case | netem | jitterbuf | net drop | net % | RTP pushed | jb lost | jb late | pictures | discont | corrupt |
|---|---|---|---|---|---|---|---|---|---|---|
| clean | `loss 0%` | 0 ms | 0 | 0.00 | 4705 | 0 | 0 | **300** | 0 | 0 |
| loss | `loss 2%` | 0 ms | 86 | 1.83 | 4604 | 86 | 0 | **300** | 0 | 0 |
| loss + jitter | `loss 2% delay 20ms 5ms` | 0 ms | 87 | 1.86 | 1176 | 3624 | 3359 | **42** | 0 | 19 |
| loss + jitter | `loss 2% delay 20ms 5ms` | 200 ms | 90 | 1.92 | 4582 | 3644 | 0 | **270** | 0 | 0 |

Row 2: 2% loss costs nothing in *delivery*. Every picture arrives, and `jb lost`
equals `net drop` exactly — 86 and 86. The damage is in the pixels, not the
count. See the pixel experiment below.

Row 3 is the result worth carrying to an interview. The network dropped under 2%.
The receiver got 25% of the packets and decoded 42 pictures out of 300. The other
3359 packets arrived intact and were thrown away by the jitter buffer for being
late. This row is unstable across runs — 0, 20, 42, 52 and 106 pictures on five
runs — because it sits on the cliff edge where nothing decodes.

### The bill for `latency=0`

T1.4 set `rtpjitterbuffer latency=0` and saved 200 ms. Here is the invoice.
Same impairment, three runs each:

| jitterbuffer | netem dropped | RTP pushed | pictures decoded (of 300) |
|---|---|---|---|
| 0 ms | 89 / 100 / 97 | 1088 / 1211 / 1114 | **52 / 106 / 20** |
| 200 ms | 74 / 105 / 112 | 4597 / 4574 / 4557 | **270 / 300 / 299** |

And the control that settles what is to blame — **jitter alone, no packet loss at
all**, `latency=0`:

```
netem: delay 20ms 5ms          (loss 0%)
tc dropped        : 0
num-pushed        : 1106
num-late          : 3495
pictures decoded  : 67 / 300
```

The network lost nothing. The receiver threw away three quarters of a perfectly
delivered stream because each packet was given a random delay of 20 ± 5 ms, which
reorders packets that were sent microseconds apart, and a jitter buffer of depth
zero has no memory in which to put an early-arriving successor. **`latency=0`
does not tolerate a network. It tolerates a wire.**

That is the honest shape of the trade: 200 ms of latency buys the difference
between 67 pictures and 300.

## Table 2 — two failure modes

`rtph264depay wait-for-keyframe=true` changes what the operator sees after a
loss: instead of a concealed, damaged picture, nothing at all until the stream
recovers. `--wait-for-keyframe` on the receiver selects it.

| on loss | netem | pictures sent | net drop | delivered | never shown |
|---|---|---|---|---|---|
| conceal (default) | 2% | 300 | 92 | **300** | 0 |
| drop until keyframe | 2% | 300 | 83 | **31** | 269 |
| drop until keyframe | 0.1% | 900 | 17 | **672** | 228 |

At 2% loss, "wait for a clean keyframe" delivers 31 of 300 pictures — a tenth of
the video, the rest a frozen still. Neither mode is good; they differ in *how*
they are bad. Wrong pixels or no pixels is a real decision, and on a drone it is
not obvious: a stale-but-clean picture may be more dangerous than a visibly
broken one, precisely because it does not look broken.

The 228 pictures never shown at 0.1% loss, over the 17 packets dropped, give
**13.4 pictures per lost packet** — a first estimate of the cost of one packet,
biased low because two losses inside one GOP only cost one recovery.

## The pixel experiment

Counting pictures cannot see concealment. To see the damage, compare the
received picture against the picture that should have been received.

That comparison needs a reference, and the obvious reference — decode a second,
clean run — does not work: **x264enc is not bit-reproducible.** Encoding the same
deterministic `videotestsrc` input twice gives two different files (verified by
`md5sum`). Every pixel would differ before a single packet was dropped.

So the encoder is taken out of the experiment. `scripts/make-stream.sh` encodes
once to a file; `STREAM=... scripts/sender.sh` replays that one bitstream over
RTP. Now the only thing that varies between runs is the network.

The control confirms it:

```
clean vs clean, same frozen bitstream:
  pictures compared  : 600
  pictures bit-exact : 600     <- the instrument reads zero when it should
```

### Why one lost packet ruins a whole second

`scripts/frame-diff.sh` compares each received picture against the reference and
reports mean absolute pixel difference. Loss rate 0.15%, 20 packets dropped of
9510, 600 pictures, GOP 30:

```
Any difference from the reference -- must end at an IDR
  #  starts   ends  pictures     ms  ends at IDR?  GOPs
  1       5     59        55   1833           yes     2
  2      90    119        30   1000           yes     1
  3     129    149        21    700           yes     1
  4     155    179        25    833           yes     1
  5     181    209        29    967           yes     1
  6     281    299        19    633           yes     1
  7     388    389         2     67           yes     1
  8     392    419        28    933           yes     1
  9     424    449        26    867           yes     1
 10     540    569        30   1000           yes     1

    ending exactly at an IDR: 10/10
```

Ten damage episodes. **All ten end exactly on a keyframe boundary**, never one
picture earlier or later. That is the whole mechanism in one column: a P picture
codes only its difference from the previous picture, so a wrong picture makes
every picture after it wrong, and nothing stops the chain until a picture arrives
that was coded without reference to anything — the next IDR.

Per GOP, which is the statistic that does not care whether two damaged GOPs
happened to be adjacent:

```
GOPs damaged                       : 11 / 20
mean pictures damaged per hit GOP  : 24.1  (803 ms)
total pictures damaged             : 265
GOPs damaged from their first picture (the keyframe itself was hit): 3 / 11
```

The error does not fade. Measured mean absolute difference against the reference,
on a harsher run (2% loss), around the first keyframe boundary:

```
picture   mean abs diff
   12       22.616  ############################################################
   ...      (flat)
   29       22.612  ############################################################
   30        0.336  #                                            <- IDR
   60        0.000                                               <- IDR, bit-exact
```

Flat at 22.6 for the whole GOP, then gone. There is no decay, no partial
recovery: a P picture that copies a wrong block copies it exactly.

| | |
|---|---|
| ![clean](img/01-clean.png) | ![corrupt](img/02-corrupt.png) |
| **Picture 29, as sent.** | **Picture 29, as received.** A packet of this GOP's keyframe was lost 29 pictures earlier. Two slices — two horizontal bands — never arrived, and every picture since has copied the hole forward. |

![recovered](img/03-recovered.png)

**Picture 30: the next keyframe.** Coded from nothing, so it owes the previous
picture nothing, and the bands are gone. (The three small green blocks are a
*fresh* loss in this keyframe, not residue: the next clean keyframe, picture 60,
matches the reference bit for bit.)

### The textbook answer is wrong

The usual account: a loss lands at a uniformly random picture, so on average it
ruins half a GOP — 15.5 pictures, 517 ms.

A loss does not land at a uniformly random *picture*. It lands at a uniformly
random *packet*, and packets are not spread evenly across pictures. The keyframe
of this stream is 15× the size of a P picture and holds 15% of all packets. Lose
one of those and the entire GOP is gone, all 30 pictures.

`gop-stats.sh` weights by the real packet layout of the real bitstream:

```
one lost packet damages (uniform over pictures) : 15.5 pictures (517 ms)  <- textbook
one lost packet damages (uniform over packets)  : 17.6 pictures (586 ms)  <- measured layout
share of packets that belong to a keyframe      : 15%
```

And the measured mean was higher still, 24.1 pictures. The remaining gap is not
a mystery, it is the estimator: at 0.21% loss this stream carries about one drop
per GOP, so a *damaged* GOP usually contains more than one, and the damage starts
at the earliest of them. Simulating that on the same bitstream's packet layout:

| | model | measured |
|---|---|---|
| GOPs damaged | 61% | 11/20 = 55% |
| mean pictures damaged per hit GOP | 20.1 (671 ms) | 24.1 (803 ms) |
| damaged GOPs whose keyframe was hit | ~24% | 3/11 = 27% |

Eleven samples with a standard deviation of 8 pictures give a standard error of
2.5, so 24.1 against 20.1 is 1.6 σ — the model is not contradicted, and it is not
confirmed to better than that either. The keyframe-hit share, predicted from the
packet layout alone, lands on the measurement.

## What I got wrong

**`GST_BUFFER_FLAG_DISCONT` is a fingerprint of packet loss.** It is not. The
comment saying so sat in `receiver.cpp` for a day. It survived because the number
it produced — zero on a clean link — was the number I expected. It kept producing
zero when two thirds of the stream never arrived. A counter that agrees with you
is not evidence; it has to be shown a case where it *should* move.

**A still test pattern hides the damage.** This was the diagnosis after the first
attempt with `pattern=smpte` showed nothing, and it is wrong twice over. It is in
the section below, because getting it wrong twice was the more useful result.

**Two runs of the same pipeline are comparable.** They are not — x264enc is not
bit-reproducible. The whole pixel experiment above rests on freezing the
bitstream first, and it would have produced confident nonsense otherwise.

**The keyframe's slice is the one that hurts.** Plausible enough that I wrote it
into this document as the likely cause before testing it. It is 5.8× worse than a
P slice, and on a still picture it is *still invisible* — 0.23 of 255 against the
22.6 it was invoked to explain. Being 5.8× worse than nothing is nothing.

## Does the picture hide the damage?

The first attempt at the pixel experiment used `pattern=smpte`, saw nothing, and
I concluded: *a still image hides packet loss, because concealment copies the
missing block from the previous picture and on a still image that block is
correct.* The experiment was rerun "with motion", using `pattern=pinwheel`, and
the damage appeared. That looked like a confirmation. It was not.

**`pattern=pinwheel` does not move.** Measured over 30 consecutive frames, the
share of pixels changing by more than 8 of 255 (`scripts/pattern-damage.sh`):

| pattern | pixels that move | spatial detail |
|---|---|---|
| `pinwheel` | **0.0%** | 10.6 |
| `ball motion=sweep` | 2.0% | 1.4 |
| `smpte` | 5.8% | 6.1 |
| `zone-plate kx2=20 ky2=20 kt2=1` | 72.9% | 17.0 |

The rerun swapped one still picture for another still picture, and the result
changed anyway. Whatever fixed it, "adding motion" was not what happened, because
no motion was added.

So measure the thing properly. Same frozen bitstream, same `loss 0.15%`, 600
pictures, four patterns. `median` is the median mean-absolute pixel difference
over the pictures that differ from the reference at all:

| pattern | dropped | altered | median | ends at IDR |
|---|---|---|---|---|
| `smpte` | 16 | 118 / 600 | 0.34 | 8/8 |
| `pinwheel` | 11 | 110 / 600 | **0.01** | 7/7 |
| `ball motion=sweep` | 10 | 128 / 600 | 0.58 | 8/8 |
| `zone-plate` | 13 | 151 / 600 | **4.22** | 6/6 |

Three things fall out.

**No pattern hides the damage. Every one of them is wrong on 110–155 pictures of
600.** `smpte` never concealed the loss; it concealed the *amplitude*, by a
factor of 400 against the zone plate. The original instrument was a histogram of
PNG file sizes, and 0.34 of 255 does not move a PNG file size. The picture came
back wrong on a fifth of its frames and looked perfect.

**Amplitude needs motion, but motion does not rank it.** The pinwheel never moves
and has the least damage of the four, 0.01 — which is exactly the mechanism I
first guessed: concealment copies the co-located block from the previous picture,
and if nothing moved, that block is right. The zone plate moves 73% of its pixels
and is 400× worse. But `ball` (2.0% moving) beats `smpte` (5.8% moving) on both
runs, so the ordering in between is not a function of motion alone.

**The headline survives.** Grouping pictures that differ from the reference at
all — threshold-free, nothing to tune — **29 of 29 damage episodes ended exactly
at a keyframe**. (The deterministic experiment two sections down puts this beyond
sampling luck: 36 of 36 episodes, every slice of a picture tried in turn.) A
second run of the same command gave 29 of 31; both exceptions
were on `ball`, and they are an artifact of the metric rather than of the codec:
`ball` is 98% flat black, so a corrupted macroblock in the background renders
*pixel-identical* to the reference, the difference reads exactly 0.000 for a
picture or two, and one true episode is chopped into fragments that appear to end
mid-GOP. The error is still in the decoder's reference buffer. Pixel difference
measures what you can see, not what the decoder believes.

### Two ways this measurement lied to me

**A maximum is not a statistic.** The first version of this table reported the
*worst* picture in each run. On `smpte` at 2% loss it read 2.2 in one run and
12.1 in the next — a factor of six from the same command, because the maximum is
decided by whether one keyframe slice happened to be hit. It looked like a
finding. It was a coin toss. The table above reports a median.

**A truncated episode is not a counter-example.** The last damage episode of a
capture ends when the capture ends, not when a keyframe arrives. Counting it
turned a 27/27 into a 7/8 between two runs and nearly bought a retraction of the
central result. `frame-diff.sh` now excludes it and says so.

## Which slice dies: the keyframe's, or a P picture's?

Netem cannot answer this. A keyframe holds 15% of the packets, so a 600-picture
run yields one or two keyframe losses; two runs of that experiment disagreed by a
factor of 60. The sample was the result.

So take netem out. `scripts/idr-vs-p.sh` deletes **exactly one slice NAL** from
the frozen bitstream and decodes. Losing any RTP packet of a NAL loses the whole
NAL — `rtph264depay` discards an incomplete one — so deleting the NAL is a
faithful model of losing one of its packets, and it lets us choose the victim.
Given a bitstream, nothing here is random and the table repeats exactly. Across
runs it wobbles in the third decimal — 0.226 became 0.225 — because the script
re-encodes, and x264enc is not bit-reproducible, as this document says two
sections up. The effects below are 5.8× and 100×, so this does not threaten them,
but it is the reason no claim here rests on a third decimal.

90 pictures, three GOPs, 11 slices per picture. Each of the 11 slices of picture
30 (an IDR) is deleted in turn, then each of the 11 slices of picture 15 (a P).
Three GOPs rather than two, so that the keyframe which heals the IDR victim —
picture 60 — is inside the capture. At 60 pictures its recovery would be off the
end of the file, and I would be assuming the heal instead of seeing it.

On `zone-plate kx2=20 ky2=20 kt2=1`, the pattern that actually moves:

| victim | trials | pictures altered | MAE at impact | peak | worst peak |
|---|---|---|---|---|---|
| one slice of the IDR, picture 30 | 11 | `30..59`, every time | **10.69** | 10.97 | 24.31 |
| one slice of a P, picture 15 | 11 | `15..29`, every time | **1.85** | 1.92 | 2.65 |

*(medians over the 11 slices; MAE is of 255. "Impact" is the picture the loss
lands on, "peak" the worst picture of the episode.)*

**Duration is not a property of the frame type.** It is the distance to the next
keyframe, and nothing else. The IDR victim costs 30 pictures and the P victim 15
because picture 30 is a full GOP from rescue and picture 15 is half a GOP away.
A slice lost in picture 29 would cost exactly one picture. Every one of the 22
trials produced a *contiguous* run of altered pictures ending exactly at the next
keyframe — no gaps, no early recovery, no bleed past the IDR.

**Amplitude is a property of the frame type: losing a keyframe's slice is 5.8×
worse** — 10.69 against 1.85.

**And that gap is decided at impact, not accumulated over the episode.** This is
the part I could easily have got backwards. The IDR victim's damage lasts twice
as long, so a bigger peak could simply be error drifting for twice as many
pictures. It is not: the median peak exceeds the median impact by 3% for the IDR
and 4% for the P. The whole 5.8× is already present in the first damaged picture.
Concealing an intra-coded band is what is hard; the rest of the GOP just carries
the result forward. Drift is real but secondary — the worst single slice grew
from 10.69 at impact to 24.31 by the end of its GOP.

Now the same 22 trials on the still `pinwheel`:

| victim | trials | trials that changed *any* pixel | MAE at impact | worst peak |
|---|---|---|---|---|
| one slice of the IDR, picture 30 | 11 | 11 | 0.069 | 0.225 |
| one slice of a P, picture 15 | 11 | **3** | 0.000 | 0.149 |

On a still image, 8 of the 11 P-slice deletions decode **pixel-identical to the
reference** — MAE exactly 0.000. That is the concealment mechanism caught in the
act: it copies the co-located band from the previous picture, and when nothing
moved, the copy is not an approximation, it is the right answer. The IDR is
different in kind — all 11 of its slices leave a residue — but at 0.07 of 255 the
residue is invisible.

On the pinwheel, peak equals impact to three decimals in all 22 trials. A frozen
band copied forward through a frozen picture does not drift. Motion is what turns
a concealment error into an error that grows.

### What this rules out

The suspect named in the previous version of this document was that pinwheel's
collapse at 2% loss is keyframe-slice loss: an IDR is coded without reference to
anything, so perhaps concealment has no previous picture to copy from.

**That is wrong, and this experiment is what shows it.** A lost IDR slice on the
pinwheel peaks at 0.23 of 255. The wrecked picture screenshotted above, same
pattern at 2% loss, sits flat at 22.6 of 255 for a whole GOP — a hundred times
larger. One dead keyframe slice does not do that. The decoder plainly *does* hold
the previous picture and copy from it, even across an IDR.

### Still open

What does happen to the pinwheel at 2%, then. At 0.15% loss this stream drops
about one packet per two GOPs, so a concealed band is nearly always copied from a
*correct* neighbour. At 2% it drops one per 6 pictures: many slices per GOP, on
consecutive pictures, and the previous picture — the thing concealment copies
from — is itself already wrong. The still image stops being its own best
predictor. That is a testable claim (delete the same slice index from *k*
consecutive pictures and watch the peak as *k* grows) and I have not tested it,
so it stays a hypothesis here rather than a result.

## Mapping to Jetson Orin NX

The RTP layer is where all of this lives, and none of it changes: `rtph264pay`,
`udpsink`, `rtpjitterbuffer`, `rtph264depay`, the `num-lost` counter, the
jitter-vs-latency trade. All transfer unchanged.

What changes is the encoder, and with it the two structural facts this document
leans on. From `nvv4l2h264enc`'s documented property set — not verified on
hardware, I have no board — there is no `sliced-threads`: a picture is one slice
unless `slice-header-spacing` is set, so a lost packet damages the whole picture
rather than one of eleven bands. Its keyframe interval is `iframeinterval` rather
than `key-int-max`, and `insert-sps-pps=true` plays the role of
`config-interval=1`. The keyframe/P size ratio, and with it the packet-weighted
cost of one lost packet, is a property of the content and the encoder, so it
would have to be measured again on the real camera.
