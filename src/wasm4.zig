const std = @import("std");
const c = @import("c.zig");
const lv2 = @import("lv2.zig");

// Features
map: *c.LV2_URID_Map,
// logger: c.LV2_Log_Logger,
max_block_length: u32,

// Port buffers
in_port: ?*const c.LV2_Atom_Sequence = null,
out_left_port: ?[*]f32 = null,
out_right_port: ?[*]f32 = null,
controls: ControlPortArray = ControlPortArray.initFill(null),

// URI Lookup
uris: URIs,

// Sampling variables
sample_rate: f64,
position: f64 = 0,
apu: c.WASM4_APU = undefined,
current_note: [4]u8 = .{ 0, 0, 0, 0 },
buffer_i16: []i16,

pub fn init(this: *@This(), allocator: std.mem.Allocator, sample_rate: f64, features: [*]const ?[*]const c.LV2_Feature) !void {
    const presentFeatures = try lv2.queryFeatures(allocator, features, &required_features);
    defer allocator.free(presentFeatures);

    std.log.info("2", .{});

    // const map = @ptrCast(*c.LV2_URID_Map, @alignCast(@alignOf(c.LV2_URID_Map), presentFeatures[0] orelse {
    //     return error.MissingURIDMap;
    // }));

    // const uris = URIs.init(this.map);

    const max_block_length = 4096;
    // const max_block_length = block_length: {
    //     const options = @ptrCast([*]c.LV2_Options_Option, @alignCast(@alignOf(c.LV2_Options_Option), presentFeatures[1] orelse break :block_length 65536));
    //     const max_block_length_option = lv2.queryOption(options, uris.bufSize_maxBlockLength) orelse break :block_length 65536;
    //     break :block_length @ptrCast(*const u32, @alignCast(@alignOf(u32), max_block_length_option.value)).*;
    // };

    this.* = @This(){
        .map = @ptrCast(*c.LV2_URID_Map, @alignCast(@alignOf(c.LV2_URID_Map), presentFeatures[0] orelse {
            return error.MissingURIDMap;
        })),
        // .options = options,
        .max_block_length = max_block_length,
        .uris = URIs.init(this.map),
        .sample_rate = sample_rate,
        // Size is copied from scope example
        .buffer_i16 = try allocator.alloc(i16, max_block_length * 2),
    };

    c.w4_apuInit(&this.apu, @floatToInt(u16, sample_rate));
    std.log.info("Host sample_rate={}, APU sample_rate={}", .{ sample_rate, this.apu.sample_rate });
}

pub fn connect_port(this: *@This(), portIndex: u32, ptr: ?*anyopaque) void {
    const port = std.meta.intToEnum(PortIndex, portIndex) catch {
        const control = std.meta.intToEnum(ControlPort, portIndex) catch {
            // TODO: log error
            return;
        };
        this.controls.set(control, @ptrCast(*const f32, @alignCast(@alignOf(f32), ptr)));
        return;
    };
    switch (port) {
        .Input => this.in_port = @ptrCast(*const c.LV2_Atom_Sequence, @alignCast(@alignOf(c.LV2_Atom_Sequence), ptr)),
        .OutputLeft => this.out_left_port = @ptrCast([*]f32, @alignCast(@alignOf([*]f32), ptr)),
        .OutputRight => this.out_right_port = @ptrCast([*]f32, @alignCast(@alignOf([*]f32), ptr)),
    }
}

fn play(this: *@This(), controls: ControlArray, output_left: []f32, output_right: []f32, start: u32, end: u32) void {
    var buffer = this.buffer_i16[start * 2 .. end * 2 + 1];
    c.w4_apuWriteSamples(&this.apu, buffer.ptr, @intCast(c_ulong, buffer.len));
    const max_volume = @intToFloat(f32, std.math.maxInt(u16));
    var i = start;
    while (i < end) : (i += 1) {
        output_left[i] = (@intToFloat(f32, this.buffer_i16[i * 2]) / max_volume) * controls.get(.Volume).*;
        output_right[i] = (@intToFloat(f32, this.buffer_i16[i * 2 + 1]) / max_volume) * controls.get(.Volume).*;
    }
}

