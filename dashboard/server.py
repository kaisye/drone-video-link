#!/usr/bin/env python3
"""Live dashboard server for the drone video + telemetry link.

Serves a single-page dashboard and pushes two live event streams to it over
Server-Sent Events (SSE): one for the video link, one for MAVLink telemetry.
Pure standard library -- no pip install -- so it runs the same on Windows and
in WSL, wherever the data sources happen to live.

The link is push-only (server -> browser), which is exactly what SSE is for:
no WebSocket dependency, and the browser's EventSource reconnects on its own.

Data sources are chosen by flags; any subset can run at once:

  --synthetic        generate plausible fake events, no drone needed. For
                     developing the UI and demoing the dashboard standalone.
  --telemetry-log P  tail a telemetry.jsonl written by `gateway monitor`
                     (real MAVLink, real SI-scaled numbers).
  --receiver-cmd C   spawn the video receiver and parse its [stats] lines
                     (real fps / discont / corrupt straight from GStreamer).

Every source publishes the same event schema, so index.html does not care
whether a number is synthetic or measured:

  {"kind":"video", "t":epoch, "frames":N, "fps":N, "avg":F,
                   "discont":N, "corrupt":N, "w":W, "h":H}
  {"kind":"mav",   "t":epoch, "armed":bool, "flight_mode":str,
                   "rel_alt_m":F, "roll_deg":F, "pitch_deg":F, "yaw_deg":F,
                   "heading_deg":F, "battery_v":F, "battery_pct":F,
                   "lat_deg":F, "lon_deg":F, "groundspeed_ms":F}
  {"kind":"link",  "channel":"video|mav", "state":"up|lost", "gap":F}
"""
from __future__ import annotations

import argparse
import json
import math
import os
import queue
import re
import shlex
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HTML_PATH = Path(__file__).resolve().parent / "index.html"


# --------------------------------------------------------------------------- #
# Hub: a tiny publish/subscribe fan-out.
#
# Producers (synthetic / telemetry tail / receiver) call publish(); each SSE
# client owns one Queue it drains. `latest` keeps the last event of each kind so
# a browser that connects mid-flight is handed the current state immediately
# instead of a blank panel until the next tick.
# --------------------------------------------------------------------------- #
class Hub:
    def __init__(self) -> None:
        self._subs: set[queue.Queue] = set()
        self._latest: dict[str, dict] = {}
        self._lock = threading.Lock()

    def subscribe(self) -> queue.Queue:
        q: queue.Queue = queue.Queue(maxsize=1000)
        with self._lock:
            self._subs.add(q)
            snapshot = list(self._latest.values())
        for ev in snapshot:
            q.put_nowait(ev)
        return q

    def unsubscribe(self, q: queue.Queue) -> None:
        with self._lock:
            self._subs.discard(q)

    def publish(self, event: dict) -> None:
        # Key the snapshot by kind (and channel, for link events) so each
        # distinct panel keeps its own last value.
        key = event.get("kind", "?")
        if key == "link":
            key = f"link:{event.get('channel')}"
        with self._lock:
            self._latest[key] = event
            subs = list(self._subs)
        for q in subs:
            try:
                q.put_nowait(event)
            except queue.Full:
                # A stalled client must not back-pressure producers: drop its
                # oldest event and keep going.
                try:
                    q.get_nowait()
                    q.put_nowait(event)
                except queue.Empty:
                    pass


