//! Linux: V4L2 capture nodes from sysfs. The index is N of /dev/videoN.
const std = @import("std");
const Camera = @import("enumerate.zig").Camera;

/// cv::CAP_V4L2
pub const opencv_api: c_int = 200;
pub const device_fmt = "/dev/video{d}";

const sysfs_dir = "/sys/class/video4linux";

pub fn list(arena: std.mem.Allocator, io: std.Io) ![]Camera {
    // The directory only exists once a V4L2 driver has loaded: without it there are no cameras.
    var dir = std.Io.Dir.cwd().openDir(io, sysfs_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(io);

    var cameras: std.ArrayList(Camera) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const num = deviceNumber(entry.name) orelse continue;
        // One camera has several nodes (capture, metadata, ...); index 0 is the capture node.
        var index_buf: [16]u8 = undefined;
        if (!std.mem.eql(u8, readAttribute(io, dir, entry.name, "index", &index_buf) orelse "0", "0")) continue;
        var name_buf: [256]u8 = undefined;
        const name = readAttribute(io, dir, entry.name, "name", &name_buf) orelse "?";
        try cameras.append(arena, .{ .num = num, .name = try arena.dupe(u8, name) });
    }
    return cameras.items;
}

/// N of "videoN".
fn deviceNumber(name: []const u8) ?u32 {
    const prefix = "video";
    if (!std.mem.startsWith(u8, name, prefix) or name.len == prefix.len) return null;
    return std.fmt.parseInt(u32, name[prefix.len..], 10) catch null;
}

fn readAttribute(io: std.Io, dir: std.Io.Dir, device: []const u8, attribute: []const u8, buf: []u8) ?[]const u8 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ device, attribute }) catch return null;
    const content = dir.readFile(io, path, buf) catch return null;
    return std.mem.trim(u8, content, " \t\r\n");
}

test deviceNumber {
    try std.testing.expectEqual(@as(?u32, 12), deviceNumber("video12"));
    try std.testing.expectEqual(@as(?u32, null), deviceNumber("video"));
    try std.testing.expectEqual(@as(?u32, null), deviceNumber("v4l-subdev0"));
    try std.testing.expectEqual(@as(?u32, null), deviceNumber("video1x"));
}
