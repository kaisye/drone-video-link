// Ground-station receiver: RTP/UDP -> H.264 -> raw frames handed to application code.
//
// The point of this file is the appsink boundary. Everything upstream of it is a
// GStreamer pipeline that gst-launch could also run; everything downstream is ours.
// On a real ground station this is where frames would go to a display, a recorder,
// or a TensorRT inference engine.

#include <gst/gst.h>
#include <gst/app/gstappsink.h>
#include <glib-unix.h>

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace {

struct Options {
    int  port           = 5000;
    int  jitter_latency = 0;      // ms; 0 = hand packets on immediately
    bool sync           = false;  // false = render on arrival, ignore PTS
    bool verbose        = false;  // print one line per frame
    bool lost_events    = true;   // jitterbuffer announces gaps downstream
    bool wait_keyframe  = false;  // after a loss, output nothing until the next IDR
};

struct Stats {
    std::atomic<guint64> frames{0};
    std::atomic<guint64> bytes{0};
    std::atomic<guint64> discontinuities{0};
    std::atomic<guint64> corrupted{0};

    // Written only from the streaming thread, read from the main-loop timer.
    // A torn read costs us a wrong digit in a log line, nothing more.
    gint     width  = 0;
    gint     height = 0;
    gint     fps_n  = 0;
    gint     fps_d  = 1;
    GstClockTime first_pts = GST_CLOCK_TIME_NONE;
    GstClockTime last_pts  = GST_CLOCK_TIME_NONE;

    guint64 frames_at_last_tick = 0;
    gint64  wall_start_us       = 0;
};

struct Context {
    Options    opts;
    Stats      stats;
    GMainLoop *loop     = nullptr;
    GstElement *pipeline = nullptr;  // borrowed, for live jitterbuffer stats
};

// num-lost from the jitterbuffer -- the only counter that tracks loss while the
// decoder conceals it in silence (DISCONT/CORRUPTED stay clear up to ~20% loss,
// see results/packet-loss.md). Read live each tick so a dashboard can watch it.
guint64 read_jb_lost(GstElement *pipeline) {
    if (!pipeline) return 0;
    GstElement *jb = gst_bin_get_by_name(GST_BIN(pipeline), "jbuf");
    if (!jb) return 0;
    GstStructure *s = nullptr;
    g_object_get(jb, "stats", &s, nullptr);
    guint64 lost = 0;
    if (s) {
        gst_structure_get_uint64(s, "num-lost", &lost);
        gst_structure_free(s);
    }
    gst_object_unref(jb);
    return lost;
}

void read_caps_once(Context *ctx, GstSample *sample) {
    if (ctx->stats.width != 0) return;

    GstCaps *caps = gst_sample_get_caps(sample);
    if (!caps) return;

    const GstStructure *s = gst_caps_get_structure(caps, 0);
    gst_structure_get_int(s, "width", &ctx->stats.width);
    gst_structure_get_int(s, "height", &ctx->stats.height);
    gst_structure_get_fraction(s, "framerate", &ctx->stats.fps_n, &ctx->stats.fps_d);

    g_print("[caps] %dx%d @ %d/%d fps, format=%s\n",
            ctx->stats.width, ctx->stats.height,
            ctx->stats.fps_n, ctx->stats.fps_d,
            gst_structure_get_string(s, "format"));
}

// Runs on the streaming thread, once per decoded frame.
GstFlowReturn on_new_sample(GstAppSink *appsink, gpointer user_data) {
    auto *ctx = static_cast<Context *>(user_data);

    GstSample *sample = gst_app_sink_pull_sample(appsink);
    if (!sample) return GST_FLOW_EOS;

    read_caps_once(ctx, sample);

    GstBuffer *buf = gst_sample_get_buffer(sample);  // borrowed, do not unref
    if (buf) {
        GstMapInfo map;
        if (gst_buffer_map(buf, &map, GST_MAP_READ)) {
            ctx->stats.bytes += map.size;
            // Real work on the frame would happen here, on map.data.
            gst_buffer_unmap(buf, &map);
        }

        const GstClockTime pts = GST_BUFFER_PTS(buf);
        if (GST_CLOCK_TIME_IS_VALID(pts)) {
            if (!GST_CLOCK_TIME_IS_VALID(ctx->stats.first_pts))
                ctx->stats.first_pts = pts;
            ctx->stats.last_pts = pts;
        }

        const guint64 n = ++ctx->stats.frames;

        // DISCONT means "this buffer does not continue the previous one", not
        // "the data is damaged". It only appears here if the jitterbuffer was
        // told to announce gaps (do-lost=true); with the default it stays clear
        // even when two thirds of the stream never arrives. Measured, painfully.
        // The very first buffer always carries it -- a stream starts
        // discontinuous -- so counting it would make the clean baseline 1, not 0.
        if (n > 1 && GST_BUFFER_FLAG_IS_SET(buf, GST_BUFFER_FLAG_DISCONT))
            ctx->stats.discontinuities++;

        // CORRUPTED is the decoder's own verdict: it produced this picture from
        // an incomplete bitstream. This is the flag that actually tracks loss.
        if (GST_BUFFER_FLAG_IS_SET(buf, GST_BUFFER_FLAG_CORRUPTED))
            ctx->stats.corrupted++;

        if (ctx->opts.verbose) {
            g_print("[frame %6" G_GUINT64_FORMAT "] %dx%d  pts=%" GST_TIME_FORMAT "  size=%zu\n",
                    n, ctx->stats.width, ctx->stats.height,
                    GST_TIME_ARGS(pts), gst_buffer_get_size(buf));
        }
    }

    // pull_sample returns a reference. Forgetting this unref is the classic
    // GStreamer leak: RSS climbs steadily until the OOM killer intervenes.
    gst_sample_unref(sample);
    return GST_FLOW_OK;
}

gboolean on_stats_tick(gpointer user_data) {
    auto *ctx = static_cast<Context *>(user_data);

    const guint64 total = ctx->stats.frames.load();
    const guint64 delta = total - ctx->stats.frames_at_last_tick;
    ctx->stats.frames_at_last_tick = total;

    const gint64 elapsed_us = g_get_monotonic_time() - ctx->stats.wall_start_us;
    const double avg_fps = elapsed_us > 0 ? total * 1e6 / elapsed_us : 0.0;

    g_print("[stats] frames=%" G_GUINT64_FORMAT "  fps=%" G_GUINT64_FORMAT
            "  avg=%.2f  discont=%" G_GUINT64_FORMAT "  corrupt=%" G_GUINT64_FORMAT
            "  lost=%" G_GUINT64_FORMAT "  last_pts=%" GST_TIME_FORMAT "\n",
            total, delta, avg_fps, ctx->stats.discontinuities.load(),
            ctx->stats.corrupted.load(), read_jb_lost(ctx->pipeline),
            GST_TIME_ARGS(ctx->stats.last_pts));

    return G_SOURCE_CONTINUE;
}

// The jitterbuffer is the only element that sees RTP sequence numbers, so it is
// the only element that can say how many packets never arrived. Everything
// downstream sees pictures, and a picture missing one slice still looks like a
// picture. Read this before going to NULL: the counters do not survive the
// state change.
void print_jitterbuffer_stats(GstElement *pipeline) {
    GstElement *jb = gst_bin_get_by_name(GST_BIN(pipeline), "jbuf");
    if (!jb) return;

    GstStructure *s = nullptr;
    g_object_get(jb, "stats", &s, nullptr);
    if (s) {
        gchar *txt = gst_structure_to_string(s);
        g_print("[jitterbuf] %s\n", txt);
        g_free(txt);
        gst_structure_free(s);
    }
    gst_object_unref(jb);
}

gboolean on_bus_message(GstBus *, GstMessage *msg, gpointer user_data) {
    auto *ctx = static_cast<Context *>(user_data);

    switch (GST_MESSAGE_TYPE(msg)) {
    case GST_MESSAGE_ERROR: {
        GError *err = nullptr;
        gchar  *dbg = nullptr;
        gst_message_parse_error(msg, &err, &dbg);
        g_printerr("[error] from %s: %s\n", GST_OBJECT_NAME(msg->src), err->message);
        if (dbg) g_printerr("[debug] %s\n", dbg);
        g_clear_error(&err);
        g_free(dbg);
        g_main_loop_quit(ctx->loop);
        break;
    }
    case GST_MESSAGE_WARNING: {
        GError *err = nullptr;
        gchar  *dbg = nullptr;
        gst_message_parse_warning(msg, &err, &dbg);
        g_printerr("[warn ] from %s: %s\n", GST_OBJECT_NAME(msg->src), err->message);
        g_clear_error(&err);
        g_free(dbg);
        break;
    }
    case GST_MESSAGE_EOS:
        g_print("[eos  ] end of stream\n");
        g_main_loop_quit(ctx->loop);
        break;
    default:
        break;
    }
    return G_SOURCE_CONTINUE;
}

gboolean on_sigint(gpointer user_data) {
    auto *ctx = static_cast<Context *>(user_data);
    g_print("\n[sigint] shutting down\n");
    g_main_loop_quit(ctx->loop);
    return G_SOURCE_REMOVE;
}

void print_usage(const char *argv0) {
    g_print("usage: %s [--port N] [--jitter-latency MS] [--sync]\n"
            "          [--no-lost-events] [--wait-for-keyframe] [--verbose]\n\n"
            "  --port N            UDP port to listen on            (default 5000)\n"
            "  --jitter-latency MS rtpjitterbuffer depth            (default 0)\n"
            "  --sync              honour buffer PTS at the sink    (default off)\n"
            "  --no-lost-events    jitterbuffer stays silent about gaps (do-lost=false)\n"
            "  --wait-for-keyframe drop pictures after a loss until the next IDR\n"
            "  --verbose           print one line per frame\n",
            argv0);
}

bool parse_args(int argc, char **argv, Options *o) {
    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        auto next_int = [&](int *dst) {
            if (i + 1 >= argc) return false;
            *dst = std::atoi(argv[++i]);
            return true;
        };
        if (a == "--port") { if (!next_int(&o->port)) return false; }
        else if (a == "--jitter-latency") { if (!next_int(&o->jitter_latency)) return false; }
        else if (a == "--sync") { o->sync = true; }
        else if (a == "--no-lost-events") { o->lost_events = false; }
        else if (a == "--wait-for-keyframe") { o->wait_keyframe = true; }
        else if (a == "--verbose" || a == "-v") { o->verbose = true; }
        else if (a == "--help" || a == "-h") { print_usage(argv[0]); std::exit(0); }
        else { g_printerr("unknown argument: %s\n", a.c_str()); return false; }
    }
    return true;
}

}  // namespace

