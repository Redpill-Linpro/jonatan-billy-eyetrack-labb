//! macOS: AVFoundation capture devices, listed through the Objective-C runtime.
//! libobjc and AVFoundation are loaded at run time, so this needs no macOS SDK
//! to build. Nothing is opened: listing needs no camera permission.
const std = @import("std");
const Camera = @import("enumerate.zig").Camera;
const DynLib = @import("../dynlib.zig").DynLib;

/// cv::CAP_AVFOUNDATION
pub const opencv_api: c_int = 1200;
pub const device_fmt = "camera {d}";

const libobjc_path = "/usr/lib/libobjc.A.dylib";
/// Not on disk on modern macOS; dlopen finds it in the dyld shared cache.
const avfoundation_path = "/System/Library/Frameworks/AVFoundation.framework/AVFoundation";

const id = *anyopaque;
const SEL = *anyopaque;

const Objc = struct {
    objc_getClass: *const fn ([*:0]const u8) callconv(.c) ?id,
    sel_registerName: *const fn ([*:0]const u8) callconv(.c) SEL,
    objc_msgSend: *const fn () callconv(.c) void,
    objc_autoreleasePoolPush: *const fn () callconv(.c) ?*anyopaque,
    objc_autoreleasePoolPop: *const fn (?*anyopaque) callconv(.c) void,

    /// `[receiver sel args...]` returning `Ret`. Plain objc_msgSend covers
    /// every call here (object, integer and pointer returns) on arm64 and x86_64.
    fn send(objc: Objc, comptime Ret: type, receiver: id, sel: [*:0]const u8, args: anytype) Ret {
        const params = [_]type{ id, SEL } ++ @typeInfo(@TypeOf(args)).@"struct".field_types;
        const F = @Fn(params, &@splat(.{}), Ret, .{ .@"callconv" = .c });
        const f: *const F = @ptrCast(objc.objc_msgSend);
        return @call(.auto, f, .{ receiver, objc.sel_registerName(sel) } ++ args);
    }
};

/// The NSComparator block OpenCV sorts with, laid out per the Clang block ABI
/// as a stack block (the sort only calls it synchronously); `objc` is its capture.
const Comparator = extern struct {
    isa: *const anyopaque,
    flags: c_int = 0,
    reserved: c_int = 0,
    invoke: *const fn (*const Comparator, id, id) callconv(.c) isize = compare,
    descriptor: *const Descriptor = &descriptor_value,
    objc: *const Objc,

    const Descriptor = extern struct { reserved: c_ulong, size: c_ulong };
    const descriptor_value: Descriptor = .{ .reserved = 0, .size = @sizeOf(Comparator) };

    /// `[d1.uniqueID compare:d2.uniqueID]`
    fn compare(block: *const Comparator, d1: id, d2: id) callconv(.c) isize {
        const objc = block.objc;
        const id1 = objc.send(id, d1, "uniqueID", .{});
        return objc.send(isize, id1, "compare:", .{objc.send(id, d2, "uniqueID", .{})});
    }
};

extern "c" var _NSConcreteStackBlock: anyopaque;

/// Same list, order and index as OpenCV's CvCaptureCAM::startCaptureDevice
/// (cap_avfoundation_mac.mm, identical in 4.8.0, 4.10.0 and 4.x): video then
/// muxed devices, sorted by `[d1.uniqueID compare:d2.uniqueID]`.
pub fn list(arena: std.mem.Allocator, io: std.Io) ![]Camera {
    _ = io;
    const libobjc = DynLib.open(arena, libobjc_path) catch return error.AVFoundationUnavailable;
    const objc = libobjc.bind(Objc, libobjc_path) catch return error.AVFoundationUnavailable;
    const avfoundation = DynLib.open(arena, avfoundation_path) catch return error.AVFoundationUnavailable;
    // Exported `AVMediaType` (NSString *) data symbols.
    const media_video = avfoundation.lookup(*const id, "AVMediaTypeVideo") orelse return error.AVFoundationUnavailable;
    const media_muxed = avfoundation.lookup(*const id, "AVMediaTypeMuxed") orelse return error.AVFoundationUnavailable;
    const AVCaptureDevice = objc.objc_getClass("AVCaptureDevice") orelse return error.AVFoundationUnavailable;

    const pool = objc.objc_autoreleasePoolPush();
    defer objc.objc_autoreleasePoolPop(pool);

    const video = objc.send(id, AVCaptureDevice, "devicesWithMediaType:", .{media_video.*});
    const muxed = objc.send(id, AVCaptureDevice, "devicesWithMediaType:", .{media_muxed.*});
    const all = objc.send(id, video, "arrayByAddingObjectsFromArray:", .{muxed});
    const comparator: Comparator = .{ .isa = &_NSConcreteStackBlock, .objc = &objc };
    const devices = objc.send(id, all, "sortedArrayUsingComparator:", .{@as(*const anyopaque, &comparator)});

    const count = objc.send(usize, devices, "count", .{});
    const cameras = try arena.alloc(Camera, count);
    for (cameras, 0..) |*camera, i| {
        const device = objc.send(id, devices, "objectAtIndex:", .{i});
        const name = objc.send(?id, device, "localizedName", .{});
        const utf8 = if (name) |n| objc.send(?[*:0]const u8, n, "UTF8String", .{}) else null;
        camera.* = .{ .num = @intCast(i), .name = try arena.dupe(u8, std.mem.span(utf8 orelse "?")) };
    }
    return cameras;
}
