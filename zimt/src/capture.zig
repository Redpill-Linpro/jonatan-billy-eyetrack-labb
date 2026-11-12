//! Frames from OpenCV's VideoCapture, through the C shim in shim/zimt_cv.cpp
//! (OpenCV has no C API of its own).
const std = @import("std");
const dynlib = @import("dynlib.zig");

pub const lib_file_name = dynlib.fileName("zimt_cv");

/// Must match ZIMT_CV_ABI in shim/zimt_cv.h.
const abi_version = 1;

const Api = struct {
    zimt_cv_abi: *const fn () callconv(.c) c_int,
    zimt_cap_open_index: *const fn (index: c_int, opencv_api: c_int) callconv(.c) ?*anyopaque,
    zimt_cap_open_path: *const fn (path: [*:0]const u8) callconv(.c) ?*anyopaque,
    zimt_cap_read: *const fn (*anyopaque, rgb: *?[*]const u8, width: *c_int, height: *c_int) callconv(.c) c_int,
    zimt_cap_close: *const fn (*anyopaque) callconv(.c) void,
};

pub const Frame = struct {
    /// Tightly packed RGB, valid until the next read.
    rgb: []const u8,
    width: u32,
    height: u32,
};

pub const Library = struct {
    api: Api,

    pub fn load(gpa: std.mem.Allocator, path: []const u8) !Library {
        const lib: dynlib.DynLib = try .open(gpa, path);
        const api = try lib.bind(Api, lib_file_name);
        if (api.zimt_cv_abi() != abi_version) {
            std.debug.print("ERROR: {s} is from a different zimt build. Run make again.\n", .{path});
            return error.LibraryNotLoaded;
        }
        return .{ .api = api };
    }

    /// Opens camera `index` of the given OpenCV backend (a cv::VideoCaptureAPIs value).
    pub fn openIndex(self: *const Library, index: u32, opencv_api: c_int) ?Capture {
        const handle = self.api.zimt_cap_open_index(@intCast(index), opencv_api) orelse return null;
        return .{ .api = &self.api, .handle = handle };
    }

    /// Opens a video file (or anything else OpenCV accepts as a path or URL).
    pub fn openPath(self: *const Library, path: [*:0]const u8) ?Capture {
        const handle = self.api.zimt_cap_open_path(path) orelse return null;
        return .{ .api = &self.api, .handle = handle };
    }
};

pub const Capture = struct {
    api: *const Api,
    handle: *anyopaque,

    pub fn read(self: Capture) ?Frame {
        var rgb: ?[*]const u8 = null;
        var w: c_int = 0;
        var h: c_int = 0;
        if (self.api.zimt_cap_read(self.handle, &rgb, &w, &h) == 0 or w <= 0 or h <= 0) return null;
        const width: u32 = @intCast(w);
        const height: u32 = @intCast(h);
        return .{ .rgb = (rgb orelse return null)[0 .. @as(usize, width) * height * 3], .width = width, .height = height };
    }

    pub fn close(self: Capture) void {
        self.api.zimt_cap_close(self.handle);
    }
};
