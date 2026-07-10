# mavlink/ — Drone control & telemetry gateway

A Python MAVLink gateway for the ground-station side of a drone link: a **heartbeat
watchdog** on the failsafe interval, **telemetry parsed and scaled to SI** then logged to
CSV and JSONL, and **arm / takeoff / land that read `COMMAND_ACK`** instead of firing and
hoping. An optional MQTT bridge puts the telemetry on a broker.

**What it was tested against.** Both a real **ArduPilot SITL** build (ArduCopter, x86, real
EKF and pre-arm checks, over TCP) and `mock_fc.py`, a small fake flight controller in
`scripts/` used for fast iteration. The command path is validated end to end on SITL:
`takeoff 10` arms and climbs to 10 m, repeatably across cold starts. SITL earned its keep by
catching two bugs the mock had hidden — see [What SITL caught that the mock did
not](#what-sitl-caught-that-the-mock-did-not), which is the whole reason to test against an
independent implementation.

## Architecture

```
  flight controller ── UDP :14550 ──►  gateway  ─┬─► watchdog   3 missed 1 Hz beats -> LINK LOST
  (ArduPilot SITL, or                            ├─► telemetry  parse + scale to SI
   scripts/mock_fc.py)   MAVLink v2              ├─► logger     telemetry.csv + telemetry.jsonl
        ▲                                         └─► MQTT       drone/telemetry           [P2]
        │
        └── COMMAND_LONG (arm/takeoff/land) ── gateway ── COMMAND_ACK ──► verified, not assumed
```

MAVLink is a two-way asymmetric protocol, and the code is split along that seam: telemetry is
streamed by the FC (once a GCS requests the streams — see below) and folded in `telemetry.py`,
while commands are request/ack in `commands.py`. The watchdog (`watchdog.py`) watches the one
message the FC sends unprompted and always: the heartbeat.

## Setup

```bash
pip install -r requirements.txt        # pymavlink; MAVProxy (for SITL); paho-mqtt (for P2)
```

## Run

Terminal 1 — a flight controller to talk to. Either the real thing:

```bash
./scripts/run-sitl.sh                  # ArduPilot SITL on UDP 14550
```

or the fallback, which needs no build and no network:

```bash
python3 scripts/mock_fc.py             # streams HEARTBEAT/ATTITUDE/POSITION/... to 14550
python3 scripts/mock_fc.py --drop-after 8   # ... then goes silent, to trip the watchdog
```

Terminal 2 — the gateway:

```bash
python3 -m gateway.cli monitor         # heartbeat line/s, telemetry logged, watchdog running
python3 -m gateway.cli takeoff 10      # GUIDED -> wait armable -> arm -> climb to 10 m
python3 -m gateway.cli land
python3 -m gateway.cli monitor --mqtt  # also publish to drone/telemetry
```

## The watchdog is the point

Losing the ground-station heartbeat is what triggers a real aircraft's failsafe (RTL/land).
ArduPilot's default GCS-failsafe threshold is about 3 seconds — three missed 1 Hz beats — so
the gateway declares the link lost on the same budget:

```
  hb#1    STABILIZE disarmed  alt   0.0m  12.6V
  hb#2    STABILIZE disarmed  alt   0.0m  12.6V
  hb#3    STABILIZE disarmed  alt   0.0m  12.6V
*** LINK LOST *** no heartbeat for 3.0s
```

The threshold is 3.0 s, and detection lands at the next poll: `monitor` blocks up to 0.5 s
for a message, so the loss is declared 3.0–3.5 s after the last beat (runs here printed both
3.0 and 3.5). Shrink the poll for a tighter bound; it trades CPU for latency.

`watchdog.py` is a small edge-triggered state machine, not a thread: it is `feed()` on every
heartbeat and `check()` on every loop, and its `on_lost` / `on_restored` callbacks fire
exactly once per edge. It takes an injectable clock, so the 3-second *threshold* is
unit-tested exactly — without a test that sleeps for 3 seconds — `tests/test_watchdog.py`,
7 cases including the boundary (a gap *equal* to the timeout is not yet lost) and the
fire-once guarantee.

```bash
python3 tests/test_watchdog.py         # 7/7 passed
```

## Telemetry: the scaling is the whole job

MAVLink sends scaled integers, and getting the scale wrong does not raise — it logs
plausible rubbish. Each field carries the unit it arrives in and the factor applied, in
`telemetry.py`:

| message | field | on the wire | logged as |
|---|---|---|---|
| `HEARTBEAT` | flight mode | `custom_mode` int | name via the vehicle's own `mode_mapping()` |
| `HEARTBEAT` | armed | `base_mode` bit | bool |
| `GLOBAL_POSITION_INT` | lat, lon | `degE7` | degrees (`/1e7`) |
| `GLOBAL_POSITION_INT` | alt, rel_alt | mm | metres (`/1000`) |
| `ATTITUDE` | roll, pitch, yaw | radians | degrees |
| `VFR_HUD` | groundspeed, heading | m/s, deg | unchanged |
| `SYS_STATUS` | battery | mV, % (−1 = unknown) | volts, percent-or-null |

The parser folds every message into one evolving snapshot, so a single log row describes the
whole vehicle even though position, attitude and battery arrive in separate messages. One
captured JSONL line:

```json
{"t_mono": 530737.9, "armed": null, "flight_mode": null, "lat_deg": -35.363262,
 "lon_deg": 149.165237, "alt_m": 584.0, "rel_alt_m": 0.0, "roll_deg": 2.86,
 "yaw_deg": 31.55, "groundspeed_ms": 0.0, "battery_v": 12.589, "battery_pct": 100.0,
 "iso_time": "..."}
```

The line above is from the mock. The committed samples — `logs/telemetry.sample.csv` and
`.jsonl` — are from **real SITL**: lat/lon `-35.363262 / 149.165237`, alt `584.09` m MSL,
attitude in degrees, `12.6` V. CSV and JSONL share one column order (`FIELDS` in
`telemetry.py`), so a spreadsheet row and a JSON line line up. `logs/` is otherwise gitignored.

## Commands are verified, and correctly ordered

A command is not done when it is sent. Every `COMMAND_LONG` is matched to the `COMMAND_ACK`
that names *that* command (not merely the next ack on a wire that is also carrying telemetry),
and the result is surfaced:

```
$ python3 -m gateway.cli arm            # before GUIDED
REFUSED: arm refused: TEMPORARILY_REJECTED     (exit 1)

$ python3 -m gateway.cli arm --guided   # after GUIDED
armed                                          (exit 0)
```

`takeoff` runs the full ArduPilot ordering and stops at the first refusal, so control never
reaches takeoff on a vehicle that failed an earlier step:

```
wait for GPS 3D fix + EKF  ->  GUIDED  ->  arm (retry through the pre-arm window)  ->  NAV_TAKEOFF
```

On **real SITL**, `takeoff 10` arms and climbs to 10 m, repeatably across cold starts:

```
GUIDED -> arm -> takeoff 10.0 m
takeoff accepted; watch alt climb in `monitor`
  hb#3   GUIDED  ARMED  alt  0.0m  12.3V
  hb#6   GUIDED  ARMED  alt  5.6m  12.3V
  hb#9   GUIDED  ARMED  alt 10.0m  12.3V
```

## What SITL caught that the mock did not

SITL is the ArduPilot firmware compiled for x86: the real EKF, controllers and pre-arm checks
against a simulated airframe. Its protocol, timing and *rejection* behaviour are the
hardware's. `mock_fc.py` imitates the slice the gateway touches — 1 Hz heartbeat, streamed
telemetry at realistic rates and units, command acks that enforce the ordering — which is
enough for fast iteration but is **not** independent verification: the mock and the gateway
share one author's reading of the spec, so a shared misunderstanding passes both.

It found two, and they are the point of this section:

1. **ArduPilot does not stream telemetry unasked.** It sends HEARTBEAT and nothing else until
   a GCS sends `REQUEST_DATA_STREAM`. The mock streamed everything from the first packet, so
   the gateway had never needed to ask — and against SITL every telemetry column came back
   null, and the armable check (which reads SYS_STATUS) hung forever. `connection.py` now
   requests the streams on connect.

2. **The sensor-health bits go green before the vehicle can actually arm.** The mock flipped
   its health bits and accepted the arm; SITL flips the same bits several seconds before GPS
   gets a 3D fix and the EKF sets its origin, and rejects the arm as `MAV_RESULT_FAILED` in
   between. A single arm attempt gated on those bits lost the race. `commands.py` now waits on
   a GPS 3D fix and retries the arm through the transient pre-arm window, surfacing the FC's
   own `PreArm:` reason if it never succeeds.

Both fixes also improved the mock — it now streams `GPS_RAW_INT` — so the two paths exercise
the same readiness gate. But a mock alone would never have made me write either fix, because a
mock never says no for a reason you did not anticipate.

## Files

| file | what it is |
|---|---|
| `gateway/connection.py` | open the link, wait for heartbeat, learn the vehicle's system id |
| `gateway/watchdog.py` | edge-triggered link-health state machine, injectable clock |
| `gateway/telemetry.py` | parse + scale to SI; fold into one snapshot; CSV/JSONL logger |
| `gateway/commands.py` | arm/takeoff/land, ack-matched; the correctly-ordered takeoff sequence |
| `gateway/mqtt_bridge.py` | publish snapshots to MQTT, optional (`paho-mqtt`) |
| `gateway/cli.py` | `monitor` / `takeoff` / `land` / `arm` / `disarm` |
| `scripts/mock_fc.py` | fake FC for fast iteration; answers commands, streams GPS/telemetry |
| `scripts/run-sitl.sh` | launch ArduPilot SITL from a built tree |
| `tests/test_watchdog.py` | 7 unit tests for the failsafe logic |

## Known limitations

- Validated on SITL and the mock, both over loopback. **No real radio** — a telemetry radio's
  loss and latency are not exercised here. (The `video/` half of this repo does measure loss,
  on the RTP path.)
- No mission/waypoint protocol, no geofence, no parameter or camera protocols.
- `takeoff` climbs and holds; there is no landing-at-a-point or return-to-launch sequence, and
  disconnecting the GCS after takeoff lets SITL's own GCS-failsafe land the vehicle.
- MQTT bridge is fire-and-publish with a retained last value; no store-and-forward.
