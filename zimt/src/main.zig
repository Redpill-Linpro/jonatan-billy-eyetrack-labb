//! zimt: webcam head and eye tracking for opentrack.
const std = @import("std");
const Io = std.Io;
const camera = @import("camera.zig");
const capture = @import("capture.zig");
const Config = @import("config.zig").Config;
const enumerate = @import("camera/enumerate.zig");
const mediapipe = @import("mediapipe.zig");
const opentrack = @import("opentrack.zig");
const tracker = @import("tracker.zig");

const usage =
    \\Usage: zimt [options]
    \\
    \\Webcam head/eye tracker sending pose to opentrack (UDP 127.0.0.1:4242).
    \\
    \\Options:
    \\  --calibrate      use the eye-sphere gaze model, starting with a calibration
    \\                   step (look at the screen centre, press Enter)
    \\  --list-cameras   print the cameras found and exit
    \\  --source PATH    track a video file instead of a camera
    \\  --print          print every pose sent: x y z yaw pitch roll
    \\  --config PATH    settings file (default: settings.ini next to the executable)
    \\  --model PATH     model file (default: face_landmarker.task next to the executable)
    \\  -h, --help       show this help
    \\
;

const Options = struct {
    calibrate: bool = false,
    list_cameras: bool = false,
    print: bool = false,
    source: ?[:0]const u8 = null,
    config: ?[]const u8 = null,
    model: ?[]const u8 = null,
};

/// Errors whose explanation has already been printed.
const Reported = error{Reported};

pub fn main(init: std.process.Init) u8 {
    run(init) catch |err| {
        if (err != error.Reported) std.debug.print("ERROR: {t}\n", .{err});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const options = try parseArgs(try init.minimal.args.toSlice(arena), out);

    if (options.list_cameras) {
        for (try enumerate.list(arena, io)) |cam| {
            try out.print(enumerate.device_fmt ++ "  {s}\n", .{ cam.num, cam.name });
        }
        return out.flush();
    }

    if (options.calibrate and !(try Io.File.stdin().isTty(io))) {
        return fail("--calibrate waits for Enter on a terminal, but stdin is not a terminal.", .{});
    }

    const exe_dir = try std.process.executableDirPathAlloc(io, arena);
    const cfg = try loadConfig(arena, io, options.config orelse try std.fs.path.join(arena, &.{ exe_dir, "settings.ini" }), options.config != null);

    const model_path = options.model orelse try std.fs.path.join(arena, &.{ exe_dir, "face_landmarker.task" });
    const model = Io.Dir.cwd().readFileAlloc(io, model_path, arena, .limited(256 << 20)) catch |err| {
        return fail(
            \\Could not read the model file {s} ({t}).
            \\Run `make` to download it, or pass --model.
        , .{ model_path, err });
    };

    const cv: capture.Library = capture.Library.load(arena, try std.fs.path.join(arena, &.{ exe_dir, capture.lib_file_name })) catch return error.Reported;

    var cap: capture.Capture = undefined;
    if (options.source) |path| {
        cap = cv.openPath(path) orelse return fail("Could not open {s}.", .{path});
        try out.print("[Camera] Using {s}\n", .{path});
    } else {
        const selected = camera.select(arena, io, &cv, cfg.camera_index, cfg.camera_name) catch |err| switch (err) {
            error.CameraUnavailable => return error.Reported,
            else => |e| return e,
        };
        cap = selected.cap;
        try out.print("[Camera] Using " ++ enumerate.device_fmt ++ " ({s}), {d}x{d}\n", .{ selected.num, selected.name, selected.width, selected.height });
    }
    defer cap.close();
    try out.flush();

    var landmarker = mediapipe.FaceLandmarker.create(arena, try std.fs.path.join(arena, &.{ exe_dir, mediapipe.lib_file_name }), model) catch return error.Reported;
    defer landmarker.close();

    var client: opentrack.Client = try .init(io, .{ .ip4 = .loopback(opentrack.default_port) });
    defer client.deinit(io);

    var t: tracker.Tracker = .{
        .io = io,
        .out = out,
        .cfg = &cfg,
        .cap = cap,
        .landmarker = &landmarker,
        .client = &client,
        .print_poses = options.print,
    };
    var enter: tracker.EnterKey = .{};
    const result = if (options.calibrate) calibrated: {
        try enter.start(io);
        const spheres = t.calibrate(&enter) catch |err| break :calibrated err;
        break :calibrated t.run(spheres);
    } else t.run(null);
    result catch |err| switch (err) {
        error.CameraStopped => {
            if (options.source != null) return; // end of the video
            return fail("Camera stopped delivering frames (unplugged or in use by another app?).", .{});
        },
        error.StdinClosed, error.MediaPipeFailed => return error.Reported,
        else => |e| return e,
    };
}

fn parseArgs(args: []const [:0]const u8, out: *Io.Writer) !Options {
    var options: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--calibrate")) {
            options.calibrate = true;
        } else if (std.mem.eql(u8, arg, "--list-cameras")) {
            options.list_cameras = true;
        } else if (std.mem.eql(u8, arg, "--print")) {
            options.print = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try out.writeAll(usage);
            try out.flush();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--source") or std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "--model")) {
            i += 1;
            if (i == args.len) return fail("{s} needs a path.\n\n" ++ usage, .{arg});
            if (arg[2] == 's') options.source = args[i] else if (arg[2] == 'c') options.config = args[i] else options.model = args[i];
        } else {
            return fail("Unknown argument '{s}'.\n\n" ++ usage, .{arg});
        }
    }
    return options;
}

/// A missing settings file means defaults, unless it was asked for by name.
fn loadConfig(arena: std.mem.Allocator, io: Io, path: []const u8, required: bool) !Config {
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| {
        if (err == error.FileNotFound and !required) return .{};
        return fail("Could not read {s} ({t}).", .{ path, err });
    };
    var diagnostic: Config.Diagnostic = .{};
    return Config.parse(text, &diagnostic) catch
        fail("{s}: [{s}] {s} = '{s}' is not a valid value.", .{ path, diagnostic.section, diagnostic.key, diagnostic.value });
}

fn fail(comptime fmt: []const u8, args: anytype) Reported {
    std.debug.print("ERROR: " ++ fmt ++ "\n", args);
    return error.Reported;
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("blink.zig");
    _ = @import("config.zig");
    _ = @import("filter.zig");
    _ = @import("linalg.zig");
    _ = @import("monitor.zig");
    _ = @import("pose.zig");
}
