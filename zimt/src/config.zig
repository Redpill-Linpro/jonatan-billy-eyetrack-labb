//! settings.ini, read the way Python's configparser reads it for the original
//! tracker: `key = value` or `key: value` under `[Section]` headers, `#` and
//! `;` comments (inline ones need whitespace before them), case-insensitive keys.
const std = @import("std");

pub const Config = struct {
    /// "auto", or the OS camera index.
    camera_index: []const u8 = "auto",
    /// Case-insensitive part of a camera name; takes precedence over the index.
    camera_name: []const u8 = "",

    invert_x: bool = true,
    invert_y: bool = false,
    invert_yaw: bool = true,
    invert_pitch: bool = false,
    invert_roll: bool = false,

    gaze_boost: f64 = 1.2,
    scale_x: f64 = 100,
    scale_y: f64 = 100,

    lost_timeout_ms: i64 = 500,
    auto_center_on_acquire: bool = true,
    recalibrate_blinks: i64 = 3,

    /// The setting a parse error refers to, for the error message.
    pub const Diagnostic = struct { section: []const u8 = "", key: []const u8 = "", value: []const u8 = "" };

    const Field = struct { section: []const u8, key: []const u8, name: []const u8 };
    const fields = [_]Field{
        .{ .section = "Camera", .key = "index", .name = "camera_index" },
        .{ .section = "Camera", .key = "name", .name = "camera_name" },
        .{ .section = "Inversion", .key = "invert_x", .name = "invert_x" },
        .{ .section = "Inversion", .key = "invert_y", .name = "invert_y" },
        .{ .section = "Inversion", .key = "invert_yaw", .name = "invert_yaw" },
        .{ .section = "Inversion", .key = "invert_pitch", .name = "invert_pitch" },
        .{ .section = "Inversion", .key = "invert_roll", .name = "invert_roll" },
        .{ .section = "Sensitivity", .key = "gaze_boost", .name = "gaze_boost" },
        .{ .section = "Sensitivity", .key = "scale_x", .name = "scale_x" },
        .{ .section = "Sensitivity", .key = "scale_y", .name = "scale_y" },
        .{ .section = "Tracking", .key = "lost_timeout_ms", .name = "lost_timeout_ms" },
        .{ .section = "Tracking", .key = "auto_center_on_acquire", .name = "auto_center_on_acquire" },
        .{ .section = "Tracking", .key = "recalibrate_blinks", .name = "recalibrate_blinks" },
    };

    /// String values are slices of `text`. Unknown sections and keys are ignored.
    pub fn parse(text: []const u8, diagnostic: *Diagnostic) error{InvalidValue}!Config {
        var cfg: Config = .{};
        var section: []const u8 = "";
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
            if (line[0] == '[') {
                const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
                section = line[1..end];
                continue;
            }
            const sep = std.mem.indexOfAny(u8, line, "=:") orelse continue;
            const key = std.mem.trim(u8, line[0..sep], " \t");
            const value = stripInlineComment(line[sep + 1 ..]);
            inline for (fields) |f| {
                if (std.mem.eql(u8, section, f.section) and std.ascii.eqlIgnoreCase(key, f.key)) {
                    const T = @TypeOf(@field(cfg, f.name));
                    @field(cfg, f.name) = convert(T, value) orelse {
                        diagnostic.* = .{ .section = f.section, .key = f.key, .value = value };
                        return error.InvalidValue;
                    };
                }
            }
        }
        if (cfg.camera_index.len == 0) cfg.camera_index = "auto";
        return cfg;
    }

    fn stripInlineComment(value: []const u8) []const u8 {
        var end = value.len;
        for (value, 0..) |ch, i| {
            if ((ch == ';' or ch == '#') and (i == 0 or value[i - 1] == ' ' or value[i - 1] == '\t')) {
                end = i;
                break;
            }
        }
        return std.mem.trim(u8, value[0..end], " \t");
    }

    fn convert(comptime T: type, value: []const u8) ?T {
        return switch (T) {
            []const u8 => value,
            f64 => std.fmt.parseFloat(f64, value) catch null,
            i64 => std.fmt.parseInt(i64, value, 10) catch null,
            bool => {
                for ([_][]const u8{ "1", "yes", "true", "on" }) |word| {
                    if (std.ascii.eqlIgnoreCase(value, word)) return true;
                }
                for ([_][]const u8{ "0", "no", "false", "off" }) |word| {
                    if (std.ascii.eqlIgnoreCase(value, word)) return false;
                }
                return null;
            },
            else => @compileError("unsupported setting type"),
        };
    }
};

const testing = std.testing;

test "defaults without a file" {
    var d: Config.Diagnostic = .{};
    const cfg = try Config.parse("", &d);
    try testing.expectEqualStrings("auto", cfg.camera_index);
    try testing.expect(cfg.invert_x and !cfg.invert_y and cfg.invert_yaw);
    try testing.expectEqual(@as(f64, 1.2), cfg.gaze_boost);
}

test "sections, comments, booleans, numbers" {
    const text =
        \\[Camera]
        \\# a comment
        \\index = 2   ; inline
        \\name =
        \\[Inversion]
        \\invert_x = False
        \\Invert_Y: yes
        \\[Sensitivity]
        \\gaze_boost = 2.0
        \\scale_z = 100
        \\[Tracking]
        \\recalibrate_blinks = 0
        \\lost_timeout_ms = 750 # ms
    ;
    var d: Config.Diagnostic = .{};
    const cfg = try Config.parse(text, &d);
    try testing.expectEqualStrings("2", cfg.camera_index);
    try testing.expectEqualStrings("", cfg.camera_name);
    try testing.expect(!cfg.invert_x and cfg.invert_y);
    try testing.expectEqual(@as(f64, 2.0), cfg.gaze_boost);
    try testing.expectEqual(@as(i64, 0), cfg.recalibrate_blinks);
    try testing.expectEqual(@as(i64, 750), cfg.lost_timeout_ms);
}

test "a bad value names the setting" {
    var d: Config.Diagnostic = .{};
    try testing.expectError(error.InvalidValue, Config.parse("[Inversion]\ninvert_x = maybe\n", &d));
    try testing.expectEqualStrings("invert_x", d.key);
    try testing.expectEqualStrings("maybe", d.value);
}
