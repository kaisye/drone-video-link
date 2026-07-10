#!/usr/bin/env bash
#
# Launch ArduPilot SITL and fan its MAVLink link out to UDP 14550 for the
# gateway. Run from a checked-out, built ardupilot tree (see the note below).
#
#   ./scripts/run-sitl.sh              # ArduCopter, default location
#   VEHICLE=ArduPlane ./scripts/run-sitl.sh
#
# sim_vehicle.py is ArduPilot's own launcher: it starts the firmware built for
# x86, wraps it in MAVProxy, and --out forwards the stream to our port. The
# gateway then binds udpin:0.0.0.0:14550, which is its default.
set -euo pipefail

VEHICLE="${VEHICLE:-ArduCopter}"
OUT="${OUT:-udp:127.0.0.1:14550}"
ARDUPILOT="${ARDUPILOT:-$HOME/ardupilot}"

if [ ! -x "$ARDUPILOT/Tools/autotest/sim_vehicle.py" ]; then
  cat >&2 <<EOF
ArduPilot not found at $ARDUPILOT.

  git clone --recurse-submodules https://github.com/ArduPilot/ardupilot
  cd ardupilot && ./waf configure --board sitl && ./waf copter

Then set ARDUPILOT=/path/to/ardupilot, or run this from there. No board and no
build handy? Use the fallback instead -- it needs neither:

  python3 scripts/mock_fc.py
EOF
  exit 1
fi

# --map --console are ArduPilot's GUIs; omit them for a headless run.
exec "$ARDUPILOT/Tools/autotest/sim_vehicle.py" \
  -v "$VEHICLE" --out="$OUT" --no-rebuild "$@"
