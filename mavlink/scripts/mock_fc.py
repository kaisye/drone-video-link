#!/usr/bin/env python3
"""A minimal fake flight controller, for developing the gateway without SITL.

It speaks just enough MAVLink to exercise every path in the gateway:

    HEARTBEAT            1 Hz, so the watchdog has something to watch
    ATTITUDE             25 Hz, radians -- checks the rad->deg scaling
    GLOBAL_POSITION_INT  4 Hz, degE7 + mm -- checks the position scaling
    VFR_HUD, SYS_STATUS  1 Hz

It also *answers commands*, which is the point that makes it more than a replay:
on COMMAND_LONG it returns a COMMAND_ACK, and it honours the real ArduPilot
ordering constraint -- ARM is rejected unless the mode is GUIDED, TAKEOFF is
rejected unless armed. That is exactly the logic T2.4's gateway must cope with,
so the mock has to enforce it or the gateway would be tested against a pushover.

This is NOT a flight dynamics model. Altitude after takeoff ramps linearly to
the requested height so the logs show it climbing; nothing here is physics.

    python3 mock_fc.py                 # stream to udp:127.0.0.1:14550
    python3 mock_fc.py --drop-after 8  # stop after 8 s, to trip the watchdog
"""
from __future__ import annotations

import argparse
import math
import sys
import time

from pymavlink import mavutil


# Mirror ArduPilot copter's mode numbers for the few we use, so the gateway's
# mode_mapping() lookups resolve to real names.
MODE_STABILIZE = 0
MODE_GUIDED = 4
MODE_LAND = 9

# Seconds before the mock reports its sensors healthy, standing in for the
# EKF/GPS convergence a real vehicle (and SITL) needs before it will arm.
ARMABLE_AFTER_S = 2.0


