"""The MAVLink link itself: open it, wait for the first heartbeat, learn who is
on the other end.

Everything else in the gateway takes a `mavutil.mavlink_connection` from here.
Keeping the connection in one place means there is one definition of "which
system are we talking to" (the `target_system` / `target_component` a command
must be addressed to) rather than a guess repeated at every call site.
"""
from __future__ import annotations

import time
from dataclasses import dataclass

from pymavlink import mavutil


# ArduPilot's SITL, and a real Pixhawk over a companion link, both default to
# streaming on UDP 14550. `udpin:` means "bind and listen" -- the flight
# controller (or the sim's MAVProxy) is the one that connects out to us.
DEFAULT_ENDPOINT = "udpin:0.0.0.0:14550"


@dataclass
class LinkInfo:
    """Who answered the first heartbeat."""
    system_id: int
    component_id: int
    autopilot: str          # human-readable MAV_AUTOPILOT name
    vehicle_type: str       # human-readable MAV_TYPE name


def _enum_name(enum: str, value: int) -> str:
    """Map an integer back to its MAVLink enum name, e.g. 3 -> QUADROTOR.

    pymavlink ships the enum tables it generated from the XML, so this is the
    same source of truth the wire uses. Fall back to the raw number rather than
    raising: an unknown vehicle type should not stop telemetry.
    """
    try:
        entry = mavutil.mavlink.enums[enum][value]
    except KeyError:
        return f"{enum}:{value}"
    # names look like MAV_TYPE_QUADROTOR; drop the prefix for readability.
    prefix = enum + "_"
    return entry.name[len(prefix):] if entry.name.startswith(prefix) else entry.name


def connect(endpoint: str = DEFAULT_ENDPOINT,
            source_system: int = 255,
            timeout: float | None = 30.0,
            stream_rate_hz: int = 4) -> tuple[mavutil.mavlink_connection, LinkInfo]:
    """Open `endpoint` and block until the first HEARTBEAT arrives.

    source_system=255 is the conventional address for a ground control station,
    which is what this gateway is. The flight controller is a separate system id
    (1 by default in ArduPilot), learned from the heartbeat and returned here.

    Raises TimeoutError if no heartbeat arrives within `timeout` seconds, rather
    than blocking forever -- a link that never comes up is a condition the caller
    should be able to report, not hang on.
    """
    conn = mavutil.mavlink_connection(endpoint, source_system=source_system)

    # wait_heartbeat() with a timeout returns the message, or None on timeout.
    deadline = None if timeout is None else time.monotonic() + timeout
    hb = None
    while hb is None:
        remaining = None if deadline is None else max(0.0, deadline - time.monotonic())
        if remaining is not None and remaining == 0.0:
            raise TimeoutError(
                f"no MAVLink heartbeat on {endpoint} within {timeout:.0f}s")
        hb = conn.wait_heartbeat(timeout=remaining if remaining is not None else 1.0)

    info = LinkInfo(
        system_id=conn.target_system,
        component_id=conn.target_component,
        autopilot=_enum_name("MAV_AUTOPILOT", hb.autopilot),
        vehicle_type=_enum_name("MAV_TYPE", hb.type),
    )
    request_data_streams(conn, rate_hz=stream_rate_hz)
    return conn, info


def request_data_streams(conn: mavutil.mavlink_connection, rate_hz: int = 4) -> None:
    """Ask the flight controller to start streaming telemetry.

    This is the difference between a mock and the real thing. ArduPilot sends
    HEARTBEAT unprompted but stays silent on ATTITUDE, GLOBAL_POSITION_INT,
    VFR_HUD and SYS_STATUS until a GCS asks -- so without this call the telemetry
    columns are all null and, because the armable check reads SYS_STATUS, the
    vehicle never looks armable and takeoff hangs. A mock that streams everything
    by default hides this entirely.

    REQUEST_DATA_STREAM is deprecated in favour of per-message
    SET_MESSAGE_INTERVAL, but ArduPilot honours it, one call covers every stream,
    and it is what most ground stations still send. rate_hz is a request, not a
    guarantee -- the FC caps it.
    """
    conn.mav.request_data_stream_send(
        conn.target_system, conn.target_component,
        mavutil.mavlink.MAV_DATA_STREAM_ALL, rate_hz, 1)  # 1 = start
