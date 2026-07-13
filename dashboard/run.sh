#!/usr/bin/env bash
#
# One command to bring the whole live dashboard up, in WSL:
#
#     wsl -d Ubuntu-22.04 bash dashboard/run.sh
#     # then open http://localhost:8090/ in Windows
#
# It starts four things and wires them together:
#   mock_fc.py       fake flight controller, streams MAVLink on udp:14550
#   demo_flight.py   scripted flight (takeoff/hold/land), logs telemetry.jsonl
#   sender.sh        simulated camera -> H.264 -> RTP on udp:5000
#   server.py        serves the dashboard, tails the telemetry log, spawns the
#                    video receiver and parses its stats
#
# Stop everything with:  bash dashboard/stop.sh
# Inject packet loss:    wsl -d Ubuntu-22.04 -u root bash dashboard/loss.sh on
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PORT="${PORT:-8090}"
cd "$ROOT"

echo "stopping any previous run ..."
bash "$HERE/stop.sh" >/dev/null 2>&1 || true
sleep 0.6

if [ ! -x video/build/receiver ]; then
  echo "!! video/build/receiver not built. Run: cd video && cmake -B build && cmake --build build" >&2
  exit 1
fi

echo "starting mock flight controller ..."
setsid nohup python3 mavlink/scripts/mock_fc.py \
  > /tmp/dvl-mock.log 2>&1 &
sleep 1.2

echo "starting scripted flight (telemetry -> log) ..."
setsid nohup python3 dashboard/demo_flight.py \
  > /tmp/dvl-flight.log 2>&1 &

echo "starting video sender (tee: 5000 for stats, 5001 for the picture) ..."
if [ -n "${VIDEO:-}" ]; then
  # A real clip was requested. Accept a Windows path (d:\clip.mp4) too and map it
  # to the WSL mount, so either form works.
  case "$VIDEO" in
    [A-Za-z]:\\*|[A-Za-z]:/*)
      drive="$(printf '%s' "$VIDEO" | cut -c1 | tr 'A-Z' 'a-z')"
      rest="$(printf '%s' "$VIDEO" | cut -c3- | tr '\\' '/')"
      VIDEO="/mnt/${drive}${rest}"
      ;;
  esac
  echo "  video source: $VIDEO"
  QUIET=1 VIDEO="$VIDEO" TEE_PORT=5001 \
    setsid nohup bash video/scripts/sender.sh \
    > /tmp/dvl-sender.log 2>&1 &
else
  QUIET=1 PATTERN=zone-plate SRC_EXTRA="kx2=20 ky2=20 kt2=1" TEE_PORT=5001 \
    setsid nohup bash video/scripts/sender.sh \
    > /tmp/dvl-sender.log 2>&1 &
fi
sleep 1.2

MJPEG_CMD="gst-launch-1.0 -q udpsrc port=5001 caps=application/x-rtp,media=video,encoding-name=H264,payload=96 ! rtpjitterbuffer latency=50 ! rtph264depay ! avdec_h264 ! videoconvert ! videoscale ! video/x-raw,width=480,height=270 ! jpegenc quality=55 ! fdsink fd=1"

echo "starting dashboard server on :$PORT ..."
setsid nohup python3 dashboard/server.py --port "$PORT" \
  --telemetry-log mavlink/logs/telemetry.jsonl \
  --receiver-cmd "stdbuf -oL video/build/receiver --port 5000" \
  --video-mjpeg-cmd "$MJPEG_CMD" \
  > /tmp/dvl-dash.log 2>&1 &
sleep 2

echo
echo "  dashboard live:  http://localhost:$PORT/"
echo "  logs:            /tmp/dvl-*.log"
echo "  inject loss:     wsl -d Ubuntu-22.04 -u root bash dashboard/loss.sh on"
echo "  stop:            bash dashboard/stop.sh"
echo
tail -n 2 /tmp/dvl-dash.log 2>/dev/null || true
