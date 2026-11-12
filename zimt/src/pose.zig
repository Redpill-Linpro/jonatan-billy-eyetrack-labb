//! Head pose and gaze from MediaPipe face landmarks.
const std = @import("std");
const linalg = @import("linalg.zig");
const Vec3 = linalg.Vec3;
const Mat3 = linalg.Mat3;

/// Landmarks the model outputs with iris refinement; the iris centres are the last ones used.
pub const landmark_count = 478;

/// Landmarks in pixels: x*w, y*h, z*w.
pub const Points = [landmark_count]Vec3;

/// Nose bridge and tip: rigid, so their principal axes follow the skull.
const nose = [_]usize{ 1, 2, 3, 4, 5, 6, 168, 197, 195 };
const left_socket = [_]usize{ 33, 160, 158, 133, 153, 144 };
const right_socket = [_]usize{ 362, 385, 387, 263, 373, 380 };
const left_iris = 468;
const right_iris = 473;

const Eye = struct { iris: usize, corner_a: usize, corner_b: usize };
const eyes = [2]Eye{
    .{ .iris = left_iris, .corner_a = 33, .corner_b = 133 },
    .{ .iris = right_iris, .corner_a = 362, .corner_b = 263 },
};

/// Eyeball centre to iris, as a fraction of eye width.
const eye_radius = 0.4;
/// Ignore an eye whose ray is over 60 degrees from where it was at calibration.
const min_ray_cos = 0.5;

/// Anything with x, y, z fields normalised to the image (MediaPipe's NormalizedLandmark).
pub fn toPixels(landmarks: anytype, w: f64, h: f64) Points {
    var out: Points = undefined;
    for (&out, landmarks[0..landmark_count]) |*o, lm| o.* = .{ lm.x * w, lm.y * h, lm.z * w };
    return out;
}

pub const HeadFrame = struct {
    /// Mean of the nose landmarks.
    center: Vec3,
    /// Columns: principal axes of the nose landmarks, a right-handed basis.
    r: Mat3,
    /// Mean pairwise distance of the nose landmarks.
    scale: f64,
};

/// The principal axes come out of an eigen-decomposition with arbitrary signs,
/// and the signs decide which way yaw and pitch run. They are fixed here: the
/// first axis (along the nose bridge) points up the image, the second (bridge
/// to tip) away from the camera, the third completes a right-handed basis.
/// `StateMonitor.stabilize` then keeps them continuous from frame to frame.
pub fn headFrame(p: *const Points) HeadFrame {
    var pts: [nose.len]Vec3 = undefined;
    for (&pts, nose) |*o, i| o.* = p[i];
    const center = linalg.mean(&pts);

    var cov: Mat3 = @splat(@splat(0));
    for (pts) |q| {
        const d = linalg.sub(q, center);
        for (0..3) |r| for (0..3) |c| {
            cov[r][c] += d[r] * d[c];
        };
    }
    var r = linalg.symmetricEigenvectors(cov);
    if (r[1][0] > 0) linalg.negateCol(&r, 0);
    if (r[2][1] < 0) linalg.negateCol(&r, 1);
    linalg.setCol(&r, 2, linalg.cross(linalg.col(r, 0), linalg.col(r, 1)));

    var sum: f64 = 0;
    for (pts, 0..) |a, i| for (pts[i + 1 ..]) |b| {
        sum += linalg.norm(linalg.sub(a, b));
    };
    return .{ .center = center, .r = r, .scale = sum / (nose.len * (nose.len - 1) / 2) };
}

fn meanOf(p: *const Points, comptime indices: []const usize) Vec3 {
    var pts: [indices.len]Vec3 = undefined;
    for (&pts, indices) |*o, i| o.* = p[i];
    return linalg.mean(&pts);
}

/// Mean offset of the irises from their sockets, in eye widths. x right, y down.
pub fn irisOffset(p: *const Points) [2]f64 {
    const l = linalg.sub(p[left_iris], meanOf(p, &left_socket));
    const r = linalg.sub(p[right_iris], meanOf(p, &right_socket));
    const eye_width = std.math.hypot(p[33][0] - p[133][0], p[33][1] - p[133][1]);
    return .{ (l[0] + r[0]) / (2 * eye_width), (l[1] + r[1]) / (2 * eye_width) };
}

