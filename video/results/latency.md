# Pipeline latency

Measured with GStreamer's built-in tracer, `GST_TRACERS="latency(flags=pipeline+element)"`,
by [`../scripts/measure-latency.sh`](../scripts/measure-latency.sh). The raw `trace-*.log`
files are ~700 KB of DEBUG records each and are **not** committed; the script regenerates
them here and prints the medians below.

**Host:** WSL2 Ubuntu 22.04, 16 logical cores, GStreamer 1.20.3, x86-64 software encoding.
**Stream:** 1280x720 @ 30 fps, `videotestsrc pattern=smpte`, 2 Mbps target.
**Sample:** 150 frames per run, first 15 discarded as warm-up.

## What is being measured, and what is not

The tracer can only see inside a single pipeline, but the real system splits at UDP into
two. So the measurement runs the whole chain — `x264enc → rtph264pay → rtpjitterbuffer →
rtph264depay → avdec_h264` — inside one pipeline and drops the loopback hop. Every knob
under test lives in that chain; loopback contributes tens of microseconds.

This is **pipeline latency, not glass-to-glass latency.** It excludes camera exposure and
readout, the display's own buffering, and the real network. A number measured this way is
not comparable to one measured by pointing a camera at two screens.

Figures below are **medians**. The mean is misleading here: when the source stops, the
encoder drains its internal queue quickly, and those last few frames pull the mean far
below the steady-state value. For `e-plain` the mean is 1623 ms against a median of
2070 ms — a 450 ms gap that is pure end-of-stream artefact.

## Table 1 — the four configurations

| # | Configuration | Pipeline | of which x264enc | of which jitter buffer |
|---|---|---|---|---|
| 1 | stock defaults, `rtpjitterbuffer latency=200`, `sync=true` | **2288 ms** | 2067 ms | 218 ms |
| 2 | `+ tune=zerolatency speed-preset=ultrafast` | **223 ms** | 4.2 ms | 216 ms |
| 3 | `+ rtpjitterbuffer latency=0` | **23 ms** | 4.2 ms | 15.5 ms |
| 4 | `+ fakesink sync=false` | **7.8 ms** | 4.1 ms | 0.8 ms |

Each row explained:

**1 → 2, encoder: −2064 ms.** By far the largest win, and it comes entirely from the
encoder. Broken down in Table 2.

**2 → 3, jitter buffer: −200 ms.** `rtpjitterbuffer latency` is a promise to hold every
packet for that long so late or reordered ones can still be slotted into place. The delay
is paid unconditionally, on every packet, whether or not the network ever misbehaves. It
buys tolerance of jitter and costs exactly its own value in latency. FPV control needs the
opposite trade from video-on-demand, so it goes to 0.

**3 → 4, sink clock sync: −15 ms.** With `sync=true` the sink holds each buffer until its
presentation timestamp is due on the pipeline clock. There is no audio track to stay in
step with, so that wait is pure delay. Note where the cost actually appears: the jitter
buffer's own contribution falls from 15.5 ms to 0.8 ms. The sink was blocking, upstream
elements backed up behind it, and the buffers were queueing **in the jitter buffer**. The
element that showed the symptom was not the element with the problem.

**Total: 2288 ms → 7.8 ms.**

## Table 2 — which encoder knob costs the latency

Jitter buffer at 0 and sink sync off throughout; only the encoder line changes.

| Encoder configuration | x264enc median | in frames @30fps |
|---|---|---|
| `x264enc` (stock) | 2067 ms | 62 |
| `+ sliced-threads=true` | 1340 ms | 40 |
| `+ rc-lookahead=0` | 734 ms | 22 |
| `+ speed-preset=ultrafast` | 734 ms | 22 |
| `+ tune=zerolatency` | 5.8 ms | 0.2 |
| `+ tune=zerolatency speed-preset=ultrafast` | 4.2 ms | 0.1 |

Two independent delays, and within this pipeline they are additive: 1340 + 734 = 2074 ms,
against a measured 2067 ms for the stock encoder.

### It is not B-frames

The obvious explanation — that `tune=zerolatency` disables B-frames, which force the
encoder to wait for a future frame — **is wrong for this element.** GStreamer's `x264enc`
ships with `bframes=0`:

```
$ gst-inspect-1.0 x264enc | grep -A2 '^  bframes'
  bframes  : Number of B-frames between I and P
             Unsigned Integer. Range: 0 - 16 Default: 0
```

There are no B-frames to disable. The delay is elsewhere, and an isolation run
(`x264enc ! fakesink`, nothing else in the pipeline) locates it:

| threads | rc-lookahead | x264enc median | in frames |
|---|---|---|---|
| auto (16 cores) | 40 | 1503 ms | 45.1 |
| auto | 0 | 935 ms | 28.0 |
| 1 | 40 | 1313 ms | **39.4** |
| 1 | 0 | 119 ms | 3.6 |
| 4 | 0 | 334 ms | 10.0 |
| 8 | 0 | 468 ms | 14.0 |

**Lookahead costs exactly its own frame count.** At `threads=1`, `rc-lookahead=40` measures
39.4 frames of delay. The encoder is holding 40 frames so the rate controller can see how
complex the upcoming scene is before it decides how many bits to spend on the current one.

**Frame-based multithreading costs roughly one frame per worker thread.** 4 threads → 10
frames, 8 → 14, auto on 16 cores → 28. Each thread encodes a different frame concurrently,
so frame *N* cannot be emitted until its thread finishes, and frames *N+1…N+k* are already
in flight. `sliced-threads=true` splits each frame across threads instead of assigning a
frame to each — the throughput is lower, the delay is gone.

`tune=zerolatency` sets both at once: `rc-lookahead=0` and sliced threads. That is why it
alone takes 2067 ms down to 5.8 ms, and why `speed-preset=ultrafast` on its own gets stuck
at 734 ms — the preset zeroes the lookahead but leaves frame-based threading in place.

Absolute values in this last table are lower than in Table 2 because the probe pipeline has
no RTP payloader, decoder or colour conversion competing for the same cores. Compare the
rows against each other, not across tables.

## Mapping to Jetson Orin NX

On target, `x264enc` is replaced by `nvv4l2h264enc`, which encodes on NVENC rather than the
CPU. The 2 s of software-encoder delay measured here does not exist there — but neither
knob transfers: NVENC has no `rc-lookahead` property and no frame threads. Its equivalent
controls are `insert-sps-pps`, `iframeinterval` and `maxperf-enable`. The jitter buffer and
sink-sync results transfer unchanged, because those elements are the same.

## Reproduce

```bash
./scripts/measure-latency.sh 150
```
