"""Commands: arm, takeoff, land -- and read the COMMAND_ACK for each.

The one rule this module is built around: a command is not done when it is sent.
MAVLink commands are request/ack. You send COMMAND_LONG and the flight
controller replies COMMAND_ACK with a result. If you do not read the ack you do
not know whether the aircraft armed, refused to arm, or never heard you. On a
drone that difference is the whole game, so every function here sends and then
waits for the matching ack, and returns whether it was ACCEPTED.

The command *ordering* is also real and unforgiving (ArduPilot copter):

    1. mode -> GUIDED          (offboard commands are ignored in other modes)
    2. wait for the FC to be armable  (EKF/GPS; ~20-30 s in SITL from cold)
    3. arm                     (MAV_CMD_COMPONENT_ARM_DISARM, param1=1)
    4. takeoff                 (MAV_CMD_NAV_TAKEOFF, param7=altitude)

Arm before GUIDED, or takeoff before arm, and the FC returns a non-ACCEPTED ack.
This module surfaces that result rather than swallowing it.
"""
from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Optional

from pymavlink import mavutil


@dataclass
class AckResult:
    accepted: bool
    result: int             # raw MAV_RESULT
    result_name: str        # e.g. "ACCEPTED", "TEMPORARILY_REJECTED"
    command: int
    timed_out: bool = False

    def __bool__(self) -> bool:
        return self.accepted


def _result_name(result: int) -> str:
    try:
        return mavutil.mavlink.enums["MAV_RESULT"][result].name \
            .replace("MAV_RESULT_", "")
    except KeyError:
        return str(result)


class CommandError(RuntimeError):
    """Raised when a required step is refused, so a sequence stops rather than
    charging on to takeoff after a failed arm."""