# --------------------------------------------------------------------------- #
# HTTP + SSE
# --------------------------------------------------------------------------- #
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    @property
    def hub(self) -> Hub:
        return self.server.hub  # type: ignore[attr-defined]

    def log_message(self, fmt, *args):  # noqa: A003 - quiet the access log
        pass

    def do_GET(self):  # noqa: N802
        if self.path in ("/", "/index.html"):
            self._serve_html()
        elif self.path.startswith("/events"):
            self._serve_events()
        elif self.path.startswith("/video.mjpeg"):
            self._serve_mjpeg()
        elif self.path == "/health":
            self._serve_text("ok")
        else:
            self.send_error(404, "not found")

    def _serve_mjpeg(self):
        src = self.server.mjpeg  # type: ignore[attr-defined]
        if src is None:
            self.send_error(503, "no video source")
            return
        self.send_response(200)
        self.send_header("Content-Type",
                         "multipart/x-mixed-replace; boundary=frame")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        last = 0
        try:
            while True:
                last, frame = src.get(last, timeout=10.0)
                if frame is None:
                    continue
                self.wfile.write(b"--frame\r\nContent-Type: image/jpeg\r\n")
                self.wfile.write(f"Content-Length: {len(frame)}\r\n\r\n".encode())
                self.wfile.write(frame)
                self.wfile.write(b"\r\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass  # browser closed the tab

    def _serve_html(self):
        try:
            body = HTML_PATH.read_bytes()
        except OSError:
            self.send_error(500, "index.html missing")
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(body)

    def _serve_text(self, text: str):
        body = text.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve_events(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()

        q = self.hub.subscribe()
        try:
            self.wfile.write(b"retry: 3000\n\n")
            self.wfile.flush()
            while True:
                try:
                    ev = q.get(timeout=15)
                except queue.Empty:
                    # Keep the connection (and any proxy) from timing out.
                    self.wfile.write(b": ping\n\n")
                    self.wfile.flush()
                    continue
                payload = json.dumps(ev, separators=(",", ":"))
                self.wfile.write(f"data: {payload}\n\n".encode())
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass  # client went away
        finally:
            self.hub.unsubscribe(q)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr, hub: Hub, mjpeg=None):
        super().__init__(addr, Handler)
        self.hub = hub
        self.mjpeg = mjpeg  # MjpegSource or None


# --------------------------------------------------------------------------- #
# Producer 1: synthetic -- a scripted flight, so the dashboard is alive with no
# drone attached. One ~34 s cycle: sit armable, arm, climb to 10 m, hold, land.
# A video loss episode is injected mid-flight so the loss panel actually moves.
# --------------------------------------------------------------------------- #
def synthetic_producer(hub: Hub, stop: threading.Event) -> None:
    t0 = time.monotonic()
    frames = 0
    discont = 0
    corrupt = 0
    jb_lost = 0
    battery_v = 12.6
    fps_hz = 15.0
    period = 1.0 / fps_hz

    CYCLE = 34.0
    while not stop.is_set():
        now = time.monotonic()
        t = now - t0
        c = t % CYCLE  # phase within the cycle

        # --- flight state machine ---
        if c < 6:                      # on the ground, getting armable
            armed, mode, target = False, "GUIDED", 0.0
        elif c < 8:                    # arming
            armed, mode, target = True, "GUIDED", 0.0
        elif c < 24:                   # climb to 10 and hold
            armed, mode, target = True, "GUIDED", 10.0
        else:                          # land
            armed, mode, target = True, "LAND", 0.0

        # altitude eased toward the target so it ramps, never jumps
        if not hasattr(synthetic_producer, "_alt"):
            synthetic_producer._alt = 0.0  # type: ignore[attr-defined]
        alt = synthetic_producer._alt  # type: ignore[attr-defined]
        alt += (target - alt) * 0.04
        alt = max(0.0, alt)
        synthetic_producer._alt = alt  # type: ignore[attr-defined]

        flying = alt > 0.3
        wobble = 1.0 if flying else 0.15
        roll = 9.0 * wobble * math.sin(t * 0.9)
        pitch = 6.0 * wobble * math.sin(t * 0.55 + 1.0)
        yaw = (t * 18.0) % 360.0

        battery_v = max(10.8, 12.6 - t * 0.004)
        battery_pct = max(0.0, 100.0 - t * 0.25)

        hub.publish({
            "kind": "mav", "t": time.time(),
            "armed": armed, "flight_mode": mode,
            "rel_alt_m": round(alt, 2), "alt_m": round(584.0 + alt, 2),
            "roll_deg": round(roll, 2), "pitch_deg": round(pitch, 2),
            "yaw_deg": round(yaw, 2), "heading_deg": round(yaw, 1),
            "groundspeed_ms": round(abs(target - alt) * 0.3, 2),
            "battery_v": round(battery_v, 2), "battery_pct": round(battery_pct, 1),
            "lat_deg": -35.363262, "lon_deg": 149.165237,
        })
        hub.publish({"kind": "link", "channel": "mav", "state": "up", "gap": 0.0})

        # --- video: a loss episode from ~14 s to ~21 s of each cycle ---
        # Mirror the measured reality: under loss the decoder conceals in
        # silence (corrupt/discont stay ~0); the jitterbuffer's num-lost is the
        # counter that actually moves. See results/packet-loss.md.
        lossy = 14.0 <= c < 21.0
        frames += 1
        if lossy:
            fps = 30  # pictures still produced, just damaged (conceal mode)
            if frames % 2 == 0:
                jb_lost += 1
        else:
            fps = 30

        hub.publish({
            "kind": "video", "t": time.time(),
            "frames": frames, "fps": fps, "avg": 29.5,
            "discont": discont, "corrupt": corrupt, "jb_lost": jb_lost,
            "w": 1280, "h": 720,
        })
        hub.publish({"kind": "link", "channel": "video",
                     "state": "up", "gap": 0.0})

        stop.wait(period)


# --------------------------------------------------------------------------- #
# Producer 2: tail a real telemetry.jsonl written by `gateway monitor`.
# Each line is a full evolving snapshot in SI units, so we forward it as-is and
# derive link UP/LOST from how long since the last line arrived.
# --------------------------------------------------------------------------- #
def telemetry_tail_producer(hub: Hub, path: Path, stop: threading.Event,
                            link_timeout: float = 3.0) -> None:
    last_line_at = 0.0
    link_up = False
    f = None
    while not stop.is_set():
        if f is None:
            try:
                f = open(path, "r")
                f.seek(0, os.SEEK_END)  # only new telemetry, not the old log
            except OSError:
                stop.wait(0.5)
                continue
        line = f.readline()
        if line:
            line = line.strip()
            if line:
                try:
                    snap = json.loads(line)
                except json.JSONDecodeError:
                    continue
                snap["kind"] = "mav"
                snap["t"] = time.time()
                hub.publish(snap)
                last_line_at = time.monotonic()
                if not link_up:
                    link_up = True
                    hub.publish({"kind": "link", "channel": "mav",
                                 "state": "up", "gap": 0.0})
            continue

        # `gateway monitor` reopens the log in "w" mode on each start, truncating
        # it. If our read position is now past the file's end, the writer rolled
        # over -- seek back to the top and follow the fresh file.
        try:
            if os.fstat(f.fileno()).st_size < f.tell():
                f.seek(0)
                continue
        except OSError:
            pass

        # no new line right now: idle, and check the link watchdog
        gap = time.monotonic() - last_line_at if last_line_at else 0.0
        if link_up and last_line_at and gap > link_timeout:
            link_up = False
            hub.publish({"kind": "link", "channel": "mav",
                         "state": "lost", "gap": round(gap, 1)})
        stop.wait(0.1)


# --------------------------------------------------------------------------- #
# Producer 3: spawn the video receiver and parse its once-a-second [stats] line.
# --------------------------------------------------------------------------- #
_STATS_RE = re.compile(
    r"frames=(\d+)\s+fps=(\d+)\s+avg=([\d.]+)\s+discont=(\d+)\s+corrupt=(\d+)"
    r"(?:\s+lost=(\d+))?")
_CAPS_RE = re.compile(r"\[caps\]\s+(\d+)x(\d+)")


def receiver_stats_producer(hub: Hub, cmd: list[str],
                            stop: threading.Event) -> None:
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, bufsize=1)
    w = h = 0
    last_stats_at = 0.0
    link_up = False

    def watchdog():
        nonlocal link_up
        while not stop.is_set():
            if last_stats_at and time.monotonic() - last_stats_at > 3.0 and link_up:
                link_up = False
                hub.publish({"kind": "link", "channel": "video",
                             "state": "lost", "gap": 0.0})
            stop.wait(0.5)

    threading.Thread(target=watchdog, daemon=True).start()

    assert proc.stdout is not None
    for line in proc.stdout:
        if stop.is_set():
            break
        mc = _CAPS_RE.search(line)
        if mc:
            w, h = int(mc.group(1)), int(mc.group(2))
            continue
        m = _STATS_RE.search(line)
        if not m:
            continue
        frames, fps, avg, discont, corrupt, lost = m.groups()
        hub.publish({
            "kind": "video", "t": time.time(),
            "frames": int(frames), "fps": int(fps), "avg": float(avg),
            "discont": int(discont), "corrupt": int(corrupt),
            "jb_lost": int(lost) if lost is not None else 0, "w": w, "h": h,
        })
        last_stats_at = time.monotonic()
        if not link_up:
            link_up = True
            hub.publish({"kind": "link", "channel": "video",
                         "state": "up", "gap": 0.0})
    proc.terminate()


