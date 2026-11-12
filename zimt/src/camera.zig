//! Camera selection: by name, by index, or the first one that delivers a frame.
const std = @import("std");
const Io = std.Io;
const capture = @import("capture.zig");
const enumerate = @import("camera/enumerate.zig");
const Camera = enumerate.Camera;

pub const Selected = struct {
    cap: capture.Capture,
    num: u32,
    name: []const u8,
    width: u32,
    height: u32,
};

pub const Error = error{CameraUnavailable};

/// Resolves the [Camera] settings to an opened camera. On failure the reason
/// and the detected cameras are printed to stderr.
pub fn select(arena: std.mem.Allocator, io: Io, lib: *const capture.Library, index: []const u8, name: []const u8) !Selected {
    const cams = listOrGuess(arena, io);

    if (name.len != 0) {
        const cam = for (cams) |c| {
            if (std.ascii.findIgnoreCase(c.name, name) != null) break c;
        } else return fail(cams, "No camera name contains '{s}'.", .{name});
        return open(io, lib, cam) orelse
            fail(cams, enumerate.device_fmt ++ " ({s}) matched '{s}' but gave no frame.", .{ cam.num, cam.name, name });
    }

    if (!std.ascii.eqlIgnoreCase(index, "auto")) {
        const num = std.fmt.parseInt(u32, index, 10) catch
            return fail(cams, "Invalid index '{s}' (expected 'auto' or a non-negative integer).", .{index});
        const cam: Camera = for (cams) |c| {
            if (c.num == num) break c;
        } else .{ .num = num, .name = "?" };
        return open(io, lib, cam) orelse
            fail(cams, "Could not open " ++ enumerate.device_fmt ++ " or read a frame from it.", .{num});
    }

    const ranked = try arena.dupe(Camera, cams);
    std.mem.sort(Camera, ranked, {}, struct {
        fn lessThan(_: void, a: Camera, b: Camera) bool {
            return autoRank(a.name) < autoRank(b.name); // stable: ties stay in index order
        }
    }.lessThan);
    for (ranked) |cam| {
        if (open(io, lib, cam)) |selected| return selected;
        std.debug.print("[Camera] " ++ enumerate.device_fmt ++ " ({s}) unusable, trying next...\n", .{ cam.num, cam.name });
    }
    return fail(cams, "Auto-detect found no working camera.", .{});
}

/// The OS's cameras; if they cannot be listed, the first few indices unnamed,
/// so selection by index and auto-detection still work.
pub fn listOrGuess(arena: std.mem.Allocator, io: Io) []const Camera {
    return enumerate.list(arena, io) catch |err| {
        std.debug.print("[Camera] Could not list cameras ({t}); probing indices 0-3.\n", .{err});
        const unnamed = [_]Camera{ .{ .num = 0, .name = "?" }, .{ .num = 1, .name = "?" }, .{ .num = 2, .name = "?" }, .{ .num = 3, .name = "?" } };
        return &unnamed;
    };
}

pub fn printList(cams: []const Camera) void {
    for (cams) |c| std.debug.print("  " ++ enumerate.device_fmt ++ "  {s}\n", .{ c.num, c.name });
    if (cams.len == 0) std.debug.print("  (none - is the camera plugged in, and is this program allowed to use it?)\n", .{});
}

/// Opens the camera and grabs a frame, retrying while it warms up.
fn open(io: Io, lib: *const capture.Library, cam: Camera) ?Selected {
    const cap = lib.openIndex(cam.num, enumerate.opencv_api) orelse return null;
    for (0..10) |_| {
        if (cap.read()) |frame| {
            return .{ .cap = cap, .num = cam.num, .name = cam.name, .width = frame.width, .height = frame.height };
        }
        io.sleep(.fromMilliseconds(50), .awake) catch break;
    }
    cap.close();
    return null;
}

fn fail(cams: []const Camera, comptime fmt: []const u8, args: anytype) Error {
    std.debug.print("ERROR: " ++ fmt ++ "\nDetected cameras:\n", args);
    printList(cams);
    std.debug.print(
        \\Set [Camera] in settings.ini:
        \\  name  = <part of a camera name above>   (takes precedence)
        \\  index = <camera number above> | auto
        \\
    , .{});
    return error.CameraUnavailable;
}

/// 0 = external webcam, 1 = built into the computer, 2 = infrared.
fn autoRank(name: []const u8) u8 {
    if (isInfrared(name)) return 2;
    for ([_][]const u8{ "integrated", "built-in", "facetime", "macbook" }) |word| {
        if (std.ascii.findIgnoreCase(name, word) != null) return 1;
    }
    return 0;
}

/// "infrared" anywhere, or "ir" as a word of its own.
fn isInfrared(name: []const u8) bool {
    if (std.ascii.findIgnoreCase(name, "infrared") != null) return true;
    var start: usize = 0;
    while (std.ascii.findIgnoreCasePos(name, start, "ir")) |i| : (start = i + 1) {
        const before = i == 0 or !isWordChar(name[i - 1]);
        const after = i + 2 == name.len or !isWordChar(name[i + 2]);
        if (before and after) return true;
    }
    return false;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

test autoRank {
    try std.testing.expectEqual(0, autoRank("Logitech BRIO"));
    try std.testing.expectEqual(1, autoRank("Integrated Camera: Integrated C"));
    try std.testing.expectEqual(1, autoRank("FaceTime HD Camera"));
    try std.testing.expectEqual(2, autoRank("Integrated Camera: Integrated I (IR)"));
    try std.testing.expectEqual(2, autoRank("Integrated IR Camera"));
    try std.testing.expectEqual(2, autoRank("USB Infrared Cam"));
    try std.testing.expectEqual(0, autoRank("Fire Wire Cam")); // "ir" inside a word
}
