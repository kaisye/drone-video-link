#!/usr/bin/env bash
# Stop every process run.sh started. Safe to run repeatedly.
# Patterns match every path variant these commands are launched with.
for pat in \
  'dashboard/server.py' \
  'demo_flight.py' \
  'mock_fc.py' \
  'gateway.cli monitor' \
  'build/receiver' \
  'videotestsrc' \
  'gst-launch-1.0' ; do
  pkill -f "$pat" 2>/dev/null || true
done
echo "stopped."