# --------------------------------------------------------------------------- #
# MJPEG picture source.
#
# A GStreamer pipeline (spawned separately) decodes the RTP video and writes a
# stream of JPEG frames to its stdout. We read that stream, carve it back into
# individual frames on the JPEG start/end markers (FFD8 .. FFD9), and keep only
# the most recent complete one. Every /video.mjpeg client then pushes that frame
# to its browser at its own pace -- so N browsers cost one decode, not N.
# --------------------------------------------------------------------------- #
class MjpegSource:
    SOI = b"\xff\xd8"  # JPEG start-of-image
    EOI = b"\xff\xd9"  # JPEG end-of-image

    def __init__(self, cmd: list[str]):
        self._cmd = cmd
        self._frame: bytes | None = None
        self._seq = 0
        self._cond = threading.Condition()

    def start(self, stop: threading.Event) -> None:
        threading.Thread(target=self._run, args=(stop,), daemon=True).start()

    def _run(self, stop: threading.Event) -> None:
        while not stop.is_set():
            proc = subprocess.Popen(self._cmd, stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL, bufsize=0)
            buf = bytearray()
            assert proc.stdout is not None
            while not stop.is_set():
                chunk = proc.stdout.read(65536)
                if not chunk:
                    break
                buf.extend(chunk)
                # pull out every complete JPEG currently in the buffer
                while True:
                    soi = buf.find(self.SOI)
                    if soi < 0:
                        del buf[:-1]  # keep a trailing byte for a split marker
                        break
                    eoi = buf.find(self.EOI, soi + 2)
                    if eoi < 0:
                        if soi > 0:
                            del buf[:soi]
                        break
                    frame = bytes(buf[soi:eoi + 2])
                    del buf[:eoi + 2]
                    with self._cond:
                        self._frame = frame
                        self._seq += 1
                        self._cond.notify_all()
            proc.terminate()
            if not stop.is_set():
                stop.wait(1.0)  # pipeline died; back off and respawn

    def get(self, last_seq: int, timeout: float = 10.0):
        """Block until a frame newer than last_seq, or timeout. Returns
        (seq, frame_bytes) -- frame may be None if none has arrived yet."""
        with self._cond:
            if self._seq == last_seq:
                self._cond.wait(timeout)
            return self._seq, self._frame


