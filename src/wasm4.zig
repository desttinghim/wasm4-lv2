const std = @import("std");
const c = @import("c.zig");
const lv2 = @import("lv2.zig");

// Features
map: *c.LV2_URID_Map,
// logger: c.LV2_Log_Logger,

// Port buffers
in_port: ?*const c.LV2_Atom_Sequence = null,
out_port: ?[*]f32 = null,
controls: ControlPortArray = ControlPortArray.initFill(null),

// URI Lookup
uris: URIs,

// Sampling variables
sample_rate: f64,
position: f64 = 0,
apu: c.WASM4_APU = undefined,
buffer_i16: []i16,

pub fn init(this: *@This(), allocator: std.mem.Allocator, sample_rate: f64, features: [*]const ?[*]const c.LV2_Feature) !void {
    const presentFeatures = try lv2.queryFeatures(allocator, features, &required_features);
    defer allocator.free(presentFeatures);

    this.* = @This(){
        .map = @ptrCast(*c.LV2_URID_Map, @alignCast(@alignOf(c.LV2_URID_Map), presentFeatures[0] orelse {
            return error.MissingURIDMap;
        })),
        .uris = URIs.init(this.map),
        .sample_rate = sample_rate,
        // Size is copied from scope example
        .buffer_i16 = try allocator.alloc(i16, 65664),
    };

    c.w4_apuInit(&this.apu, @floatToInt(u16, sample_rate));
    std.log.info("Host sample_rate={}, APU sample_rate={}", .{sample_rate, this.apu.sample_rate});
}

pub fn connect_port(this: *@This(), port: PortIndex, ptr: ?*anyopaque) void {
    switch (port) {
        .Input => this.in_port = @ptrCast(*const c.LV2_Atom_Sequence, @alignCast(@alignOf(c.LV2_Atom_Sequence), ptr)),
        .Output => this.out_port = @ptrCast([*]f32, @alignCast(@alignOf([*]f32), ptr)),
        else => {
            const control = @intToEnum(ControlPort, @enumToInt(port));
            this.controls.set(control, @ptrCast(*const f32, @alignCast(@alignOf(f32), ptr)));
        },
    }
}

fn play(this: *@This(), controls: ControlArray, output: []f32, start: u32, end: u32) void {
    var buffer = this.buffer_i16[start * 2..end * 2];
    c.w4_apuWriteSamples(&this.apu, buffer.ptr, @intCast(c_ulong, buffer.len));
    const max_volume = @intToFloat(f32, std.math.maxInt(u16));
    var i = start;
    while (i < end) : (i += 1) {
        output[i] = (@intToFloat(f32, this.buffer_i16[i * 2]) / max_volume) * controls.get(.Volume).*;
    }
}

fn tone(this: *@This(), controls: ControlArray, event: lv2.Event) void {
    const frequency = @floatToInt(u32, midi2freq(event.msg[1]));

    const attack = @maximum(0, @minimum(255, @floatToInt(u32, controls.get(.Attack).* * 60)));
    const decay = @maximum(0, @minimum(255, @floatToInt(u32, controls.get(.Decay).* * 60)));
    const sustain = @as(u32, 255);
    const release = @maximum(0, @minimum(255, @floatToInt(u32, controls.get(.Release).* * 60)));
    const duration = sustain | release << 8 | decay << 16 | attack << 24;

    const peak = @floatToInt(u32, controls.get(.Peak).*);
    const volume_sustain = @maximum(0, @minimum(100, @floatToInt(u16, controls.get(.Volume).* * 100)));
    const volume = volume_sustain | peak << 8;

    const channel = @floatToInt(u32, controls.get(.Channel).*);
    const mode = @floatToInt(u32, controls.get(.Mode).*);
    const pan = @floatToInt(u32, controls.get(.Pan).*);

    const flags = channel | mode << 2 | pan << 4;

    c.w4_apuTone(&this.apu, frequency, duration, volume, flags);
}

fn toneOff(this: *@This(), controls: ControlArray, event: lv2.Event) void {
    const frequency = @floatToInt(u32, midi2freq(event.msg[1]));

    const attack = 0;
    const decay = 0;
    const sustain = 0;
    const release = @maximum(0, @minimum(255, @floatToInt(u32, controls.get(.Release).* * 60)));
    const duration = sustain | release << 8 | decay << 16 | attack << 24;

    const peak = @floatToInt(u32, controls.get(.Peak).*);
    const volume_sustain = @maximum(0, @minimum(100, @floatToInt(u16, controls.get(.Volume).* * 100)));
    const volume = volume_sustain | peak << 8;

    const channel = @floatToInt(u32, controls.get(.Channel).*);
    const mode = @floatToInt(u32, controls.get(.Mode).*);
    const pan = @floatToInt(u32, controls.get(.Pan).*);

    const flags = channel | mode << 2 | pan << 4;

    c.w4_apuTone(&this.apu, frequency, duration, volume, flags);
}

