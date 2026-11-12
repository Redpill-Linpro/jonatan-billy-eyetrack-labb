//! Runtime loading of shared libraries, so the executable has no link-time
//! dependency on MediaPipe or OpenCV and cross-compiles for every target.
const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

const win = struct {
    extern "kernel32" fn LoadLibraryExW(name: [*:0]const u16, file: ?*anyopaque, flags: u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
    /// Resolve the library's own dependencies from its directory first.
    const LOAD_WITH_ALTERED_SEARCH_PATH = 0x8;
};

pub const DynLib = struct {
    handle: *anyopaque,

    /// `path` should be absolute. On failure the reason is printed to stderr.
    pub fn open(gpa: std.mem.Allocator, path: []const u8) error{ OutOfMemory, LibraryNotLoaded }!DynLib {
        if (is_windows) {
            const wide = std.unicode.wtf8ToWtf16LeAllocZ(gpa, path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidWtf8 => return error.LibraryNotLoaded,
            };
            defer gpa.free(wide);
            const handle = win.LoadLibraryExW(wide, null, win.LOAD_WITH_ALTERED_SEARCH_PATH) orelse {
                std.debug.print("ERROR: Could not load {s} (Windows error {d}).\n", .{ path, win.GetLastError() });
                return error.LibraryNotLoaded;
            };
            return .{ .handle = handle };
        }
        const path_z = try gpa.dupeSentinel(u8, path, 0);
        defer gpa.free(path_z);
        const handle = std.c.dlopen(path_z, .{ .NOW = true }) orelse {
            const reason: [*:0]const u8 = std.c.dlerror() orelse "unknown error";
            std.debug.print("ERROR: Could not load {s}: {s}\n", .{ path, reason });
            return error.LibraryNotLoaded;
        };
        return .{ .handle = handle };
    }

    pub fn lookup(self: DynLib, comptime T: type, name: [:0]const u8) ?T {
        const sym = if (is_windows) win.GetProcAddress(self.handle, name) else std.c.dlsym(self.handle, name);
        return @ptrCast(@alignCast(sym orelse return null));
    }

    /// Fills every field of `Table` (all function pointers) with the symbol of the same name.
    pub fn bind(self: DynLib, comptime Table: type, lib_name: []const u8) error{SymbolNotFound}!Table {
        var table: Table = undefined;
        inline for (comptime std.meta.fieldNames(Table)) |name| {
            @field(table, name) = self.lookup(@FieldType(Table, name), name) orelse {
                std.debug.print("ERROR: {s} has no symbol {s} (wrong version?).\n", .{ lib_name, name });
                return error.SymbolNotFound;
            };
        }
        return table;
    }
};

/// File name of a shared library called `name` on this OS, e.g. libname.so.
pub fn fileName(comptime name: []const u8) []const u8 {
    return "lib" ++ name ++ switch (builtin.os.tag) {
        .windows => ".dll",
        .macos => ".dylib",
        else => ".so",
    };
}
