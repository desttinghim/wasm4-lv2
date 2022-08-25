const std = @import("std");
const c = @import("c.zig");
const WASM4 = @import("wasm4.zig");
const lv2 = @import("lv2.zig");

const URI = "https://github.com/desttinghim/wasm4-lv2";

// Allocator
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator: std.mem.Allocator = gpa.allocator();

export fn instantiate(
    _descriptor: ?[*]const c.LV2_Descriptor,
    rate: f64,
    bundle_path: ?[*]const u8,
    features_opt: ?[*]const ?[*]const c.LV2_Feature,
) callconv(.C) c.LV2_Handle {
    _ = _descriptor;
    _ = bundle_path;
    const features = features_opt orelse return null;

    const self = allocator.create(WASM4) catch {
        std.log.err("Couldn't allocate instance, exiting", .{});
        return null;
    };

    self.init(allocator, rate, features) catch {
        std.log.err("Couldn't initialize WASM4 instrument", .{});
        allocator.destroy(self);
        return null;
    };

    return @ptrCast(c.LV2_Handle, self);
}

export fn connect_port(instance: c.LV2_Handle, port: u32, data: ?*anyopaque) void {
    if (data == null) return;
    const self = @ptrCast(*WASM4, @alignCast(@alignOf(*WASM4), instance));

    self.connect_port(@intToEnum(WASM4.PortIndex, port), data);
}

export fn run(instance: c.LV2_Handle, sample_count: u32) void {
    _ = sample_count;
    if (instance == null) return;
    const self = @ptrCast(*WASM4, @alignCast(@alignOf(*WASM4), instance));

    self.run(sample_count) catch |e| switch(e) {
        error.NoSpaceLeft => {
            std.log.err("Out of space in output buffer", .{});
        },
    };
}

export fn cleanup(instance: c.LV2_Handle) void {
    if (instance == null) return;
    const self = @ptrCast(*WASM4, @alignCast(@alignOf(*WASM4), instance));

    allocator.destroy(self);
}

export fn extension_data(uri: ?[*]const u8) ?*anyopaque {
    _ = uri;
    return null;
}

export const descriptor = c.LV2_Descriptor{
    .URI = URI,
    .instantiate = instantiate,
    .connect_port = connect_port,
    .activate = null,
    .run = run,
    .deactivate = null,
    .cleanup = cleanup,
    .extension_data = extension_data,
};

export fn lv2_descriptor(index: u32) ?*const c.LV2_Descriptor {
    return if (index == 0) &descriptor else null;
}