fn tone(this: *@This(), controls: ControlArray, event: lv2.Event, channel: u32) void {
    const frequency = freq: {
        const start = controls.get(.StartFreq).*;
        const end = controls.get(.EndFreq).*;
        if (@fabs(end) < 1.0) {
            break :freq @floatToInt(u32, midi2freq(event.msg[1]));
        } else {
            const starti = 0xFFFF & @floatToInt(u32, start);
            const endi = 0xFFFF & @floatToInt(u32, end);
            break :freq starti | endi << 16;
        }
    };

    const attack = @maximum(0, @minimum(255, @floatToInt(u32, controls.get(.Attack).*)));
    const decay = @maximum(0, @minimum(255, @floatToInt(u32, controls.get(.Decay).*)));
    const sustain = sustain: {
        if (@floatToInt(u32, controls.get(.SustainMode).*) == 1) {
            break :sustain @maximum(0, @minimum(255, @floatToInt(u32, controls.get(.Sustain).*)));
        }
        break :sustain @as(u32, 255);
    };
    const release = @maximum(0, @minimum(255, @floatToInt(u32, controls.get(.Release).*)));
    const duration = sustain | release << 8 | decay << 16 | attack << 24;

    const peak = @floatToInt(u32, controls.get(.Peak).*);
    const volume_sustain = @maximum(0, @minimum(100, @floatToInt(u16, controls.get(.Volume).*)));
    const volume = volume_sustain | peak << 8;

    const mode = @floatToInt(u32, controls.get(.Mode).*);
    const pan = @floatToInt(u32, controls.get(.Pan).*);

    const flags = channel | mode << 2 | pan << 4;

    c.w4_apuTone(&this.apu, frequency, duration, volume, flags);
}

fn toneOff(this: *@This(), controls: ControlArray, event: lv2.Event, channel: u32) void {
    if (@floatToInt(u32, controls.get(.SustainMode).*) == 1) {
        return;
    }
    const frequency = @floatToInt(u32, midi2freq(event.msg[1]));

    const attack = 0;
    const decay = 0;
    const sustain = 0;
    const release = @maximum(0, @minimum(255, @floatToInt(u32, controls.get(.Release).*)));
    const duration = sustain | release << 8 | decay << 16 | attack << 24;

    const peak = @floatToInt(u32, controls.get(.Peak).*);
    const volume_sustain = @maximum(0, @minimum(100, @floatToInt(u16, controls.get(.Volume).*)));
    const volume = volume_sustain | peak << 8;

    const mode = @floatToInt(u32, controls.get(.Mode).*);
    const pan = @floatToInt(u32, controls.get(.Pan).*);

    const flags = channel | mode << 2 | pan << 4;

    c.w4_apuTone(&this.apu, frequency, duration, volume, flags);
}

fn toneAllOff(this: *@This()) void {
    c.w4_apuTone(&this.apu, 0, 0, 0, 0);
    c.w4_apuTone(&this.apu, 0, 0, 0, 1);
    c.w4_apuTone(&this.apu, 0, 0, 0, 2);
    c.w4_apuTone(&this.apu, 0, 0, 0, 3);
}

