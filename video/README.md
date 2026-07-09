# video/ — Low-latency H.264 downlink over RTP/UDP

GStreamer sender + a **C++ receiver built on the GStreamer C API** (`appsink`), with
end-to-end latency measurement and packet-loss experiments under `tc netem`.

> Status: **not implemented yet.** See [../docs/01-PLAN.md](../docs/01-PLAN.md) tasks T1.1–T1.6.

## Pipeline

```
videotestsrc → timeoverlay → videoconvert → x264enc → rtph264pay → udpsink
                                                                      │
                                                                UDP :5000
                                                                      │
   appsink ← avdec_h264 ← rtph264depay ← rtpjitterbuffer ← udpsrc ────┘
      │
   receiver.cpp
```

## Build

```bash
cmake -B build && cmake --build build
```

## Run

```bash
./scripts/sender.sh          # terminal 1
./build/receiver --port 5000 # terminal 2
```

## Measure latency

```bash
./scripts/measure-latency.sh          # wraps GST_TRACERS=latency
```

## Simulate a lossy link

```bash
./scripts/netem.sh on    # 2% loss, 20ms delay, 5ms jitter on lo
./scripts/netem.sh off
```

## Results

| Configuration | Pipeline latency |
|---|---|
| Default | _TBD_ |
| `tune=zerolatency` | _TBD_ |
| `+ rtpjitterbuffer latency=0` | _TBD_ |
| `+ sink sync=false` | _TBD_ |

Method, raw traces and packet-loss screenshots: [`results/`](results/).

## Mapping to Jetson Orin NX

The pipeline architecture is unchanged on target hardware; only the source, converter and
codec elements are swapped for their NVMM-backed equivalents:

| Here (x86) | Jetson |
|---|---|
| `videotestsrc` | `nvarguscamerasrc` (CSI) / `v4l2src` (USB) |
| `videoconvert` | `nvvidconv` |
| `x264enc` | `nvv4l2h264enc` (NVENC hardware encoder) |
| `avdec_h264` | `nvv4l2decoder` |

`rtph264pay`, `udpsink`, `rtpjitterbuffer` and the C++ receiver are identical.

## Known limitations

- Both endpoints run on loopback, so NIC and real-network effects (MTU, congestion) are not
  exercised — `tc netem` approximates loss and jitter only.
- Latency reported is **pipeline latency** (`GST_TRACERS`), not glass-to-glass.
- Software encoding only; NVENC latency is not measured.
