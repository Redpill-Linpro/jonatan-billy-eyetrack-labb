//! MediaPipe Face Landmarker through the C API of libmediapipe, the shared
//! library the official `mediapipe` Python wheel is a thin wrapper around.
//! Struct layouts follow mediapipe/tasks/c of release 0.10.32.
const std = @import("std");
const dynlib = @import("dynlib.zig");
const pose = @import("pose.zig");

pub const lib_file_name = dynlib.fileName("mediapipe");

const Status = c_int; // 0 is OK
const ErrorMessage = ?[*:0]u8;

const BaseOptions = extern struct {
    model_asset_buffer: ?[*]const u8 = null,
    model_asset_buffer_count: c_uint = 0,
    model_asset_path: ?[*:0]const u8 = null,
    delegate: c_int = 0, // CPU
};

const RunningMode = enum(c_int) { image = 1, video = 2, live_stream = 3 };

const FaceLandmarkerOptions = extern struct {
    base_options: BaseOptions,
    running_mode: RunningMode,
    num_faces: c_int = 1,
    min_face_detection_confidence: f32 = 0.5,
    min_face_presence_confidence: f32 = 0.5,
    min_tracking_confidence: f32 = 0.5,
    output_face_blendshapes: bool,
    output_facial_transformation_matrixes: bool = false,
    result_callback: ?*const anyopaque = null,
};

const NormalizedLandmark = extern struct {
    x: f32,
    y: f32,
    z: f32,
    has_visibility: bool,
    visibility: f32,
    has_presence: bool,
    presence: f32,
    name: ?[*:0]u8,
};

const NormalizedLandmarks = extern struct {
    landmarks: ?[*]NormalizedLandmark,
    landmarks_count: u32,
};

const Category = extern struct {
    index: c_int,
    score: f32,
    category_name: ?[*:0]u8,
    display_name: ?[*:0]u8,
};

const Categories = extern struct {
    categories: ?[*]Category,
    categories_count: u32,
};

const FaceLandmarkerResult = extern struct {
    face_landmarks: ?[*]NormalizedLandmarks = null,
    face_landmarks_count: u32 = 0,
    face_blendshapes: ?[*]Categories = null,
    face_blendshapes_count: u32 = 0,
    facial_transformation_matrixes: ?*anyopaque = null,
    facial_transformation_matrixes_count: u32 = 0,
};

const ImageFormat = enum(c_int) { srgb = 1 };

const Api = struct {
    MpFaceLandmarkerCreate: *const fn (*const FaceLandmarkerOptions, *?*anyopaque, *ErrorMessage) callconv(.c) Status,
    MpFaceLandmarkerDetectForVideo: *const fn (*anyopaque, *anyopaque, ?*const anyopaque, i64, *FaceLandmarkerResult, *ErrorMessage) callconv(.c) Status,
    MpFaceLandmarkerCloseResult: *const fn (*FaceLandmarkerResult) callconv(.c) void,
    MpFaceLandmarkerClose: *const fn (*anyopaque, *ErrorMessage) callconv(.c) Status,
    MpImageCreateFromUint8Data: *const fn (ImageFormat, c_int, c_int, [*]const u8, c_int, *?*anyopaque, *ErrorMessage) callconv(.c) Status,
    MpImageFree: *const fn (*anyopaque) callconv(.c) void,
    MpErrorFree: *const fn (?*anyopaque) callconv(.c) void,
};

pub const Face = struct {
    /// Landmarks in pixels.
    points: pose.Points,
    /// eyeBlink score of the more closed eye.
    blink: ?f64,
};

pub const FaceLandmarker = struct {
    api: Api,
    handle: *anyopaque,

    pub const Error = error{MediaPipeFailed};

    /// `model` is the content of face_landmarker.task and must outlive the landmarker.
    pub fn create(gpa: std.mem.Allocator, lib_path: []const u8, model: []const u8) !FaceLandmarker {
        const lib: dynlib.DynLib = try .open(gpa, lib_path);
        const api = try lib.bind(Api, lib_file_name);

        const options: FaceLandmarkerOptions = .{
            .base_options = .{ .model_asset_buffer = model.ptr, .model_asset_buffer_count = @intCast(model.len) },
            .running_mode = .video,
            .output_face_blendshapes = true, // eyeBlink scores
        };
        var handle: ?*anyopaque = null;
        var msg: ErrorMessage = null;
        try check(api, api.MpFaceLandmarkerCreate(&options, &handle, &msg), msg, "creating the face landmarker");
        return .{ .api = api, .handle = handle orelse return error.MediaPipeFailed };
    }

    pub fn close(self: *FaceLandmarker) void {
        var msg: ErrorMessage = null;
        check(self.api, self.api.MpFaceLandmarkerClose(self.handle, &msg), msg, "closing the face landmarker") catch {};
    }

    /// Runs the landmarker on a tightly packed RGB frame. `t_ms` must increase
    /// from call to call. Returns null when no face is found.
    pub fn detect(self: *FaceLandmarker, rgb: []const u8, width: u32, height: u32, t_ms: i64) Error!?Face {
        const api = self.api;
        var msg: ErrorMessage = null;

        var image: ?*anyopaque = null;
        try check(api, api.MpImageCreateFromUint8Data(.srgb, @intCast(width), @intCast(height), rgb.ptr, @intCast(rgb.len), &image, &msg), msg, "wrapping the camera frame");
        defer api.MpImageFree(image.?);

        var result: FaceLandmarkerResult = .{};
        try check(api, api.MpFaceLandmarkerDetectForVideo(self.handle, image.?, null, t_ms, &result, &msg), msg, "detecting face landmarks");
        defer api.MpFaceLandmarkerCloseResult(&result);

        if (result.face_landmarks_count == 0) return null;
        const landmarks = result.face_landmarks.?[0];
        if (landmarks.landmarks_count < pose.landmark_count) return null;

        var blink: ?f64 = null;
        if (result.face_blendshapes_count > 0) {
            const shapes = result.face_blendshapes.?[0];
            for (shapes.categories.?[0..shapes.categories_count]) |category| {
                const name = std.mem.span(category.category_name orelse continue);
                if (std.mem.eql(u8, name, "eyeBlinkLeft") or std.mem.eql(u8, name, "eyeBlinkRight")) {
                    blink = @max(blink orelse 0, category.score);
                }
            }
        }
        return .{
            .points = pose.toPixels(landmarks.landmarks.?, @floatFromInt(width), @floatFromInt(height)),
            .blink = blink,
        };
    }

    fn check(api: Api, status: Status, msg: ErrorMessage, doing: []const u8) Error!void {
        defer if (msg) |m| api.MpErrorFree(m);
        if (status == 0) return;
        const text: [*:0]const u8 = msg orelse "no details";
        std.debug.print("ERROR: MediaPipe failed {s} (status {d}): {s}\n", .{ doing, status, text });
        return error.MediaPipeFailed;
    }
};

test "struct layouts match the C API on 64-bit targets" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    try std.testing.expectEqual(40, @sizeOf(NormalizedLandmark));
    try std.testing.expectEqual(24, @sizeOf(Category));
    try std.testing.expectEqual(32, @sizeOf(BaseOptions));
    try std.testing.expectEqual(64, @sizeOf(FaceLandmarkerOptions));
    try std.testing.expectEqual(48, @sizeOf(FaceLandmarkerResult));
}
