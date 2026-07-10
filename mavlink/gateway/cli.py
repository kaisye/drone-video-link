#!/usr/bin/env python3
"""Gateway entry point.

    python -m gateway.cli monitor                 # stream telemetry + watchdog
    python -m gateway.cli monitor --mqtt          # ... and publish to MQTT
    python -m gateway.cli takeoff 10              # GUIDED -> arm -> climb to 10 m
    python -m gateway.cli land
    python -m gateway.cli arm      / disarm

`monitor` is the long-running mode: it prints one heartbeat line per second,
logs every telemetry snapshot to logs/, and declares LINK LOST within one
failsafe interval of the heartbeats stopping. The command verbs run a sequence
and exit with a non-zero code if the flight controller refused a step.
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

from pymavlink import mavutil

from . import connection
from .watchdog import HeartbeatWatchdog, LinkState
from .telemetry import TelemetryParser, TelemetryLogger
from .commands import Commander, CommandError

LOG_DIR = Path(__file__).resolve().parent.parent / "logs"


def _connect(args):
    print(f"connecting on {args.endpoint} ...", flush=True)
    conn, info = connection.connect(args.endpoint, timeout=args.connect_timeout)
    print(f"heartbeat from system {info.system_id}: "
          f"{info.vehicle_type} / {info.autopilot}", flush=True)
    return conn, info


def cmd_monitor(args) -> int:
    conn, _ = _connect(args)
    parser = TelemetryParser(conn)

    def on_lost(gap: float) -> None:
        print(f"\n*** LINK LOST *** no heartbeat for {gap:.1f}s", flush=True)

    def on_restored(_gap: float) -> None:
        print("\n*** LINK RESTORED ***", flush=True)

    wd = HeartbeatWatchdog(timeout_s=args.link_timeout,
                           on_lost=on_lost, on_restored=on_restored)

    publisher = None
    if args.mqtt:
        publisher = _make_mqtt(args)

    last_report = 0.0
    print(f"monitoring; logging to {LOG_DIR}/  (Ctrl-C to stop)", flush=True)
    try:
        with TelemetryLogger(LOG_DIR) as logger:
            while True:
                msg = conn.recv_match(blocking=True, timeout=0.5)
                now = time.monotonic()

                if msg is not None and msg.get_type() == "HEARTBEAT":
                    wd.feed()
                if msg is not None:
                    state = parser.update(msg, now)
                    if state is not None:
                        logger.write(state)
                        if publisher is not None:
                            publisher.publish(state)

                # tick the watchdog every loop, message or not -- silence is the
                # event it exists to detect.
                wd.check()

                if now - last_report >= 1.0:
                    _print_status(wd, parser)
                    last_report = now
    except KeyboardInterrupt:
        print("\nstopping", flush=True)
        return 0


def _print_status(wd: HeartbeatWatchdog, parser: TelemetryParser) -> None:
    s = parser.state
    if wd.state is LinkState.UP:
        armed = "ARMED" if s.armed else "disarmed"
        alt = f"{s.rel_alt_m:5.1f}m" if s.rel_alt_m is not None else "  ? "
        mode = s.flight_mode or "?"
        batt = f"{s.battery_v:.1f}V" if s.battery_v is not None else "?"
        print(f"  hb#{wd.beats:<4} {mode:<9} {armed:<9} alt {alt}  {batt}",
              flush=True)


def _run_sequence(args, fn) -> int:
    conn, _ = _connect(args)
    cmder = Commander(conn, ack_timeout=args.ack_timeout)
    try:
        fn(cmder)
        return 0
    except CommandError as e:
        print(f"REFUSED: {e}", file=sys.stderr, flush=True)
        return 1


def cmd_takeoff(args) -> int:
    def seq(c: Commander) -> None:
        print(f"GUIDED -> arm -> takeoff {args.altitude} m", flush=True)
        c.guided_takeoff(args.altitude, armable_timeout=args.armable_timeout)
        print("takeoff accepted; watch alt climb in `monitor`", flush=True)
    return _run_sequence(args, seq)


def cmd_land(args) -> int:
    def seq(c: Commander) -> None:
        ack = c.land()
        if not ack:
            raise CommandError(f"land refused: {ack.result_name}")
        print("land accepted", flush=True)
    return _run_sequence(args, seq)


def cmd_arm(args) -> int:
    def seq(c: Commander) -> None:
        if args.guided:
            m = c.set_mode("GUIDED")
            if not m:
                raise CommandError(f"GUIDED refused: {m.result_name}")
        ack = c.arm()
        if not ack:
            raise CommandError(f"arm refused: {ack.result_name}")
        print("armed", flush=True)
    return _run_sequence(args, seq)


def cmd_disarm(args) -> int:
    def seq(c: Commander) -> None:
        ack = c.disarm(force=args.force)
        if not ack:
            raise CommandError(f"disarm refused: {ack.result_name}")
        print("disarmed", flush=True)
    return _run_sequence(args, seq)


def _make_mqtt(args):
    try:
        from .mqtt_bridge import MqttPublisher
    except Exception as e:  # noqa: BLE001
        print(f"--mqtt requested but bridge unavailable: {e}", file=sys.stderr)
        return None
    return MqttPublisher(host=args.mqtt_host, port=args.mqtt_port,
                         topic=args.mqtt_topic)


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="gateway", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--endpoint", default=connection.DEFAULT_ENDPOINT,
                    help=f"MAVLink endpoint (default: {connection.DEFAULT_ENDPOINT})")
    ap.add_argument("--connect-timeout", type=float, default=30.0)
    ap.add_argument("--ack-timeout", type=float, default=3.0)
    sub = ap.add_subparsers(dest="cmd", required=True)

    m = sub.add_parser("monitor", help="stream telemetry, log, run the watchdog")
    m.add_argument("--link-timeout", type=float, default=3.0,
                   help="declare LINK LOST after this many seconds (default 3)")
    m.add_argument("--mqtt", action="store_true", help="also publish to MQTT")
    m.add_argument("--mqtt-host", default="localhost")
    m.add_argument("--mqtt-port", type=int, default=1883)
    m.add_argument("--mqtt-topic", default="drone/telemetry")
    m.set_defaults(func=cmd_monitor)

    t = sub.add_parser("takeoff", help="GUIDED, arm, and climb to ALTITUDE")
    t.add_argument("altitude", type=float, help="metres, relative to home")
    t.add_argument("--armable-timeout", type=float, default=40.0)
    t.set_defaults(func=cmd_takeoff)

    la = sub.add_parser("land", help="switch to LAND")
    la.set_defaults(func=cmd_land)

    a = sub.add_parser("arm", help="arm the vehicle")
    a.add_argument("--guided", action="store_true",
                   help="switch to GUIDED first")
    a.set_defaults(func=cmd_arm)

    d = sub.add_parser("disarm", help="disarm the vehicle")
    d.add_argument("--force", action="store_true")
    d.set_defaults(func=cmd_disarm)

    return ap


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
