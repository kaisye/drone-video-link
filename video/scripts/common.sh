# Shared configuration. Sourced by every script in this directory.
# Network constants live here only -- never inline in a pipeline.

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-5000}"

WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
FPS="${FPS:-30}"
BITRATE="${BITRATE:-2000}"

# One keyframe per second at 30fps. This number sets the worst-case recovery
# time after packet loss -- see results/packet-loss.md.
KEY_INT_MAX="${KEY_INT_MAX:-30}"

# RTP dynamic payload type for H.264. 96 is the first value in the dynamic
# range (96-127); the receiver must be told the same number because RTP
# carries no format description of its own.
PT=96

RTP_CAPS="application/x-rtp,media=video,encoding-name=H264,payload=${PT}"
