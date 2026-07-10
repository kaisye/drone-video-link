"""Parse the telemetry messages a GCS actually watches, and scale them to SI.

The trap this module exists to avoid: MAVLink sends scaled integers, not the
values a human wants. Getting the scale wrong does not error -- it logs
plausible-looking rubbish. Every field below carries the unit it arrives in and
the factor applied, because that is the part that is easy to get wrong and
impossible to notice later.

Reference: common.xml message definitions (the same ones pymavlink generated its
classes from).
"""
from __future__ import annotations

import csv
import json
import math
import time
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Optional, TextIO

from pymavlink import mavutil


# The messages worth parsing for a downlink dashboard. Anything else is ignored
# rather than logged, to keep the CSV a fixed, readable width.
WATCHED = {
    "HEARTBEAT",
    "GLOBAL_POSITION_INT",
    "ATTITUDE",
    "VFR_HUD",
    "SYS_STATUS",
}


@dataclass
class TelemetryState:
    """The latest value of each field we track, in SI units.

    One flat record rather than one per message type: a telemetry row is a
    snapshot of the whole aircraft at a moment, and a dashboard or a CSV wants
    every column on every line. Fields stay None until their message arrives.
    """
    t_mono: float = 0.0                      # receiver monotonic timestamp, s

    # HEARTBEAT
    armed: Optional[bool] = None
    flight_mode: Optional[str] = None

    # GLOBAL_POSITION_INT
    lat_deg: Optional[float] = None          # degE7  -> deg
    lon_deg: Optional[float] = None          # degE7  -> deg
    alt_m: Optional[float] = None            # mm MSL -> m
    rel_alt_m: Optional[float] = None        # mm AGL -> m

    # ATTITUDE  (radians on the wire; kept in degrees for humans)
    roll_deg: Optional[float] = None
    pitch_deg: Optional[float] = None
    yaw_deg: Optional[float] = None

    # VFR_HUD
    groundspeed_ms: Optional[float] = None   # already m/s
    heading_deg: Optional[float] = None      # already deg

    # SYS_STATUS
    battery_v: Optional[float] = None        # mV -> V
    battery_pct: Optional[float] = None      # already %, -1 means "unknown"

    def as_dict(self) -> dict:
        return asdict(self)


# CSV/JSONL column order. Defined once so the header and every row agree.
FIELDS = [f for f in TelemetryState.__dataclass_fields__]  # noqa: E501


class TelemetryParser:
    """Folds incoming messages into a running TelemetryState.

    Stateful on purpose: a HEARTBEAT carries mode but not position, a
    GLOBAL_POSITION_INT carries position but not battery. Merging them into one
    evolving snapshot is what lets a single log line describe the whole vehicle.
    """

    def __init__(self, mav: mavutil.mavlink_connection):
        self._mav = mav
        self.state = TelemetryState()

    def update(self, msg, t_mono: float) -> Optional[TelemetryState]:
        """Fold one message in. Returns the updated state if the message was one
        we track, else None (so the caller can skip logging noise).
        """
        mtype = msg.get_type()
        if mtype not in WATCHED:
            return None

        s = self.state
        s.t_mono = t_mono

        if mtype == "HEARTBEAT":
            # base_mode is a bitfield; the ARMED flag is one bit of it.
            s.armed = bool(msg.base_mode
                           & mavutil.mavlink.MAV_MODE_FLAG_SAFETY_ARMED)
            # custom_mode is the ArduPilot flight-mode number; mode_mapping turns
            # it into "GUIDED"/"LOITER"/... for the vehicle we are connected to.
            s.flight_mode = self._flight_mode_name(msg.custom_mode)

        elif mtype == "GLOBAL_POSITION_INT":
            s.lat_deg = msg.lat / 1e7          # degE7
            s.lon_deg = msg.lon / 1e7          # degE7
            s.alt_m = msg.alt / 1000.0         # mm MSL
            s.rel_alt_m = msg.relative_alt / 1000.0  # mm AGL

        elif mtype == "ATTITUDE":
            s.roll_deg = math.degrees(msg.roll)    # rad
            s.pitch_deg = math.degrees(msg.pitch)  # rad
            s.yaw_deg = math.degrees(msg.yaw)      # rad, -pi..pi

        elif mtype == "VFR_HUD":
            s.groundspeed_ms = msg.groundspeed     # m/s
            s.heading_deg = float(msg.heading)     # deg

        elif mtype == "SYS_STATUS":
            s.battery_v = msg.voltage_battery / 1000.0  # mV
            # battery_remaining is a percent, or -1 when the FC cannot estimate.
            s.battery_pct = None if msg.battery_remaining == -1 \
                else float(msg.battery_remaining)

        return s

    def _flight_mode_name(self, custom_mode: int) -> str:
        """ArduPilot flight-mode number -> name, e.g. 4 -> GUIDED.

        The mapping is vehicle-specific (copter vs plane differ), so it is read
        from the connection, which knows the vehicle from its heartbeat.
        """
        mapping = self._mav.mode_mapping() or {}
        # mode_mapping() is name->number; invert it.
        for name, number in mapping.items():
            if number == custom_mode:
                return name
        return str(custom_mode)


class TelemetryLogger:
    """Write each telemetry snapshot to CSV and JSONL at once.

    Two formats because they answer different questions. The CSV opens in a
    spreadsheet and plots; the JSONL keeps full fidelity (nulls stay null, not
    empty strings) and appends one self-describing object per line, which is what
    you want to stream or grep. Both share the one column order in FIELDS, so a
    row in one lines up with a line in the other.

    A wall-clock ISO timestamp is added as the first column, alongside the
    monotonic t_mono the state already carries: monotonic is right for measuring
    durations, wrong for saying when something happened.
    """

    def __init__(self, log_dir: str | Path):
        self._dir = Path(log_dir)
        self._dir.mkdir(parents=True, exist_ok=True)
        self._csv_f: Optional[TextIO] = None
        self._csv_w: Optional["csv._writer"] = None  # type: ignore[name-defined]
        self._jsonl_f: Optional[TextIO] = None
        self._columns = ["iso_time"] + FIELDS

    def __enter__(self) -> "TelemetryLogger":
        self._csv_f = open(self._dir / "telemetry.csv", "w", newline="")
        self._csv_w = csv.writer(self._csv_f)
        self._csv_w.writerow(self._columns)
        self._jsonl_f = open(self._dir / "telemetry.jsonl", "w")
        return self

    def write(self, state: TelemetryState) -> None:
        iso = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime())
        row = state.as_dict()
        row["iso_time"] = iso
        # CSV: None -> "" so empty cells read as empty, not the string "None".
        self._csv_w.writerow(
            ["" if row[c] is None else row[c] for c in self._columns])
        self._csv_f.flush()
        self._jsonl_f.write(json.dumps(row) + "\n")
        self._jsonl_f.flush()

    def __exit__(self, *exc) -> None:
        for f in (self._csv_f, self._jsonl_f):
            if f is not None:
                f.close()
