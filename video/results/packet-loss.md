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
the same encoder settings: still colour bars 2.8×, a ball on black 3.2×, a
rotating pinwheel 15.0×. Any claim that "an I-frame is ten times a P-frame" is a
claim about a particular video.

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

**A still test pattern is fine for this.** The first attempt used
`pattern=smpte`. At 2% loss the PNG size distribution of the lossy run was
indistinguishable from the clean one, and no picture looked broken: concealment
copies the missing block from the previous picture, and on a still image that is
the *correct* block. A camera on a drone never sees a still image. The experiment
was rerun with motion.

**Two runs of the same pipeline are comparable.** They are not — x264enc is not
bit-reproducible. The whole pixel experiment above rests on freezing the
bitstream first, and it would have produced confident nonsense otherwise.

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
