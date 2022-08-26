const std = @import("std");
const c = @import("c.zig");
const lv2 = @import("lv2.zig");
const filter = @import("filter.zig");

// Features
map: *c.LV2_URID_Map,
// logger: c.LV2_Log_Logger,

// Port buffers
in_port: ?*const c.LV2_Atom_Sequence = null,
out_port: ?[*]f32 = null,
controls: std.EnumArray(ControlPort, ?*const f32) = std.EnumArray(ControlPort, ?*const f32).initFill(null),

// URI Lookup
uris: URIs,

// Sampling variables
sample_rate: f64,
position: f64 = 0,
key: Key,
apu: c.WASM4_APU = undefined,
buffer_i16: []i16,

pub fn init(this: *@This(), allocator: std.mem.Allocator, sample_rate: f64, features: [*]const ?[*]const c.LV2_Feature) !void {
    if (!std.math.approxEqAbs(f64, @intToFloat(f64, c.W4_SAMPLE_RATE), sample_rate, 0.1))  {
        std.log.info("Host sample_rate={}, w4 sample_rate={}", .{sample_rate, c.W4_SAMPLE_RATE});
        return error.SampleRateMismatch;
    }

    const presentFeatures = try lv2.queryFeatures(allocator, features, &required_features);
    defer allocator.free(presentFeatures);

    this.* = @This(){
        .map = @ptrCast(*c.LV2_URID_Map, @alignCast(@alignOf(c.LV2_URID_Map), presentFeatures[0] orelse {
            return error.MissingURIDMap;
        })),
        .uris = URIs.init(this.map),
        .sample_rate = sample_rate,
        .key = .{
            .rate = sample_rate,
        },
        // Size is copied from scope example
        .buffer_i16 = try allocator.alloc(i16, 65664),
    };

    c.w4_apuInit(&this.apu);
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

fn play(this: *@This(), controls: std.EnumArray(ControlPort, *const f32), output: []f32, start: u32, end: u32) void {
    var i = start;
    while (i < end) : (i += 1) {
        output[i] = this.key.get() * controls.get(.Level).*;
        this.key.proceed();
    }
}

pub fn run(this: *@This(), sample_count: u32) !void {
    const in_port = this.in_port orelse return;
    const out_port = this.out_port orelse return;
    var controls = std.EnumArray(ControlPort, *const f32).initUndefined();
    var control_iter = this.controls.iterator();
    while (control_iter.next()) |control| {
        controls.set(control.key, control.value.* orelse return);
    }

    var output = out_port[0..sample_count];
    _ = output;

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
                    this.key.press(
                        ev.msg[1],
                        ev.msg[2],
                        .{
                            .attack = controls.get(.Attack).*,
                            .decay = controls.get(.Decay).*,
                            .sustain = controls.get(.Sustain).*,
                            .release = controls.get(.Release).*,
                        },
                    );
                },
                c.LV2_MIDI_MSG_NOTE_OFF => {
                    this.key.release(ev.msg[1], ev.msg[2]);
                },
                c.LV2_MIDI_MSG_CONTROLLER => {
                    switch (ev.msg[1]) {
                        c.LV2_MIDI_CTL_ALL_NOTES_OFF,
                        c.LV2_MIDI_CTL_ALL_SOUNDS_OFF,
                        => this.key.off(),
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
    Level = 9,
};

pub const ControlPort = enum(usize) {
    Channel = 2,
    Attack = 3,
    Decay = 4,
    Sustain = 5,
    Release = 6,
    Peak = 7,
    Pan = 8,
    Level = 9,
};

const KeyStatus = enum {
    Off,
    Pressed,
    Released,
};

const Envelope = struct {
    attack: f64,
    decay: f64,
    sustain: f32,
    release: f64,
};

const Key = struct {
    status: KeyStatus = .Off,
    note: u8 = 0,
    velocity: u8 = 0,
    envelope: Envelope = .{
        .attack = 0,
        .decay = 0,
        .sustain = 0,
        .release = 0,
    },
    rate: f64,
    position: f64 = 0,
    start_level: f32 = 0,
    freq: f64 = 0,
    time: f64 = 0,

    fn press(this: *@This(), note: u8, vel: u8, env: Envelope) void {
        this.start_level = this.adsr();
        this.note = note;
        this.velocity = vel;
        this.envelope = env;
        this.status = .Pressed;
        this.freq = std.math.pow(f64, 2.0, (@intToFloat(f64, note) - 69.0) / 12.0) * 440;
        this.time = 0;
    }

    fn release(this: *@This(), note: u8, vel: u8) void {
        _ = vel;
        if (this.status == .Pressed and this.note == note) {
            this.start_level = this.adsr();
            this.time = 0;
            this.status = .Released;
        }
    }

    fn off(this: *@This()) void {
        this.position = 0;
        this.status = .Off;
    }

    fn adsr(this: *@This()) f32 {
        const start_level = @floatCast(f32, this.time);
        const time = @floatCast(f32, this.time);
        const attack = @floatCast(f32, this.envelope.attack);
        const decay = @floatCast(f32, this.envelope.decay);
        const sustain = @floatCast(f32, this.envelope.sustain);
        const _release = @floatCast(f32, this.envelope.release);
        switch (this.status) {
            .Pressed => {
                if (this.time < attack) {
                    return start_level + (1 - start_level) * time / attack;
                }

                if (time < decay) {
                    return 1 + (sustain - 1) * (time - attack) / decay;
                }

                return sustain;
            },
            .Released => {
                return start_level - start_level * time / _release;
            },
            .Off => {
                return 0;
            },
        }
    }

    fn get(this: *@This()) f32 {
        return this.adsr() * std.math.sin(2 * std.math.pi * @floatCast(f32, this.position)) * (@intToFloat(f32, this.velocity) / 127.0);
    }

    fn proceed(this: *@This()) void {
        this.time += 1 / this.rate;
        this.position += this.freq / this.rate;
        if (this.status == .Released and this.time >= this.envelope.release) {
            this.off();
        }
    }
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
