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

# Encoder settings live here because sender.sh and gop-stats.sh must agree on
# them: the GOP structure one script measures has to be the GOP structure the
# other script transmits.
#
# tune=zerolatency sets rc-lookahead=0 and switches to sliced threads. It is not
# about B-frames -- x264enc already defaults to bframes=0. Measured: 2067 ms ->
# 4.2 ms of encoder latency (results/latency.md).
ENC_TUNED="x264enc tune=zerolatency speed-preset=ultrafast bitrate=${BITRATE} key-int-max=${KEY_INT_MAX}"

# Stock defaults: 40 frames of rate-control lookahead plus one frame held per
# encoder thread. Roughly two seconds of delay on a 16-core host. This is the
# baseline row of the latency table, not something anyone would ship.
ENC_DEFAULT="x264enc bitrate=${BITRATE}"
