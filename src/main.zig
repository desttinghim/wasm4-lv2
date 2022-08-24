const std = @import("std");
const testing = std.testing;
const c = @import("c.zig");

const URI = "http://lv2plug.in/plugins/eg-midigate";

// Allocator
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator : std.mem.Allocator = gpa.allocator();

const PortIndex = enum(usize) {
    Control = 0,
    Input = 1,
    Output = 2,
};

const Midigate = struct {

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
    // gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // allocator = gpa.allocator();
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

const AtomEventIter = struct {
    sequence: *const c.LV2_Atom_Sequence,
    begin: [*]const c.LV2_Atom_Event,
    iter: [*]const c.LV2_Atom_Event,

    fn init (sequence: *const c.LV2_Atom_Sequence) @This() {
        const ptr_int = @ptrToInt(&sequence) + @sizeOf(c.LV2_Atom_Sequence);
        const ptr = @ptrCast([*]const c.LV2_Atom_Event, @alignCast(@alignOf(u64), @intToPtr([*]const u8, ptr_int)));
        return @This() {
            .sequence = sequence,
            .begin = ptr,
            .iter = ptr,
        };
    }

    fn next(self: *@This()) ?*const c.LV2_Atom_Event {
        if (@ptrToInt(self.iter) >= @ptrToInt(&self.sequence.body) + self.sequence.atom.size) {
            return null;
        }
        const iter = self.iter;
        self.iter = c.lv2_atom_sequence_next(self.iter);
        return &iter[0];
    }
};

export fn run(instance: c.LV2_Handle, sample_count: u32) void {
    if (instance == null) return;
    const self = @ptrCast(*Midigate, @alignCast(@alignOf(*Midigate), instance));
    var offset: u32 = 0;

    std.debug.assert(self.control.atom.size % @alignOf(u64) == 0);

    var iter = AtomEventIter.init(self.control);
    while (iter.next()) |ev| {
        if (ev.body.type == self.uris.midi_MidiEvent) {
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
        write_output(self, offset, @intCast(u64, ev.time.frames) - offset);
        offset = @intCast(u32, ev.time.frames);
    }

    write_output(self, offset, sample_count - offset);
}

export fn deactivate(instance: c.LV2_Handle) void {
    _ = instance;
}

export fn cleanup(instance: c.LV2_Handle) void {
    std.log.info("[cleanup] begin", .{});
    if (instance == null) return;
    const self = @ptrCast(*Midigate, @alignCast(@alignOf(*Midigate), instance));

    std.log.info("[cleanup] destroy", .{});
    allocator.destroy(self);
    std.log.info("[cleanup] complete", .{});
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