class Commander:
    def __init__(self, mav: mavutil.mavlink_connection, ack_timeout: float = 3.0):
        self._mav = mav
        self._ack_timeout = ack_timeout

    # --- the primitive: send one command, wait for its ack ------------------
    def _command_long(self, command: int, *params: float,
                      timeout: Optional[float] = None) -> AckResult:
        """Send COMMAND_LONG and wait for the COMMAND_ACK that names this command.

        The ack is matched on its `command` field, not just "the next ack",
        because with telemetry streaming and possibly several commands in flight
        the next COMMAND_ACK on the wire may belong to something else.
        """
        p = list(params) + [0.0] * (7 - len(params))
        self._mav.mav.command_long_send(
            self._mav.target_system, self._mav.target_component,
            command, 0, p[0], p[1], p[2], p[3], p[4], p[5], p[6])

        deadline = time.monotonic() + (timeout or self._ack_timeout)
        while time.monotonic() < deadline:
            ack = self._mav.recv_match(
                type="COMMAND_ACK", blocking=True,
                timeout=max(0.05, deadline - time.monotonic()))
            if ack is None:
                continue
            if ack.command != command:
                continue   # an ack, but for a different command; keep waiting
            return AckResult(
                accepted=(ack.result == mavutil.mavlink.MAV_RESULT_ACCEPTED),
                result=ack.result,
                result_name=_result_name(ack.result),
                command=command)
        return AckResult(False, -1, "NO_ACK", command, timed_out=True)

    # --- public verbs -------------------------------------------------------
    def set_mode(self, mode_name: str, timeout: Optional[float] = None) -> AckResult:
        """Switch flight mode by name (e.g. "GUIDED"). Resolves the name against
        the vehicle's own mapping, so it is correct for copter vs plane."""
        mapping = self._mav.mode_mapping() or {}
        if mode_name not in mapping:
            raise CommandError(
                f"mode {mode_name!r} unknown for this vehicle; "
                f"have {sorted(mapping)}")
        mode_id = mapping[mode_name]
        # DO_SET_MODE param1 is the base-mode flag set, param2 the custom mode.
        return self._command_long(
            mavutil.mavlink.MAV_CMD_DO_SET_MODE,
            mavutil.mavlink.MAV_MODE_FLAG_CUSTOM_MODE_ENABLED, float(mode_id),
            timeout=timeout)

    def arm(self, timeout: Optional[float] = None) -> AckResult:
        return self._command_long(
            mavutil.mavlink.MAV_CMD_COMPONENT_ARM_DISARM, 1, timeout=timeout)

    def arm_with_retry(self, timeout: float = 40.0) -> AckResult:
        """Arm, retrying while the flight controller's pre-arm checks reject it.

        Real ArduPilot refuses to arm (MAV_RESULT_FAILED) for the first several
        seconds after boot, while GPS gets a 3D fix and the EKF sets its origin.
        The refusal is transient, and the sensor-health bits in SYS_STATUS go
        green *before* arming is actually allowed -- so a single arm attempt
        gated only on those bits loses the race. Let the FC be the authority:
        attempt, and on a non-accepted result wait and attempt again, surfacing
        the FC's own PreArm reason if it never succeeds. This is what a human
        operator does, and it needs no fragile model of "ready".
        """
        deadline = time.monotonic() + timeout
        last = AckResult(False, -1, "NO_ATTEMPT", 0, timed_out=True)
        while time.monotonic() < deadline:
            last = self.arm()
            if last:
                return last
            reason = self._recent_prearm_text()
            time.sleep(2.0)  # give pre-arm checks time to pass, then retry
            if reason:
                last.result_name = f"{last.result_name} ({reason})"
        return last

    def _recent_prearm_text(self) -> str:
        """Drain buffered STATUSTEXT and return the newest PreArm line, if any.

        ArduPilot explains an arm refusal in a STATUSTEXT like
        'PreArm: GPS ...'. Reading it turns a bare FAILED into an actionable
        message. Non-blocking: only what has already arrived.
        """
        latest = ""
        while True:
            msg = self._mav.recv_match(type="STATUSTEXT", blocking=False)
            if msg is None:
                break
            if "arm" in msg.text.lower():
                latest = msg.text
        return latest

    def disarm(self, force: bool = False,
               timeout: Optional[float] = None) -> AckResult:
        # param2=21196 is ArduPilot's "force" magic; without it a disarm in
        # flight is refused, which is the safe default.
        return self._command_long(
            mavutil.mavlink.MAV_CMD_COMPONENT_ARM_DISARM,
            0, 21196 if force else 0, timeout=timeout)

    def takeoff(self, altitude_m: float,
                timeout: Optional[float] = None) -> AckResult:
        return self._command_long(
            mavutil.mavlink.MAV_CMD_NAV_TAKEOFF,
            0, 0, 0, 0, 0, 0, float(altitude_m), timeout=timeout)

    def land(self, timeout: Optional[float] = None) -> AckResult:
        return self._command_long(
            mavutil.mavlink.MAV_CMD_NAV_LAND, timeout=timeout)

    # --- the composed, correctly-ordered sequence ---------------------------
    def guided_takeoff(self, altitude_m: float,
                       armable_timeout: float = 40.0) -> None:
        """Wait until ready -> GUIDED -> arm -> takeoff, each verified.

        The order is not cosmetic. GUIDED needs a position estimate, and NAV_
        TAKEOFF needs both GUIDED and a just-armed vehicle. So wait for GPS/EKF
        first, then switch mode, then arm (retrying through the transient pre-arm
        window), then take off. Raises CommandError at the first refused step, so
        control never reaches takeoff on a vehicle that failed an earlier one.
        """
        if not self._wait_until_ready(min(armable_timeout, 30.0)):
            raise CommandError(
                f"GPS/EKF not ready within {min(armable_timeout, 30.0):.0f}s")

        ack = self.set_mode("GUIDED")
        if not ack:
            raise CommandError(f"GUIDED refused: {ack.result_name}")

        ack = self.arm_with_retry(timeout=armable_timeout)
        if not ack:
            raise CommandError(f"arm refused: {ack.result_name}")

        # Re-assert GUIDED: the arm-retry window can be seconds long, and the
        # takeoff below is rejected unless the mode still holds.
        self.set_mode("GUIDED")

        ack = self.takeoff(altitude_m)
        if not ack:
            raise CommandError(f"takeoff refused: {ack.result_name}")

    def _wait_until_ready(self, timeout: float) -> bool:
        """Block until the vehicle has a position estimate good enough to arm.

        The real gate on ArduPilot is a GPS 3D fix plus a converged EKF, not the
        SYS_STATUS sensor-present bits (which go green several seconds earlier,
        which is exactly the race that made a single arm attempt fail). Wait for
        GPS_RAW_INT fix_type >= 3, then a short settle for the EKF to set its
        origin. Fall back to the SYS_STATUS health bits for a flight controller
        (or a mock) that does not stream GPS_RAW_INT.
        """
        need = (mavutil.mavlink.MAV_SYS_STATUS_AHRS
                | mavutil.mavlink.MAV_SYS_STATUS_SENSOR_GPS)
        seen_gps = False   # once we know the FC streams GPS, commit to that gate
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            msg = self._mav.recv_match(
                type=["GPS_RAW_INT", "SYS_STATUS"], blocking=True, timeout=1.0)
            if msg is None:
                continue
            if msg.get_type() == "GPS_RAW_INT":
                seen_gps = True
                if msg.fix_type >= 3:
                    time.sleep(2.0)   # let the EKF set its origin after the fix
                    return True
            elif msg.get_type() == "SYS_STATUS" and not seen_gps and \
                    (msg.onboard_control_sensors_health & need) == need:
                # fallback for a FC (or mock) that does not stream GPS_RAW_INT;
                # skipped entirely once any GPS message has been seen, so it
                # cannot short-circuit the real GPS-fix gate on ArduPilot.
                return True
        return False
