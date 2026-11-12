//! Windows: DirectShow video input devices, through COM declared by hand.
//! Mirrors OpenCV's cap_dshow.cpp: the index of a camera is the position of its
//! moniker in the CLSID_VideoInputDeviceCategory enumeration (videoInput::getDevice
//! counts every moniker), but open() rejects indices past the number of monikers
//! with a readable property bag (listDevices) and fails on a device without a
//! FriendlyName (getDevice), so such devices are left out of the list.
const std = @import("std");
const GUID = std.os.windows.GUID;
const Camera = @import("enumerate.zig").Camera;

/// cv::CAP_DSHOW
pub const opencv_api: c_int = 700;
pub const device_fmt = "camera {d}";

pub fn list(arena: std.mem.Allocator, io: std.Io) ![]Camera {
    _ = io;
    // Already initialised on this thread (S_FALSE) or in another apartment
    // model (RPC_E_CHANGED_MODE): COM is usable either way.
    const init = CoInitializeEx(null, COINIT_MULTITHREADED);
    defer if (init >= 0) CoUninitialize();

    var dev_enum: *ICreateDevEnum = undefined;
    if (CoCreateInstance(&CLSID_SystemDeviceEnum, null, CLSCTX_INPROC_SERVER, &IID_ICreateDevEnum, @ptrCast(&dev_enum)) < 0)
        return error.DeviceEnumUnavailable;
    defer release(dev_enum);

    var monikers: ?*IEnumMoniker = null;
    const hr = dev_enum.vtbl.CreateClassEnumerator(dev_enum, &CLSID_VideoInputDeviceCategory, &monikers, 0);
    if (hr < 0) return error.DeviceEnumFailed;
    const it = monikers orelse return &.{}; // S_FALSE: empty category
    defer release(it);

    var cameras: std.ArrayList(Camera) = .empty;
    var index: u32 = 0; // every moniker, as getDevice counts
    var bindable: u32 = 0; // monikers with a property bag, as listDevices counts
    var moniker: *IMoniker = undefined;
    while (it.vtbl.Next(it, 1, &moniker, null) == S_OK) : (index += 1) {
        defer release(moniker);
        var bag: *IPropertyBag = undefined;
        if (moniker.vtbl.BindToStorage(moniker, null, null, &IID_IPropertyBag, @ptrCast(&bag)) < 0) continue;
        defer release(bag);
        bindable += 1;

        var name: VARIANT = .{};
        defer _ = VariantClear(&name);
        if (bag.vtbl.Read(bag, std.unicode.utf8ToUtf16LeStringLiteral("FriendlyName"), &name, null) < 0) continue;
        if (name.vt != VT_BSTR) continue;
        const bstr = name.val.bstr orelse continue;
        try cameras.append(arena, .{ .num = index, .name = try std.unicode.wtf16LeToWtf8Alloc(arena, std.mem.span(bstr)) });
    }

    // open() bounds indices by the listDevices count, not the moniker position.
    var n: usize = 0;
    for (cameras.items) |cam| {
        if (cam.num < bindable) {
            cameras.items[n] = cam;
            n += 1;
        }
    }
    return cameras.items[0..n];
}

// COM, declared by hand. Vtables follow objidl.h, oaidl.h and strmif.h.

const HRESULT = i32;
const S_OK: HRESULT = 0;
const COINIT_MULTITHREADED: u32 = 0;
const CLSCTX_INPROC_SERVER: u32 = 1;
const VT_BSTR: u16 = 8;

const CLSID_SystemDeviceEnum = GUID.parse("{62BE5D10-60EB-11d0-BD3B-00A0C911CE86}");
const CLSID_VideoInputDeviceCategory = GUID.parse("{860BB310-5D01-11d0-BD3B-00A0C911CE86}");
const IID_ICreateDevEnum = GUID.parse("{29840822-5B84-11D0-BD3B-00A0C911CE86}");
const IID_IPropertyBag = GUID.parse("{55272A00-42CB-11CE-8135-00AA004BB851}");

const VARIANT = extern struct {
    vt: u16 = 0, // VT_EMPTY, as VariantInit leaves it
    reserved: [3]u16 = .{ 0, 0, 0 },
    // Largest members are DECIMAL (overlapping vt) and BRECORD (two pointers).
    val: extern union { bstr: ?[*:0]u16, record: [2]usize } = .{ .record = .{ 0, 0 } },
};

fn Unknown(comptime Self: type) type {
    return extern struct {
        QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Self) callconv(.winapi) u32,
        Release: *const fn (*Self) callconv(.winapi) u32,
    };
}

const Unused = *const anyopaque;

fn release(obj: anytype) void {
    _ = obj.vtbl.unknown.Release(obj);
}

const ICreateDevEnum = extern struct {
    vtbl: *const extern struct {
        unknown: Unknown(ICreateDevEnum),
        CreateClassEnumerator: *const fn (*ICreateDevEnum, *const GUID, *?*IEnumMoniker, u32) callconv(.winapi) HRESULT,
    },
};

const IEnumMoniker = extern struct {
    vtbl: *const extern struct {
        unknown: Unknown(IEnumMoniker),
        Next: *const fn (*IEnumMoniker, u32, **IMoniker, ?*u32) callconv(.winapi) HRESULT,
        Skip: Unused,
        Reset: Unused,
        Clone: Unused,
    },
};

const IMoniker = extern struct {
    vtbl: *const extern struct {
        unknown: Unknown(IMoniker),
        GetClassID: Unused, // IPersist
        IsDirty: Unused, // IPersistStream
        Load: Unused,
        Save: Unused,
        GetSizeMax: Unused,
        BindToObject: Unused, // IMoniker
        BindToStorage: *const fn (*IMoniker, ?*anyopaque, ?*IMoniker, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        // Reduce, ComposeWith, ... are never called, so need no slots.
    },
};

const IPropertyBag = extern struct {
    vtbl: *const extern struct {
        unknown: Unknown(IPropertyBag),
        Read: *const fn (*IPropertyBag, [*:0]const u16, *VARIANT, ?*anyopaque) callconv(.winapi) HRESULT,
        Write: Unused,
    },
};

extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, coinit: u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoCreateInstance(clsid: *const GUID, outer: ?*anyopaque, context: u32, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT;
extern "oleaut32" fn VariantClear(v: *VARIANT) callconv(.winapi) HRESULT;