pub const Angles = struct { yaw: f64, pitch: f64 };

/// Default gaze: head angles plus the iris offset in its socket. No calibration.
pub fn headPlusIris(p: *const Points, head_yaw: f64, head_pitch: f64, gaze_boost: f64) Angles {
    const g = irisOffset(p);
    return .{ .yaw = head_yaw + g[0] * 50 * gaze_boost, .pitch = head_pitch + g[1] * 50 * gaze_boost };
}

/// Eye-sphere gaze (--calibrate). Each eyeball centre is fixed in the head
/// frame at calibration; gaze is the ray from it through the iris, so it
/// already contains head rotation.
pub const EyeSpheres = struct {
    r: Mat3,
    scale: f64,
    /// Eyeball centres relative to the nose centre, in the head frame.
    offsets: [2]Vec3,

    /// Lock both spheres from the landmarks of a face looking at the screen centre.
    pub fn lock(p: *const Points) EyeSpheres {
        const frame = headFrame(p);
        const back = linalg.mulVecT(frame.r, .{ 0, 0, 1 }); // camera viewing axis, head-local
        var offsets: [2]Vec3 = undefined;
        for (&offsets, eyes) |*o, eye| {
            const width = linalg.norm(linalg.sub(p[eye.corner_a], p[eye.corner_b]));
            o.* = linalg.add(
                linalg.mulVecT(frame.r, linalg.sub(p[eye.iris], frame.center)),
                linalg.scale(back, eye_radius * width),
            );
        }
        return .{ .r = frame.r, .scale = frame.scale, .offsets = offsets };
    }

    /// Gaze angles, 0 at calibration, or null when neither eye gives a usable ray.
    /// Same signs as `headPlusIris`: iris right -> +yaw, iris down -> +pitch.
    pub fn gaze(self: *const EyeSpheres, p: *const Points, w: f64, h: f64, gaze_boost: f64) ?Angles {
        var frame = headFrame(p);
        for (0..3) |i| { // axis signs as at calibration
            if (linalg.dot(linalg.col(frame.r, i), linalg.col(self.r, i)) < 0) linalg.negateCol(&frame.r, i);
        }
        var sum: Vec3 = .{ 0, 0, 0 };
        var usable = false;
        for (self.offsets, eyes) |off, eye| {
            const iris = p[eye.iris];
            const ball = linalg.add(frame.center, linalg.mulVec(frame.r, linalg.scale(off, frame.scale / self.scale)));
            const d = linalg.unit(linalg.sub(iris, ball));
            // An iris outside the image is extrapolated; a ray that far off is junk.
            // Weighting by the margin to that limit fades an eye out instead of switching it off.
            if (iris[0] < 0 or iris[0] >= w or iris[1] < 0 or iris[1] >= h or -d[2] <= min_ray_cos) continue;
            sum = linalg.add(sum, linalg.scale(d, -d[2] - min_ray_cos));
            usable = true;
        }
        if (!usable) return null;
        const deg = std.math.deg_per_rad;
        return .{
            .yaw = std.math.atan2(sum[0], -sum[2]) * deg * gaze_boost,
            .pitch = std.math.atan2(sum[1], -sum[2]) * deg * gaze_boost,
        };
    }
};

/// Per-coordinate median over several samples of the same landmarks, so a
/// stray blink frame drops out.
pub fn median(samples: []Points) Points {
    std.debug.assert(samples.len > 0);
    var out: Points = undefined;
    var column: [64]f64 = undefined;
    const n = @min(samples.len, column.len);
    for (&out, 0..) |*o, i| for (0..3) |k| {
        for (column[0..n], samples[0..n]) |*c, s| c.* = s[i][k];
        std.mem.sort(f64, column[0..n], {}, std.sort.asc(f64));
        o[k] = if (n % 2 == 1) column[n / 2] else (column[n / 2 - 1] + column[n / 2]) / 2;
    };
    return out;
}

const testing = std.testing;

