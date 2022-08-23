const std = @import("std");
const testing = std.testing;
const c = @import("c.zig");

const URI = "http://lv2plug.in/plugins/eg-amp";

const PortIndex = enum(usize) {
    Gain = 0,
    Input = 1,
    Output = 2,
};

const Amp = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    allocator: std.mem.Allocator,
    gain: *const f32,
    input: [*]const f32,
    output: [*]f32,
};

export fn instantiate(
    _descriptor: ?[*]const c.LV2_Descriptor,
    rate: f64,
    bundle_path: ?[*]const u8,
    features: ?[*]const ?[*]const c.LV2_Feature,
) callconv(.C) c.LV2_Handle {
    _ = _descriptor;
    _ = rate;
    _ = bundle_path;
    _ = features;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const amp = allocator.create(Amp) catch @panic("Could not allocate");
    return @ptrCast(c.LV2_Handle, amp);
}

export fn connect_port(instance: c.LV2_Handle, port: u32, data: ?*anyopaque) void {
    if (data == null) return;
    const amp = @ptrCast(*Amp, @alignCast(@alignOf(*Amp), instance));

    switch (@intToEnum(PortIndex, port)) {
        .Gain => amp.gain = @ptrCast(*const f32, @alignCast(@alignOf(f32), data)),
        .Input => amp.input = @ptrCast([*]const f32, @alignCast(@alignOf([*]const f32), data)),
        .Output => amp.output = @ptrCast([*]f32, @alignCast(@alignOf([*]f32), data)),
    }
}

export fn activate(instance: c.LV2_Handle) void {
    _ = instance;
}

fn dbCoefficient(g: f32) f32 {
    return if (g > -90.0) std.math.pow(f32, 10.0, g * 0.05) else 0;
}

export fn run(instance: c.LV2_Handle, n_samples: u32) void {
    if (instance == null) return;
    const amp = @ptrCast(*const Amp, @alignCast(@alignOf(*Amp), instance));

    // if (amp.gain == null or amp.input == null or amp.output == null) return;

    const input = amp.input[0..n_samples];
    const output = amp.output[0..n_samples];

    const coef = dbCoefficient(amp.gain.*);

    for (output) |*sample, pos| {
        sample.* = input[pos] * coef;
    }
}

export fn deactivate(instance: c.LV2_Handle) void {
    _ = instance;
}

export fn cleanup(instance: c.LV2_Handle) void {
    if (instance == null) return;
    const amp = @ptrCast(*Amp, @alignCast(@alignOf(*Amp), instance));

    amp.allocator.destroy(amp);
}

export fn extension_data(uri: ?[*]const u8) ?*anyopaque {
    _ = uri;
    return null;
}

export const descriptor = c.LV2_Descriptor{
    .URI = URI,
    .instantiate = instantiate,
    .connect_port = connect_port,
    .activate = activate,
    .run = run,
    .deactivate = deactivate,
    .cleanup = cleanup,
    .extension_data = extension_data,
};

export fn lv2_descriptor(index: u32) ?*const c.LV2_Descriptor {
    return if (index == 0) &descriptor else null;
}
