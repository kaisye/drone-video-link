# mavlink/ — Drone control & telemetry gateway

A Python MAVLink gateway against **ArduPilot SITL**: heartbeat watchdog, arm/takeoff/land
with `COMMAND_ACK` verification, telemetry parsing and structured logging.

> Status: **not implemented yet.** See [../docs/01-PLAN.md](../docs/01-PLAN.md) tasks T2.1–T2.6.

## Architecture

```
 ArduPilot SITL ── UDP :14550 ──► gateway
   (simulated FC)   MAVLink v2      ├── watchdog: 3 missed heartbeats → LINK LOST
        ▲                           ├── telemetry.csv / telemetry.jsonl
        │                           └── MQTT → drone/telemetry
        └── COMMAND_LONG ───────────┘
        ┌── COMMAND_ACK ────────────►
```

## Setup

```bash
pip install -r requirements.txt
./scripts/run-sitl.sh              # or: python scripts/mock_fc.py  (fallback)
```

## Run

```bash
python gateway/cli.py monitor       # heartbeat + live telemetry
python gateway/cli.py takeoff 10    # GUIDED → arm → takeoff to 10 m
python gateway/cli.py land
```

## Telemetry captured

| Message | Fields | Unit conversion |
|---|---|---|
| `HEARTBEAT` | flight mode, armed | — |
| `GLOBAL_POSITION_INT` | lat, lon, relative_alt | `degE7 / 1e7`, `mm / 1000` |
| `ATTITUDE` | roll, pitch, yaw | rad → deg |
| `VFR_HUD` | groundspeed | m/s |
| `SYS_STATUS` | battery voltage | `mV / 1000` |

Logged to `logs/telemetry.jsonl` and `logs/telemetry.csv`.

## Command safety

Commands are **not** fire-and-forget. Each `COMMAND_LONG` is matched against its
`COMMAND_ACK`, and the gateway distinguishes `ACCEPTED` / `TEMPORARILY_REJECTED` / `DENIED`
so a rejected pre-arm check is surfaced rather than silently ignored.

The takeoff sequence enforces the required ordering: set `GUIDED` → wait for EKF/GPS →
arm → `MAV_CMD_NAV_TAKEOFF`. Skipping a step causes the flight controller to reject the
command.

## Why SITL

SITL is the ArduPilot firmware itself, compiled for x86 instead of ARM. It runs the real
EKF, controllers and pre-arm checks against a simulated airframe — the protocol, timing and
rejection behaviour are identical to hardware. It is the standard development workflow, not
a substitute for one.

## Known limitations

- No real radio link: MAVLink runs over loopback UDP, so packet loss and latency of a real
  telemetry radio are not exercised.
- No mission/waypoint protocol, no geofence, no camera (MAVLink camera protocol) support.