int main(int argc, char **argv) {
    gst_init(&argc, &argv);

    Context ctx;
    if (!parse_args(argc, argv, &ctx.opts)) {
        print_usage(argv[0]);
        return 1;
    }

    // udpsrc cannot negotiate caps: an RTP header names a payload type number, not a
    // format. Sender and receiver agree on 96 out of band -- SDP does this in production.
    // buffer-size raises the kernel receive buffer: a stalled reader must not be
    // mistaken for a lossy network. do-lost makes the jitterbuffer emit an event
    // on every sequence gap, which is what lets the decoder flag the damage.
    //
    // wait-for-keyframe picks the failure mode. Off (default): the decoder is
    // handed the surviving slices and conceals the hole, so the operator sees a
    // damaged picture. On: the depayloader emits nothing until the next IDR, so
    // the operator sees the last good picture frozen. Neither is free, and which
    // one a drone wants depends on whether a wrong pixel is worse than no pixel.
    gchar *desc = g_strdup_printf(
        "udpsrc port=%d buffer-size=4194304 "
        "caps=\"application/x-rtp,media=video,encoding-name=H264,payload=96\" ! "
        "rtpjitterbuffer name=jbuf latency=%d do-lost=%s ! "
        "rtph264depay wait-for-keyframe=%s ! "
        "avdec_h264 ! "
        "videoconvert ! video/x-raw,format=I420 ! "
        "appsink name=sink sync=%s max-buffers=2 drop=true",
        ctx.opts.port, ctx.opts.jitter_latency,
        ctx.opts.lost_events ? "true" : "false",
        ctx.opts.wait_keyframe ? "true" : "false",
        ctx.opts.sync ? "true" : "false");

    GError *err = nullptr;
    GstElement *pipeline = gst_parse_launch(desc, &err);
    g_free(desc);
    if (!pipeline) {
        g_printerr("failed to build pipeline: %s\n", err ? err->message : "unknown");
        g_clear_error(&err);
        return 1;
    }

    ctx.pipeline = pipeline;

    GstElement *sink = gst_bin_get_by_name(GST_BIN(pipeline), "sink");
    GstAppSinkCallbacks callbacks = {};
    callbacks.new_sample = on_new_sample;
    gst_app_sink_set_callbacks(GST_APP_SINK(sink), &callbacks, &ctx, nullptr);

    ctx.loop = g_main_loop_new(nullptr, FALSE);

    GstBus *bus = gst_element_get_bus(pipeline);
    gst_bus_add_watch(bus, on_bus_message, &ctx);

    g_unix_signal_add(SIGINT, on_sigint, &ctx);
    ctx.stats.wall_start_us = g_get_monotonic_time();
    g_timeout_add_seconds(1, on_stats_tick, &ctx);

    if (gst_element_set_state(pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
        g_printerr("failed to start pipeline\n");
        return 1;
    }

    g_print("receiver: listening on udp/%d  jitter=%dms  sync=%s  on-loss=%s\n",
            ctx.opts.port, ctx.opts.jitter_latency, ctx.opts.sync ? "on" : "off",
            ctx.opts.wait_keyframe ? "drop-until-keyframe" : "conceal");

    g_main_loop_run(ctx.loop);

    print_jitterbuffer_stats(pipeline);
    gst_element_set_state(pipeline, GST_STATE_NULL);

    const guint64 frames = ctx.stats.frames.load();
    const gint64  us     = g_get_monotonic_time() - ctx.stats.wall_start_us;
    g_print("[summary] frames=%" G_GUINT64_FORMAT "  bytes=%" G_GUINT64_FORMAT
            "  discont=%" G_GUINT64_FORMAT "  corrupt=%" G_GUINT64_FORMAT
            "  elapsed=%.1fs  avg_fps=%.2f\n",
            frames, ctx.stats.bytes.load(), ctx.stats.discontinuities.load(),
            ctx.stats.corrupted.load(), us / 1e6, us > 0 ? frames * 1e6 / us : 0.0);

    gst_object_unref(bus);
    gst_object_unref(sink);
    gst_object_unref(pipeline);
    g_main_loop_unref(ctx.loop);
    return 0;
}