# --------------------------------------------------------------------------- #
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8090)
    ap.add_argument("--synthetic", action="store_true",
                    help="generate fake events (no drone needed)")
    ap.add_argument("--telemetry-log", type=Path, default=None,
                    help="tail this telemetry.jsonl for real MAVLink data")
    ap.add_argument("--receiver-cmd", default=None,
                    help="command to spawn the video receiver (parsed for stats)")
    ap.add_argument("--video-mjpeg-cmd", default=None,
                    help="command whose stdout is a stream of JPEG frames "
                         "(served live at /video.mjpeg)")
    args = ap.parse_args()

    hub = Hub()
    stop = threading.Event()
    threads: list[threading.Thread] = []

    if args.synthetic:
        threads.append(threading.Thread(
            target=synthetic_producer, args=(hub, stop), daemon=True))
    if args.telemetry_log:
        threads.append(threading.Thread(
            target=telemetry_tail_producer,
            args=(hub, args.telemetry_log, stop), daemon=True))
    if args.receiver_cmd:
        cmd = shlex.split(args.receiver_cmd)
        threads.append(threading.Thread(
            target=receiver_stats_producer, args=(hub, cmd, stop), daemon=True))

    if not threads:
        print("no data source selected; defaulting to --synthetic\n"
              "  (use --telemetry-log and/or --receiver-cmd for real data)")
        threads.append(threading.Thread(
            target=synthetic_producer, args=(hub, stop), daemon=True))

    mjpeg = None
    if args.video_mjpeg_cmd:
        mjpeg = MjpegSource(shlex.split(args.video_mjpeg_cmd))
        mjpeg.start(stop)

    for t in threads:
        t.start()

    server = Server((args.host, args.port), hub, mjpeg=mjpeg)
    url = f"http://localhost:{args.port}/"
    print(f"dashboard live at {url}   (Ctrl-C to stop)", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nstopping", flush=True)
    finally:
        stop.set()
        server.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