def main() -> int:
    ap = argparse.ArgumentParser(description="Fake MAVLink flight controller")
    ap.add_argument("--endpoint", default="udpout:127.0.0.1:14550",
                    help="where to send (default: udpout:127.0.0.1:14550)")
    ap.add_argument("--drop-after", type=float, default=None,
                    help="stop sending after N seconds, to test the watchdog")
    ap.add_argument("--sysid", type=int, default=1)
    args = ap.parse_args()

    # line-buffer stdout so the command log is visible live and survives a
    # SIGTERM, instead of dying in a block buffer when the process is killed.
    sys.stdout.reconfigure(line_buffering=True)

    # udpout: we connect out to the gateway's udpin. mavutil handles the framing;
    # source_system=1 makes us look like a flight controller (GCS uses 255).
    mav = mavutil.mavlink_connection(args.endpoint, source_system=args.sysid)

    # --- fake vehicle state --------------------------------------------------
    mode = MODE_STABILIZE
    armed = False
    alt = 0.0            # metres, relative
    target_alt = 0.0
    lat0, lon0 = -35.363262, 149.165237   # ArduPilot's default SITL home
    t0 = time.monotonic()
    last = {"hb": 0.0, "att": 0.0, "pos": 0.0, "hud": 0.0, "sys": 0.0, "gps": 0.0}
    boot_ms = lambda: int((time.monotonic() - t0) * 1000)  # noqa: E731

    print(f"mock FC on {args.endpoint}, sysid {args.sysid}"
          + (f", dropping after {args.drop_after}s" if args.drop_after else ""))

    def base_mode() -> int:
        m = mavutil.mavlink.MAV_MODE_FLAG_CUSTOM_MODE_ENABLED
        if armed:
            m |= mavutil.mavlink.MAV_MODE_FLAG_SAFETY_ARMED
        return m

    while True:
        now = time.monotonic() - t0
        if args.drop_after is not None and now >= args.drop_after:
            print(f"drop-after {args.drop_after}s reached; going silent")
            # keep the process alive but stop sending, so the gateway sees the
            # heartbeat stop rather than the socket close.
            time.sleep(3600)

        # --- answer any pending command -------------------------------------
        msg = mav.recv_match(type="COMMAND_LONG", blocking=False)
        if msg is not None:
            mode, armed, target_alt = _handle_command(
                mav, msg, mode, armed, target_alt, alt)

        # --- climb toward target when armed & guided ------------------------
        # loop runs ~100 Hz (sleep 0.01); 0.02 m/tick ~= 2 m/s, slow enough to
        # watch the altitude ramp in `monitor` rather than jump.
        if armed and mode == MODE_GUIDED and alt < target_alt:
            alt = min(target_alt, alt + 0.02)
        if mode == MODE_LAND and alt > 0:
            alt = max(0.0, alt - 0.02)

        # --- stream telemetry at each rate ----------------------------------
        if now - last["hb"] >= 1.0:
            mav.mav.heartbeat_send(
                mavutil.mavlink.MAV_TYPE_QUADROTOR,
                mavutil.mavlink.MAV_AUTOPILOT_ARDUPILOTMEGA,
                base_mode(), mode, mavutil.mavlink.MAV_STATE_ACTIVE)
            last["hb"] = now

        if now - last["att"] >= 0.04:   # 25 Hz
            # gentle wobble so roll/pitch/yaw are visibly non-zero in the log.
            mav.mav.attitude_send(
                boot_ms(),
                0.05 * math.sin(now),          # roll  (rad)
                0.03 * math.cos(now * 0.7),    # pitch (rad)
                math.radians((now * 20) % 360),  # yaw sweeps (rad)
                0.0, 0.0, 0.0)
            last["att"] = now

        if now - last["gps"] >= 0.25:   # 4 Hz
            # No fix during the warm-up, then a 3D fix -- so the gateway's
            # GPS-fix readiness gate (the one real SITL needs) is exercised here
            # too, not just the SYS_STATUS fallback.
            fix = 3 if now >= ARMABLE_AFTER_S else 0
            mav.mav.gps_raw_int_send(
                boot_ms(), fix,
                int(lat0 * 1e7), int(lon0 * 1e7), int((584 + alt) * 1000),
                65535, 65535, 0, 0, 10 if fix >= 3 else 0)
            last["gps"] = now

        if now - last["pos"] >= 0.25:   # 4 Hz
            mav.mav.global_position_int_send(
                boot_ms(),
                int(lat0 * 1e7), int(lon0 * 1e7),
                int((584 + alt) * 1000),       # alt MSL, mm (Canberra ~584 m)
                int(alt * 1000),               # relative alt, mm
                0, 0, 0,                        # velocity, cm/s
                int((now * 20) % 360 * 100))   # heading, cdeg
            last["pos"] = now

        if now - last["hud"] >= 1.0:
            mav.mav.vfr_hud_send(
                0.0, 0.0, int((now * 20) % 360), 0, alt, 0.0)
            last["hud"] = now

        if now - last["sys"] >= 1.0:
            # 12.6 V pack sagging slowly; percentage counts down from 100.
            v = 12.6 - min(2.0, now * 0.01)
            pct = max(0, 100 - int(now * 0.2))
            # Report the sensors the gateway's armable check looks for as healthy,
            # but only after a short warm-up, so the arm/takeoff path exercises
            # the real "wait until armable" wait rather than skipping it.
            health = 0
            if now >= ARMABLE_AFTER_S:
                health = (mavutil.mavlink.MAV_SYS_STATUS_AHRS
                          | mavutil.mavlink.MAV_SYS_STATUS_SENSOR_GPS
                          | mavutil.mavlink.MAV_SYS_STATUS_SENSOR_3D_GYRO
                          | mavutil.mavlink.MAV_SYS_STATUS_SENSOR_3D_ACCEL)
            mav.mav.sys_status_send(
                health, health, health, 0,
                int(v * 1000), -1, pct,
                0, 0, 0, 0, 0, 0)
            last["sys"] = now

        time.sleep(0.01)


def _handle_command(mav, msg, mode, armed, target_alt, alt):
    """Enforce ArduPilot's real command-ordering rules and ACK accordingly."""
    cmd = msg.command
    ACCEPTED = mavutil.mavlink.MAV_RESULT_ACCEPTED
    DENIED = mavutil.mavlink.MAV_RESULT_DENIED
    TEMP = mavutil.mavlink.MAV_RESULT_TEMPORARILY_REJECTED

    result = ACCEPTED

    if cmd == mavutil.mavlink.MAV_CMD_DO_SET_MODE:
        mode = int(msg.param2)
        print(f"  <- SET_MODE {mode}")
    elif cmd == mavutil.mavlink.MAV_CMD_COMPONENT_ARM_DISARM:
        want_arm = msg.param1 == 1
        if want_arm and mode != MODE_GUIDED:
            result = TEMP   # ArduPilot refuses arming outside an armable mode
            print("  <- ARM refused: not in GUIDED")
        else:
            armed = want_arm
            print(f"  <- {'ARM' if want_arm else 'DISARM'} ok")
    elif cmd == mavutil.mavlink.MAV_CMD_NAV_TAKEOFF:
        if not armed:
            result = DENIED
            print("  <- TAKEOFF denied: not armed")
        else:
            target_alt = float(msg.param7)
            print(f"  <- TAKEOFF to {target_alt} m")
    elif cmd == mavutil.mavlink.MAV_CMD_NAV_LAND:
        mode = MODE_LAND
        print("  <- LAND")
    else:
        result = mavutil.mavlink.MAV_RESULT_UNSUPPORTED

    mav.mav.command_ack_send(cmd, result)
    return mode, armed, target_alt


if __name__ == "__main__":
    raise SystemExit(main())
