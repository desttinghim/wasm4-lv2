const std = @import("std");
const testing = std.testing;
const c = @import("c.zig");

const URI = "http://lv2plug.in/plugins/eg-midigate";

const PortIndex = enum(usize) {
    Control = 0,
    Input = 1,
    Output = 2,
};

const Midigate = struct {
    // Allocator
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    allocator: std.mem.Allocator,

    // Port buffers
    control: *const c.LV2_Atom_Sequence,
    input: [*]const f32,
    output: [*]f32,

    // Features
    map: *c.LV2_URID_Map,
    // logger: c.LV2_Log_Logger,

    uris: struct {
        midi_MidiEvent: c.LV2_URID,
    },

    n_active_notes: usize,
    program: usize, // 0 = normal, 1 = inverted
};

const FeatureQuery = struct {
    uri: [*:0]const u8,
    data: *?*anyopaque,
    required: bool,
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
    std.log.info("[instantiate] start", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const self = allocator.create(Midigate) catch @panic("Could not allocate");

    // Scan host features for URID map and return null if the host does not have it
    self.map = @ptrCast(*c.LV2_URID_Map, @alignCast(@alignOf(c.LV2_URID_Map), c.lv2_features_data(features, c.LV2_URID__map) orelse {
        std.log.err("Missing feature <{s}>\n", .{ c.LV2_URID__map });
        allocator.destroy(self);
        return null;
    }));

    self.uris.midi_MidiEvent = self.map.map.?(self.map.handle, c.LV2_MIDI__MidiEvent);

    std.log.info("[instantiate] complete", .{});
    return @ptrCast(c.LV2_Handle, self);
}

export fn connect_port(instance: c.LV2_Handle, port: u32, data: ?*anyopaque) void {
    if (data == null) return;
    const self = @ptrCast(*Midigate, @alignCast(@alignOf(*Midigate), instance));

    switch (@intToEnum(PortIndex, port)) {
        .Control => self.control = @ptrCast(*const c.LV2_Atom_Sequence, @alignCast(@alignOf(c.LV2_Atom_Sequence), data)),
        .Input => self.input = @ptrCast([*]const f32, @alignCast(@alignOf([*]const f32), data)),
        .Output => self.output = @ptrCast([*]f32, @alignCast(@alignOf([*]f32), data)),
    }
}

export fn activate(instance: c.LV2_Handle) void {
    const self = @ptrCast(*Midigate, @alignCast(@alignOf(*Midigate), instance));
    self.n_active_notes = 0;
    self.program = 0;
}

fn write_output(self: *Midigate, offset: u64, len: u64) void {
    const active = if (self.program == 0) self.n_active_notes > 0 else self.n_active_notes == 0;

    if (active) {
        std.mem.copy(f32, self.output[offset..offset+len], self.input[offset..offset+len]);
    } else {
        std.mem.set(f32, self.output[offset..offset+len], 0);
    }
}

export fn run(instance: c.LV2_Handle, sample_count: u32) void {
    if (instance == null) return;
    const self = @ptrCast(*Midigate, @alignCast(@alignOf(*Midigate), instance));
    var offset: u32 = 0;

    std.debug.assert(self.control.atom.size % @alignOf(u64) == 0);

    const atom = @ptrCast([*]const u8, &self.control.atom);
    std.log.warn("atom {any}", .{atom[0..@sizeOf(c.LV2_Atom_Sequence)].*});
    const body = &self.control.body;
    std.log.warn("align {}, {*}", .{@alignOf([*c]c.LV2_Atom_Event), body});
    const fds = @ptrCast([*]const u8, body);
    std.log.warn("midi type {}, fds {any}", .{self.uris.midi_MidiEvent, fds[0..self.control.atom.size]});
    const fds2 = @ptrCast([*]const u32, @intToPtr([*]const u32, @ptrToInt(body)));
    std.log.warn("fds2 {any}", .{fds2[0..self.control.atom.size / 4]});
    const begin = @ptrCast([*]const c.LV2_Atom_Event, @alignCast(@alignOf(u64), @intToPtr([*]const u8, @ptrToInt(&self.control) + @sizeOf(c.LV2_Atom_Sequence))));
    var iter = begin;
    while (@ptrToInt(iter) < @ptrToInt(&self.control.body) + self.control.atom.size) {
        const ev = iter;
        iter = c.lv2_atom_sequence_next(iter);

        std.log.warn("ev[0] {}, {}", .{ev[0], ev[0].body.type});
        if (ev[0].body.type == self.uris.midi_MidiEvent) {
            const msg = @intToPtr([*]const u8, @ptrToInt(ev) + 1);
            std.log.warn("msg {*}", .{msg});
            switch (c.lv2_midi_message_type(msg)) {
                c.LV2_MIDI_MSG_NOTE_ON => self.n_active_notes += 1,
                c.LV2_MIDI_MSG_NOTE_OFF => self.n_active_notes -|= 1,
                c.LV2_MIDI_MSG_CONTROLLER => {
                    if (msg[1] == c.LV2_MIDI_CTL_ALL_NOTES_OFF) {
                        self.n_active_notes = 0;
                    }
                },
                c.LV2_MIDI_MSG_PGM_CHANGE => {
                    if (msg[1] == 0 or msg[1] == 1) {
                        self.program = msg[1];
                    }
                },
                else => {},
            }
        }
        // std.log.warn("frames: {}, offset {}, {}", .{ev.time.frames, offset, @intCast(u64, ev.time.frames) - offset});
        std.log.warn("offset {}, frames {}, beats {}", .{offset, ev[0].time.frames, ev[0].time.beats});
        write_output(self, offset, @intCast(u64, ev[0].time.frames) - offset);
        offset = @intCast(u32, ev[0].time.frames);
    }

    write_output(self, offset, sample_count - offset);
}

export fn deactivate(instance: c.LV2_Handle) void {
    _ = instance;
}

export fn cleanup(instance: c.LV2_Handle) void {
    if (instance == null) return;
    const self = @ptrCast(*Midigate, @alignCast(@alignOf(*Midigate), instance));

    self.allocator.destroy(self);
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
