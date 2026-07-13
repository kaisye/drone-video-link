# Live dashboard

A single-page ground-station dashboard that shows both halves of the link in
real time, side by side: the **video** channel (fps, packet loss) and the
**MAVLink** channel (attitude, altitude, battery, mode, link state). It reads
the *same* data the rest of the repo produces — the C++ receiver's `[stats]`
lines and the gateway's `telemetry.jsonl` — so nothing here is a second,
diverging implementation.

![Live ground-station dashboard: amber video channel on the left, blue MAVLink channel on the right](../docs/demo.png)

## How it fits together

```
 mock_fc.py ──udp:14550──▶ demo_flight.py ──writes──▶ mavlink/logs/telemetry.jsonl
   (fake FC)              (one connection:                         │ tail
                           telemetry + scripted                    │
                           takeoff/land)                           ▼
 sender.sh ──rtp/udp:5000──▶ receiver ──[stats] stdout──▶  server.py  ──SSE──▶ browser
  (sim camera)            (spawned by server)              (http :8090)   http://localhost:8090
```

- **`server.py`** — pure standard-library HTTP server. Pushes events to the
  browser over **Server-Sent Events** (no WebSocket dependency; the link is
  push-only, and `EventSource` reconnects on its own). Three data sources, any
  subset: `--synthetic`, `--telemetry-log PATH`, `--receiver-cmd CMD`.
- **`index.html`** — the dashboard. An SVG attitude indicator eased in a
  `requestAnimationFrame` loop, an fps sparkline, a video "monitor" tile that
  breaks up under loss, and an event log. Amber = video, blue = MAVLink — the
  same colour language as the explainer page.
- **`demo_flight.py`** — flies the mock on a repeating cycle (sit → GUIDED →
  arm → take off to 10 m → hold → land) over **one** MAVLink connection that
  carries both the commands and the telemetry, so nothing contends for UDP
  14550. Telemetry is logged with the gateway's own `TelemetryParser` /
  `TelemetryLogger`.

## Run it

Everything runs in WSL (that is where GStreamer and pymavlink live); the browser
is on Windows and reaches it over WSL2's localhost forwarding.

```bash
# build the receiver once, if you haven't:
cd video && cmake -B build && cmake --build build && cd ..

# bring the whole thing up:
wsl -d Ubuntu-22.04 bash dashboard/run.sh
# then open http://localhost:8090/
```

By default the "camera" is a synthetic zone-plate (its whole frame moves, so loss
is visible). To feed a **real video file** instead — e.g. actual drone footage —
set `VIDEO` to its path (a Windows `d:\clip.mp4` or a WSL `/mnt/d/clip.mp4` both
work):

```bash
VIDEO='d:\footage\aerial.mp4' wsl -d Ubuntu-22.04 bash dashboard/run.sh
```

The file is decoded, normalised to 1280×720@30, re-encoded to H.264 and looped,
so the receiver's fps/loss counters mean the same thing they do for the test
pattern. Any container GStreamer can open works (mp4/mov/mkv); the codec must be
one the install can decode — plain **8-bit 4:2:0 H.264** is safest. (The repo's
own `docs/assets/demo.mp4` is 10-bit 4:4:4 H.264 and will *not* decode here — use
your own clip.) This path is for the demo only; it does not touch the
packet-loss measurement, which stays on its frozen synthetic bitstream.

Drive the loss demo while watching the dashboard:

```bash
wsl -d Ubuntu-22.04 -u root bash dashboard/loss.sh on 12%   # inject 12% loss
wsl -d Ubuntu-22.04 -u root bash dashboard/loss.sh off      # clear it
```

Stop everything:

```bash
wsl -d Ubuntu-22.04 bash dashboard/stop.sh
```

To develop the UI with no drone attached, the server generates a scripted flight
on its own:

```bash
python dashboard/server.py --synthetic     # runs on Windows too (stdlib only)
```

## The one honest subtlety on the video side

The loss counter on the dashboard is **`Gói mất · RTP`**, read live from the
rtpjitterbuffer's `num-lost`. The decoder's own **`corrupt`** flag sits right
next to it and stays **0** — on purpose. `avdec_h264` conceals lost slices in
silence; neither `DISCONT` nor `CORRUPTED` is set on a picture that lost data,
up to ~20% loss (measured in [`../video/results/packet-loss.md`](../video/results/packet-loss.md)).
So the jitterbuffer — the last element that sees RTP sequence numbers — is the
only counter that actually moves under loss, and it is the one the dashboard
watches. The receiver was extended to emit `num-lost` once per second for this.

## Files

| file | what it is |
|------|------------|
| `server.py`      | HTTP + SSE server; synthetic / telemetry-tail / receiver-stats producers |
| `index.html`     | the dashboard (SVG ADI, sparkline, monitor tile, event log) |
| `demo_flight.py` | scripted flight over one MAVLink connection, logs telemetry |
| `run.sh`         | bring the whole live demo up |
| `stop.sh`        | stop every process `run.sh` started |
| `loss.sh`        | inject / clear packet loss on the loopback (needs root) |