fn toneAllOff(this: *@This()) void {
    c.w4_apuTone(&this.apu, 0, 0, 0, 0);
}

pub fn run(this: *@This(), sample_count: u32) !void {
    if (sample_count > this.buffer_i16.len) return;
    const in_port = this.in_port orelse return;
    const out_port = this.out_port orelse return;
    var controls = ControlArray.initUndefined();
    var control_iter = this.controls.iterator();
    while (control_iter.next()) |control| {
        controls.set(control.key, control.value.* orelse return);
    }

    var output = out_port[0..sample_count];

    var last_frame: i64 = 0;
    // Read incoming events
    var iter = lv2.AtomEventReader.init(in_port);
    while (iter.next()) |ev| {
        const frame = ev.ev.time.frames;
        this.play(controls, output, @intCast(u32, last_frame), @intCast(u32, frame));
        last_frame = frame;

        if (ev.ev.body.type == this.uris.midi_Event) {
            const msg_type = if (ev.msg.len > 1) ev.msg[0] else continue;
            switch (c.lv2_midi_message_type(&msg_type)) {
                c.LV2_MIDI_MSG_NOTE_ON => {
                    this.tone(controls, ev);
                },
                c.LV2_MIDI_MSG_NOTE_OFF => {
                    this.toneOff(controls, ev);
                },
                c.LV2_MIDI_MSG_CONTROLLER => {
                    switch (ev.msg[1]) {
                        c.LV2_MIDI_CTL_ALL_NOTES_OFF,
                        c.LV2_MIDI_CTL_ALL_SOUNDS_OFF,
                        => this.toneAllOff(),
                        else => {},
                    }
                },
                else => {
                    // TODO
                },
            }
        }
    }

    this.play(controls, output, @intCast(u32, last_frame), @intCast(u32, sample_count));
}

fn midi2freq(note: u8) f32 {
    return std.math.pow(f32, 2.0, (@intToFloat(f32, note) - 69.0) / 12.0) * 440;
}

pub const required_features = [_]lv2.FeatureQuery{
    .{ .uri = c.LV2_URID__map, .required = true },
};

pub const PortIndex = enum(usize) {
    Input = 0,
    Output = 1,
    Channel = 2,
    Attack = 3,
    Decay = 4,
    Sustain = 5,
    Release = 6,
    Peak = 7,
    Pan = 8,
    Volume = 9,
    Mode = 10,
};

pub const ControlPort = enum(usize) {
    Channel = 2,
    Attack = 3,
    Decay = 4,
    Sustain = 5,
    Release = 6,
    Peak = 7,
    Pan = 8,
    Volume = 9,
    Mode = 10,
};

const ControlPortArray = std.EnumArray(ControlPort, ?*const f32);
const ControlArray = std.EnumArray(ControlPort, *const f32);

const KeyStatus = enum {
    Off,
    Pressed,
    Released,
};

const URIs = struct {
    atom_Path: c.LV2_URID,
    atom_Resource: c.LV2_URID,
    atom_Sequence: c.LV2_URID,
    atom_URID: c.LV2_URID,
    atom_eventTransfer: c.LV2_URID,
    midi_Event: c.LV2_URID,
    patch_Set: c.LV2_URID,
    patch_property: c.LV2_URID,
    patch_value: c.LV2_URID,

    fn init(map: *c.LV2_URID_Map) @This() {
        const mapfn = map.map.?;
        return .{
            .atom_Path = mapfn(map.handle, c.LV2_ATOM__Path),
            .atom_Resource = mapfn(map.handle, c.LV2_ATOM__Resource),
            .atom_Sequence = mapfn(map.handle, c.LV2_ATOM__Sequence),
            .atom_URID = mapfn(map.handle, c.LV2_ATOM__URID),
            .atom_eventTransfer = mapfn(map.handle, c.LV2_ATOM__eventTransfer),
            .midi_Event = mapfn(map.handle, c.LV2_MIDI__MidiEvent),
            .patch_Set = mapfn(map.handle, c.LV2_PATCH__Set),
            .patch_property = mapfn(map.handle, c.LV2_PATCH__property),
            .patch_value = mapfn(map.handle, c.LV2_PATCH__value),
        };
    }
};
