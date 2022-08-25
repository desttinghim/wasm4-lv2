const std = @import("std");
const c = @import("c.zig");
const lv2 = @import("lv2.zig");

// Features
map: *c.LV2_URID_Map,
// logger: c.LV2_Log_Logger,

// Port buffers
in_port: *const c.LV2_Atom_Sequence,
out_port: [*]f32,
channel: *const f32,
attack: *const f32,
decay: *const f32,
sustain: *const f32,
release: *const f32,
peak: *const f32,
pan: *const f32,

uris: URIs,


pub fn init(this: *@This(), allocator: std.mem.Allocator, features:  [*]const ?[*]const c.LV2_Feature) !void {
    const presentFeatures = try lv2.queryFeatures(allocator, features, &required_features);
    defer allocator.free(presentFeatures);

    this.map = @ptrCast(*c.LV2_URID_Map, @alignCast(@alignOf(c.LV2_URID_Map), presentFeatures[0] orelse {
        return error.MissingURIDMap;
    }));

    this.uris = URIs.init(this.map);
}

pub fn connect_port(this: *@This(), port: PortIndex, ptr: ?*anyopaque) void {
    switch (port) {
        .Input => this.in_port = @ptrCast(*const c.LV2_Atom_Sequence, @alignCast(@alignOf(c.LV2_Atom_Sequence), ptr)),
        .Output => this.out_port = @ptrCast([*]f32, @alignCast(@alignOf([*]f32), ptr)),
        .Channel => this.channel = @ptrCast(*const f32, @alignCast(@alignOf(f32), ptr)),
        .Attack => this.attack = @ptrCast(*const f32, @alignCast(@alignOf(f32), ptr)),
        .Decay => this.decay = @ptrCast(*const f32, @alignCast(@alignOf(f32), ptr)),
        .Sustain => this.sustain = @ptrCast(*const f32, @alignCast(@alignOf(f32), ptr)),
        .Release => this.release = @ptrCast(*const f32, @alignCast(@alignOf(f32), ptr)),
        .Peak => this.peak = @ptrCast(*const f32, @alignCast(@alignOf(f32), ptr)),
        .Pan => this.pan = @ptrCast(*const f32, @alignCast(@alignOf(f32), ptr)),
    }
}


// Struct for 3 byte MIDI event, used for writing notes
const MIDINoteEvent = extern struct {
    event: c.LV2_Atom_Event,
    msg: [3]u8,
};

pub fn run(this: *@This(), sample_count: u32) !void {

    var output = this.out_port[0..sample_count];
    _ = output;

    // Read incoming events
    var iter = lv2.AtomEventReader.init(this.in_port);
    while (iter.next()) |ev| {
        if (ev.ev.body.type == this.uris.midi_Event) {
            const msg_type = if (ev.msg.len > 1) ev.msg[0] else continue;
            switch (c.lv2_midi_message_type(&msg_type)) {
                c.LV2_MIDI_MSG_NOTE_ON,
                c.LV2_MIDI_MSG_NOTE_OFF,
                => {
                    // TODO read notes and write to apu
                },
                else => {
                    // TODO
                },
            }
        }
    }
}

pub const required_features =  [_]lv2.FeatureQuery{
    .{.uri = c.LV2_URID__map, .required = true},
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
