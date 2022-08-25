const std = @import("std");
const testing = std.testing;
const c = @import("c.zig");

const URI = "http://lv2plug.in/plugins/eg-fifths";

// Allocator
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator: std.mem.Allocator = gpa.allocator();

const PortIndex = enum(usize) {
    Input = 0,
    Output = 1,
};

const FifthsURIs = struct {
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

const Fifths = struct {
    // Features
    map: *c.LV2_URID_Map,
    // logger: c.LV2_Log_Logger,

    // Port buffers
    in_port: *const c.LV2_Atom_Sequence,
    out_port: *c.LV2_Atom_Sequence,

    uris: FifthsURIs,
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

    const self = allocator.create(Fifths) catch {
        std.log.err("Couldn't allocate instance, exiting", .{});
        return null;
    };

    // Scan host features for URID map and return null if the host does not have it
    self.map = @ptrCast(*c.LV2_URID_Map, @alignCast(@alignOf(c.LV2_URID_Map), c.lv2_features_data(features, c.LV2_URID__map) orelse {
        std.log.err("Missing feature <{s}>, exiting", .{c.LV2_URID__map});
        allocator.destroy(self);
        return null;
    }));

    self.uris = FifthsURIs.init(self.map);
    // self.uris.midi_MidiEvent = self.map.map.?(self.map.handle, c.LV2_MIDI__MidiEvent);

    std.log.info("[instantiate] complete", .{});
    return @ptrCast(c.LV2_Handle, self);
}

export fn connect_port(instance: c.LV2_Handle, port: u32, data: ?*anyopaque) void {
    if (data == null) return;
    const self = @ptrCast(*Fifths, @alignCast(@alignOf(*Fifths), instance));

    switch (@intToEnum(PortIndex, port)) {
        .Input => self.in_port = @ptrCast(*const c.LV2_Atom_Sequence, @alignCast(@alignOf(c.LV2_Atom_Sequence), data)),
        .Output => self.out_port = @ptrCast(*c.LV2_Atom_Sequence, @alignCast(@alignOf(c.LV2_Atom_Sequence), data)),
    }
}

const AtomEventIter = struct {
    sequence: *const c.LV2_Atom_Sequence,
    begin: [*]const c.LV2_Atom_Event,
    iter: [*]const c.LV2_Atom_Event,

    fn init(sequence: *const c.LV2_Atom_Sequence) @This() {
        const ptr_int = @ptrToInt(&sequence) + @sizeOf(c.LV2_Atom_Sequence);
        const ptr = @ptrCast([*]const c.LV2_Atom_Event, @alignCast(@alignOf(u64), @intToPtr([*]const u8, ptr_int)));
        return @This(){
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
    _ = sample_count;
    if (instance == null) return;
    const self = @ptrCast(*Fifths, @alignCast(@alignOf(*Fifths), instance));

    // Struct for 3 byte MIDI event, used for writing notes
    const MIDINoteEvent = struct {
        event: c.LV2_Atom_Event,
        msg: [3]u8,
    };

    // Initially self.out_port contains a Chunk with size set to capacity

    // Get the capacity
    const out_capacity = self.out_port.atom.size;

    // Write an empty Sequence header to the output
    c.lv2_atom_sequence_clear(self.out_port);
    self.out_port.atom.type = self.in_port.atom.type;

    std.debug.assert(self.in_port.atom.size % @alignOf(u64) == 0);
    std.debug.assert(self.out_port.atom.size % @alignOf(u64) == 0);

    // Read incoming events
    var iter = AtomEventIter.init(self.in_port);
    while (iter.next()) |ev| {
        if (ev.body.type == self.uris.midi_Event) {
            const msg = @intToPtr([*]const u8, @ptrToInt(ev) + 1);
            switch (c.lv2_midi_message_type(msg)) {
                c.LV2_MIDI_MSG_NOTE_ON,
                c.LV2_MIDI_MSG_NOTE_OFF,
                => {
                    // Forward note to output
                    _ = c.lv2_atom_sequence_append_event(self.out_port, out_capacity, ev);

                    if (msg[1] <= 127 - 7) {
                        // Make a note one 5th (7 semitones) higher than input
                        // We could simply copy the value of ev here...
                        var fifth = MIDINoteEvent{
                            .event = .{
                                .time = .{ .frames = ev.time.frames }, // Same time
                                .body = .{
                                    .type = ev.body.type, // Same type
                                    .size = ev.body.size, // Same size
                                },
                            },
                            .msg = .{
                                msg[0], // Same status
                                msg[1] + 7, // Pitch up 7 semitones
                                msg[2], // Same velocity
                            },
                        };

                        _ = c.lv2_atom_sequence_append_event(self.out_port, out_capacity, &fifth.event);
                    }
                },
                else => {
                    // Forward all other MIDI events directly
                    _ = c.lv2_atom_sequence_append_event(self.out_port, out_capacity, ev);
                },
            }
        }
    }
}

export fn cleanup(instance: c.LV2_Handle) void {
    std.log.info("[cleanup] begin", .{});
    if (instance == null) return;
    const self = @ptrCast(*Fifths, @alignCast(@alignOf(*Fifths), instance));

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
    .activate = null,
    .run = run,
    .deactivate = null,
    .cleanup = cleanup,
    .extension_data = extension_data,
};

export fn lv2_descriptor(index: u32) ?*const c.LV2_Descriptor {
    return if (index == 0) &descriptor else null;
}