pub fn run(this: *@This(), sample_count: u32) !void {
    if (sample_count > this.buffer_i16.len) return;
    const in_port = this.in_port orelse return;
    const out_left_port = this.out_left_port orelse return;
    const out_right_port = this.out_right_port orelse return;
    var controls = ControlArray.initUndefined();
    var control_iter = this.controls.iterator();
    while (control_iter.next()) |control| {
        controls.set(control.key, control.value.* orelse return);
    }

    var output_left = out_left_port[0..sample_count];
    var output_right = out_right_port[0..sample_count];

    var last_frame: i64 = 0;
    // Read incoming events
    var iter = lv2.AtomEventReader.init(in_port);
    midi_loop: while (iter.next()) |ev| {
        const frame = ev.ev.time.frames;
        this.play(controls, output_left, output_right, @intCast(u32, last_frame), @intCast(u32, frame));
        last_frame = frame;

        if (ev.ev.body.type == this.uris.midi_Event) {
            const msg_type = if (ev.msg.len > 1) ev.msg[0] else continue;
            const channel_real = @intCast(u32, ev.msg[0] & 0b1111) + 1; // Read channel from last 4 bits of status byte
            const channel: u32 = chan: {
                if (@floatToInt(u32, controls.get(.Pulse1Channel).*) == channel_real) {
                    break :chan 0;
                } else if (@floatToInt(u32, controls.get(.Pulse2Channel).*) == channel_real) {
                    break :chan 1;
                } else if (@floatToInt(u32, controls.get(.TriangleChannel).*) == channel_real) {
                    break :chan 2;
                } else if (@floatToInt(u32, controls.get(.NoiseChannel).*) == channel_real) {
                    break :chan 3;
                }
                continue :midi_loop;
            };
            switch (c.lv2_midi_message_type(&msg_type)) {
                c.LV2_MIDI_MSG_NOTE_ON => {
                    this.tone(controls, ev, channel);
                    this.current_note[channel] = ev.msg[1];
                },
                c.LV2_MIDI_MSG_NOTE_OFF => {
                    if (this.current_note[channel] == ev.msg[1]) {
                        this.toneOff(controls, ev, channel);
                    }
                },
                c.LV2_MIDI_MSG_PGM_CHANGE => {
                    // TODO: change the "instrument"
                },
                c.LV2_MIDI_MSG_CONTROLLER => {
                    switch (ev.msg[1]) {
                        c.LV2_MIDI_CTL_ALL_NOTES_OFF,
                        c.LV2_MIDI_CTL_ALL_SOUNDS_OFF,
                        => this.toneAllOff(),
                        c.LV2_MIDI_CTL_MSB_BANK => {
                            // TODO: swap out presets?
                        },
                        c.LV2_MIDI_CTL_SUSTAIN => {
                            // TODO
                        },
                        c.LV2_MIDI_CTL_PORTAMENTO => {
                            // TODO
                        },
                        else => {},
                    }
                },
                else => {
                    // TODO
                },
            }
        }
    }

    this.play(controls, output_left, output_right, @intCast(u32, last_frame), @intCast(u32, sample_count));
}

fn midi2freq(note: u8) f32 {
    return std.math.pow(f32, 2.0, (@intToFloat(f32, note) - 69.0) / 12.0) * 440;
}

pub const required_features = [_]lv2.URIQuery{
    .{ .uri = c.LV2_URID__map, .required = true },
    // .{ .uri = c.LV2_OPTIONS__options, .required = true },
};

pub const PortIndex = enum(usize) {
    Input = 0,
    OutputLeft = 1,
    OutputRight = 2,
};

pub const ControlPort = enum(usize) {
    Attack = 3,
    Decay = 4,
    Sustain = 5,
    Release = 6,
    Peak = 7,
    Pan = 8,
    Volume = 9,
    Mode = 10,
    StartFreq = 11,
    EndFreq = 12,
    SustainMode = 13,
    Pulse1Channel = 14,
    Pulse2Channel = 15,
    TriangleChannel = 16,
    NoiseChannel = 17,
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
    // bufSize_boundedBlockLength: c.LV2_URID,
    // bufSize_maxBlockLength: c.LV2_URID,
    // bufSize_minBlockLength: c.LV2_URID,
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
            // .bufSize_boundedBlockLength = mapfn(map.handle, c.LV2_BUF_SIZE__boundedBlockLength),
            // .bufSize_maxBlockLength = mapfn(map.handle, c.LV2_BUF_SIZE__maxBlockLength),
            // .bufSize_minBlockLength = mapfn(map.handle, c.LV2_BUF_SIZE__minBlockLength),
            .midi_Event = mapfn(map.handle, c.LV2_MIDI__MidiEvent),
            .patch_Set = mapfn(map.handle, c.LV2_PATCH__Set),
            .patch_property = mapfn(map.handle, c.LV2_PATCH__property),
            .patch_value = mapfn(map.handle, c.LV2_PATCH__value),
        };
    }
};
