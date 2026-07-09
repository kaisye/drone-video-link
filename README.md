# drone-video-link

A ground-station link prototype for a drone camera payload: **low-latency H.264 video downlink over RTP/UDP** and a **MAVLink telemetry & control gateway**, built and profiled on Embedded Linux.

Developed against the software stack used on Jetson Xavier/Orin NX companion computers, but runnable entirely on a laptop — video source is simulated with `videotestsrc`, the flight controller with ArduPilot SITL. No drone required.

---

## System

```
        ┌──────────────────────────────┐          ┌──────────────────────────┐
        │  Companion computer          │          │  Ground station          │
        │  (Jetson Orin NX)            │          │                          │
        │                              │          │                          │
Camera ─┼─► GStreamer ─► H.264 ─► RTP ─┼─ UDP ────┼─► C++ receiver ─► display │
        │                              │ Ethernet │                          │
   FC ──┼─► MAVLink router ────────────┼─ UDP ────┼─► Python gateway ─► logs  │
(Pixhawk)                              │          │                          │
        └──────────────────────────────┘          └──────────────────────────┘
```

Both components are simulated on one host. See [docs/00-OVERVIEW.md](docs/00-OVERVIEW.md) for
what is real and what is simulated.

## Components

| Directory | What it is | Language |
|---|---|---|
| [`video/`](video/) | RTP/H.264 sender + C++ `appsink` receiver, latency measurement, packet-loss experiments | C++17, CMake, Shell |
| [`mavlink/`](mavlink/) | MAVLink gateway: heartbeat watchdog, arm/takeoff/land, telemetry logging, MQTT bridge | Python 3 |

## Results

| Metric | Value |
|---|---|
| End-to-end pipeline latency (tuned) | _TBD_ |
| End-to-end pipeline latency (default) | _TBD_ |
| Behaviour under 2% packet loss | _TBD_ |

Full method and numbers: [`video/results/`](video/results/).

## Documentation

Written in Vietnamese — the engineering notebook for this project.

| Doc | Purpose |
|---|---|
| [00-OVERVIEW](docs/00-OVERVIEW.md) | The real problem, and what this project simulates |
| [01-PLAN](docs/01-PLAN.md) | Two-day execution plan with checkpoints and fallbacks |
| [02-STATE](docs/02-STATE.md) | Live progress tracker |
| [03-ARCHITECTURE](docs/03-ARCHITECTURE.md) | Directory layout and data flow |
| [04-CONCEPTS](docs/04-CONCEPTS.md) | Every concept used here, explained from scratch |
| [05-DECISIONS](docs/05-DECISIONS.md) | Why each technical choice was made |
| [06-INTERVIEW-QA](docs/06-INTERVIEW-QA.md) | Questions this project should let me answer |

## Environment

Ubuntu 22.04 (WSL2). Both endpoints run inside the same distro over `127.0.0.1`.

```bash
sudo apt install -y \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav \
  cmake build-essential pkg-config ffmpeg iproute2
```
