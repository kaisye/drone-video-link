#!/usr/bin/env python3
"""Autonomous scripted flight against the mock FC, for the live dashboard.

One MAVLink connection carries BOTH the commands and the telemetry, so nothing
contends for UDP 14550 (which is why `gateway monitor` and `gateway takeoff`
cannot run at once). The telemetry is logged exactly the way `monitor` logs it,
to the same telemetry.jsonl the dashboard tails -- so what the browser shows is
the real gateway parser's output, not a second implementation.

The flight repeats on a fixed cycle so a demo left running keeps moving:

    sit (armable) -> GUIDED -> arm -> take off to 10 m -> hold -> land -> repeat

Commands are fired and forgotten; their effect is observed in the telemetry the
mock streams back (altitude climbing), which is the whole point of the loop.
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "mavlink"))

from pymavlink import mavutil  # noqa: E402
from gateway import connection  # noqa: E402
from gateway.telemetry import TelemetryParser, TelemetryLogger  # noqa: E402

LOG_DIR = ROOT / "mavlink" / "logs"
GUIDED = 4
CYCLE_S = 40.0
TAKEOFF_ALT = 10.0


def _cmd(conn, command, *params):
    p = list(params) + [0.0] * (7 - len(params))
    conn.mav.command_long_send(conn.target_system, conn.target_component,
                               command, 0, *p)


def set_guided(conn):
    _cmd(conn, mavutil.mavlink.MAV_CMD_DO_SET_MODE,
         mavutil.mavlink.MAV_MODE_FLAG_CUSTOM_MODE_ENABLED, GUIDED)


def arm(conn):
    _cmd(conn, mavutil.mavlink.MAV_CMD_COMPONENT_ARM_DISARM, 1)


def takeoff(conn, alt):
    _cmd(conn, mavutil.mavlink.MAV_CMD_NAV_TAKEOFF, 0, 0, 0, 0, 0, 0, alt)


def land(conn):
    _cmd(conn, mavutil.mavlink.MAV_CMD_NAV_LAND)


def main() -> int:
    print(f"connecting on {connection.DEFAULT_ENDPOINT} ...", flush=True)
    conn, info = connection.connect(connection.DEFAULT_ENDPOINT, timeout=30.0)
    print(f"connected: system {info.system_id} "
          f"{info.vehicle_type}/{info.autopilot}", flush=True)

    parser = TelemetryParser(conn)
    t0 = time.monotonic()
    fired: set[tuple[int, str]] = set()

    # scheduled command edges within each cycle: (seconds, tag, action)
    schedule = [
        (6.0, "guided", set_guided),
        (6.4, "arm", arm),
        (7.0, "takeoff", lambda c: takeoff(c, TAKEOFF_ALT)),
        (30.0, "land", land),
    ]

    with TelemetryLogger(LOG_DIR) as logger:
        while True:
            msg = conn.recv_match(blocking=True, timeout=0.2)
            now = time.monotonic()
            if msg is not None:
                state = parser.update(msg, now)
                if state is not None:
                    logger.write(state)

            elapsed = now - t0
            cycle_id = int(elapsed // CYCLE_S)
            phase = elapsed % CYCLE_S
            for when, tag, action in schedule:
                key = (cycle_id, tag)
                if phase >= when and key not in fired:
                    fired.add(key)
                    action(conn)
                    print(f"[flight] cycle {cycle_id}: {tag}", flush=True)
            # keep `fired` from growing without bound over a long demo
            if len(fired) > 64:
                fired = {k for k in fired if k[0] >= cycle_id - 1}


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        pass
