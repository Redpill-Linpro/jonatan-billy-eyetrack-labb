//! Camera enumeration: the names of the cameras the OS knows, keyed by the
//! index OpenCV opens them with. OpenCV itself only takes indices, so each OS
//! backend lists devices in the order of the OpenCV capture backend it names.
//!
//! A backend is a file exporting:
//!   pub const opencv_api: c_int        cv::VideoCaptureAPIs value the indices are for
//!   pub const device_fmt: []const u8   how to print a camera index, e.g. "/dev/video{d}"
//!   pub fn list(arena: std.mem.Allocator, io: std.Io) ![]Camera
const std = @import("std");
const builtin = @import("builtin");

pub const Camera = struct {
    /// Index to open the camera with.
    num: u32,
    name: []const u8,
};

const backend = switch (builtin.os.tag) {
    .linux => @import("linux.zig"),
    .macos => @import("macos.zig"),
    .windows => @import("windows.zig"),
    else => @compileError("no camera enumeration for this OS; add a backend in src/camera/"),
};

pub const opencv_api: c_int = backend.opencv_api;
pub const device_fmt: []const u8 = backend.device_fmt;

/// Cameras sorted by index. Names are allocated in `arena`.
pub fn list(arena: std.mem.Allocator, io: std.Io) ![]Camera {
    const cameras = try backend.list(arena, io);
    std.mem.sort(Camera, cameras, {}, struct {
        fn lessThan(_: void, a: Camera, b: Camera) bool {
            return a.num < b.num;
        }
    }.lessThan);
    return cameras;
}

test {
    _ = backend;
}
