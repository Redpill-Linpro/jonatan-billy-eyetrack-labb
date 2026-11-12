//! The tracking loop: camera frame -> face landmarks -> pose -> opentrack.
const std = @import("std");
const Io = std.Io;
const blink = @import("blink.zig");
const capture = @import("capture.zig");
const Config = @import("config.zig").Config;
const linalg = @import("linalg.zig");
const mediapipe = @import("mediapipe.zig");
const monitor = @import("monitor.zig");
const OneEuro = @import("filter.zig").OneEuro;
const opentrack = @import("opentrack.zig");
const pose = @import("pose.zig");

pub const Error = error{ CameraStopped, StdinClosed } || mediapipe.FaceLandmarker.Error || Io.Writer.Error || Io.Cancelable;

/// Frames a calibration sample is the median of.
const sample_frames = 10;

const FrameResult = struct {
    face: ?mediapipe.Face,
    width: f64,
    height: f64,
    t_ms: i64,
};

/// Counts Enter presses on a thread of its own, so frames keep flowing while
/// waiting for one (stdin cannot be polled portably).
pub const EnterKey = struct {
    presses: std.atomic.Value(u32) = .init(0),
    closed: std.atomic.Value(bool) = .init(false),

    pub fn start(self: *EnterKey, io: Io) !void {
        const thread = try std.Thread.spawn(.{}, watch, .{ self, io });
        thread.detach();
    }

    fn watch(self: *EnterKey, io: Io) void {
        var buf: [1024]u8 = undefined;
        while (true) {
            const n = Io.File.stdin().readStreaming(io, &.{&buf}) catch 0;
            if (n == 0) return self.closed.store(true, .release);
            _ = self.presses.fetchAdd(1, .release);
        }
    }
};