/// A crude synthetic face: nose landmarks along a tilted bridge with a
/// protruding tip, eye corners and sockets either side, irises centred.
fn syntheticFace() Points {
    var p: Points = @splat(.{ 320, 240, 0 });
    const bridge = [_]struct { usize, Vec3 }{
        .{ 168, .{ 320, 200, -20 } },   .{ 6, .{ 320.5, 212, -26 } }, .{ 197, .{ 319.6, 224, -33 } },
        .{ 195, .{ 320.3, 236, -40 } }, .{ 5, .{ 320, 246, -47 } },   .{ 4, .{ 320.4, 256, -52 } },
        .{ 1, .{ 319.8, 262, -50 } },   .{ 2, .{ 320, 274, -30 } },   .{ 3, .{ 317, 240, -38 } },
    };
    for (bridge) |b| p[b[0]] = b[1];
    for ([_]f64{ -1, 1 }, [_][]const usize{ &left_socket, &right_socket }, eyes) |side, socket, eye| {
        const cx = 320 + side * 45;
        for (socket, 0..) |i, k| {
            const a = @as(f64, @floatFromInt(k)) * std.math.pi / 3.0;
            p[i] = .{ cx + 12 * @cos(a), 205 + 5 * @sin(a), -5 };
        }
        p[eye.corner_a] = .{ cx - 14, 205, -4 };
        p[eye.corner_b] = .{ cx + 14, 205, -4 };
        p[eye.iris] = .{ cx, 205, -8 };
    }
    return p;
}

fn rotateY(p: *const Points, deg: f64) Points {
    const c = @cos(deg * std.math.rad_per_deg);
    const s = @sin(deg * std.math.rad_per_deg);
    var out: Points = undefined;
    for (&out, p) |*o, q| {
        const x = q[0] - 320;
        o.* = .{ 320 + c * x + s * q[2], q[1], -s * x + c * q[2] };
    }
    return out;
}

test "headFrame is right-handed with fixed axis directions" {
    const f = headFrame(&syntheticFace());
    try testing.expectApproxEqAbs(@as(f64, 1), linalg.det(f.r), 1e-9);
    try testing.expect(f.r[1][0] < -0.5); // first axis: up the bridge
    try testing.expect(f.r[2][1] > 0.5); // second axis: away from the camera
    try testing.expect(f.scale > 10);
}

test "turning the face towards image +x lowers head yaw, like looking right raises iris x" {
    // With the default invert_yaw the two then add up instead of cancelling.
    const face = syntheticFace();
    const base = linalg.eulerYxz(headFrame(&face).r);
    const turned = linalg.eulerYxz(headFrame(&rotateY(&face, -10)).r);
    try testing.expect(turned[0] < base[0] - 5);
}

test "irisOffset follows the irises" {
    var face = syntheticFace();
    try testing.expectApproxEqAbs(@as(f64, 0), irisOffset(&face)[0], 0.05);
    face[left_iris][0] += 5;
    face[right_iris][0] += 5;
    try testing.expect(irisOffset(&face)[0] > 0.1);
}

test "eye spheres read zero at calibration and follow the eyes and the head" {
    var face = syntheticFace();
    const spheres: EyeSpheres = .lock(&face);
    const zero = spheres.gaze(&face, 640, 480, 1).?;
    try testing.expectApproxEqAbs(@as(f64, 0), zero.yaw, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0), zero.pitch, 1e-6);

    const head = spheres.gaze(&rotateY(&face, -10), 640, 480, 1).?;
    try testing.expectApproxEqAbs(@as(f64, 10), head.yaw, 0.5);

    face[left_iris][0] += 3;
    face[right_iris][0] += 3;
    try testing.expect(spheres.gaze(&face, 640, 480, 1).?.yaw > 5);

    face[left_iris][0] = -10; // both irises off-image
    face[right_iris][0] = 700;
    try testing.expect(spheres.gaze(&face, 640, 480, 1) == null);
}

test "median drops an outlier sample" {
    var samples: [3]Points = @splat(syntheticFace());
    samples[1][4] = .{ 999, 999, 999 };
    try testing.expectEqual(syntheticFace()[4], median(&samples)[4]);
}