pub const Tracker = struct {
    io: Io,
    /// Status messages (stdout).
    out: *Io.Writer,
    cfg: *const Config,
    cap: capture.Capture,
    landmarker: *mediapipe.FaceLandmarker,
    client: *opentrack.Client,
    /// Print every pose sent.
    print_poses: bool = false,
    started: ?Io.Timestamp = null,
    last_t_ms: i64 = -1,

    fn say(self: *Tracker, comptime fmt: []const u8, args: anytype) Io.Writer.Error!void {
        try self.out.print(fmt ++ "\n", args);
        try self.out.flush();
    }

    /// Grabs a frame and runs the landmarker on it.
    fn readFace(self: *Tracker) Error!FrameResult {
        const frame = self.cap.read() orelse return error.CameraStopped;
        // MediaPipe wants strictly increasing timestamps.
        const now = Io.Timestamp.now(self.io, .awake);
        if (self.started == null) self.started = now;
        const t_ms = @max(self.started.?.durationTo(now).toMilliseconds(), self.last_t_ms + 1);
        self.last_t_ms = t_ms;
        return .{
            .face = try self.landmarker.detect(frame.rgb, frame.width, frame.height, t_ms),
            .width = @floatFromInt(frame.width),
            .height = @floatFromInt(frame.height),
            .t_ms = t_ms,
        };
    }

    /// Per-landmark median over the faces in the next few frames, or null if there are none.
    fn sampleFace(self: *Tracker) Error!?pose.Points {
        var samples: [sample_frames]pose.Points = undefined;
        var n: usize = 0;
        for (0..sample_frames) |_| {
            if ((try self.readFace()).face) |face| {
                samples[n] = face.points;
                n += 1;
            }
        }
        return if (n == 0) null else pose.median(samples[0..n]);
    }

    /// Waits for Enter, then locks the eye spheres from the next few faces.
    pub fn calibrate(self: *Tracker, enter: *EnterKey) Error!pose.EyeSpheres {
        try self.say("[Calibrate] Look at the centre of your screen, keep your head still, then press Enter.", .{});
        while (true) {
            const seen = enter.presses.load(.acquire);
            while (enter.presses.load(.acquire) == seen) {
                if (enter.closed.load(.acquire)) {
                    std.debug.print("ERROR: stdin closed before calibration.\n", .{});
                    return error.StdinClosed;
                }
                _ = try self.readFace();
            }
            if (try self.sampleFace()) |points| {
                try self.say("[Calibrate] Eye spheres locked.", .{});
                return .lock(&points);
            }
            try self.say("[Calibrate] No face visible. Face the camera and press Enter again.", .{});
        }
    }

    /// Runs until the camera stops. With `spheres` the gaze is the calibrated
    /// eye-sphere model, otherwise head angles plus iris offset.
    pub fn run(self: *Tracker, spheres: ?pose.EyeSpheres) Error!void {
        const cfg = self.cfg;
        var eye_spheres = spheres;
        const calibrated = eye_spheres != null;

        // Calibration zeroes yaw/pitch itself, so auto-centring leaves them alone. The eye-sphere
        // eye gain is ~3x the default's: 1/3 the filter beta gives the same response to an eye movement.
        const gaze_beta: f64 = if (calibrated) 0.01 else 0.03;
        var filters: [6]OneEuro = undefined;
        for (&filters, 0..) |*f, i| f.* = .{ .freq = 30, .min_cutoff = 0.05, .beta = if (i == 3 or i == 4) gaze_beta else 0.03 };
        var state: monitor.StateMonitor = .{
            .timeout_ms = cfg.lost_timeout_ms,
            .auto_center = cfg.auto_center_on_acquire,
            .uncentered = .{ false, false, true, calibrated, calibrated, false },
        };
        var lids: blink.EyeLids = .{};
        var blinks: blink.Blinks = .{ .n = std.math.cast(u32, cfg.recalibrate_blinks) orelse 0 };
        var held: ?pose.Angles = null; // last good gaze, sent while blinking or when gaze is unusable

        try self.say("Tracking Started (Ctrl+C to stop)", .{});

        while (true) {
            const frame = try self.readFace();
            const w = frame.width;
            const h = frame.height;
            const lid = blinks.update(lids.update(if (frame.face) |f| f.blink else null, frame.t_ms), frame.t_ms);
            if (state.is_lost) held = null;

            var raw: ?monitor.Values = null;
            var rotation: ?linalg.Mat3 = null;

            if (frame.face) |*face| {
                var head = pose.headFrame(&face.points);
                state.stabilize(&head.r);
                rotation = head.r;
                const euler = linalg.eulerYxz(head.r);

                if (!lid.hold) {
                    const angles = if (eye_spheres) |*s|
                        s.gaze(&face.points, w, h, cfg.gaze_boost)
                    else
                        pose.headPlusIris(&face.points, euler[0] * sign(cfg.invert_yaw), euler[1] * sign(cfg.invert_pitch), cfg.gaze_boost);
                    if (angles) |a| held = a;
                }

                if (held) |gaze| { // translation and roll keep updating while gaze is held
                    const values: monitor.Values = .{
                        (head.center[0] / w - 0.5) * cfg.scale_x * sign(cfg.invert_x),
                        (head.center[1] / h - 0.5) * cfg.scale_y * sign(cfg.invert_y),
                        head.center[2] / w * 100,
                        gaze.yaw,
                        gaze.pitch,
                        euler[2] * sign(cfg.invert_roll),
                    };
                    raw = values;
                    if (lid.gesture) {
                        if (calibrated) {
                            if (try self.sampleFace()) |points| {
                                eye_spheres = .lock(&points);
                                try self.say("[Calibrate] Blink gesture: eye spheres re-locked.", .{});
                            } else {
                                try self.say("[Calibrate] Blink gesture: face lost, spheres unchanged.", .{});
                            }
                        } else {
                            state.center(values);
                            try self.say("[Tracking] Blink gesture: re-centred.", .{});
                        }
                    }
                }
            }

            const centered = try state.check(raw, frame.t_ms, &filters, rotation, self.out);
            try self.out.flush();
            if (centered) |values| {
                var sent: monitor.Values = undefined;
                for (&sent, values, &filters) |*s, v, *f| s.* = f.apply(v);
                self.client.send(self.io, sent);
                if (self.print_poses) {
                    try self.say("{d:8.2} {d:8.2} {d:8.2} {d:8.2} {d:8.2} {d:8.2}", .{ sent[0], sent[1], sent[2], sent[3], sent[4], sent[5] });
                }
            }
        }
    }
};

fn sign(invert: bool) f64 {
    return if (invert) -1 else 1;
}
