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

const Event = struct {
    ev: c.LV2_Atom_Event,
    msg: []const u8,
};

const AtomEventReader = struct {
    sequence: *const c.LV2_Atom_Sequence,
    buffer: []const u8,
    fixed_buffer_stream: FBS,
    reader: ?FBS.Reader,

    const FBS = std.io.FixedBufferStream([]const u8);

    fn init(sequence: *const c.LV2_Atom_Sequence) @This() {
        const bytes = @alignCast(1, @ptrCast([*]const u8, sequence)[@sizeOf(c.LV2_Atom_Sequence) .. @sizeOf(c.LV2_Atom_Sequence) + sequence.atom.size]);
        var this = @This(){
            .sequence = sequence,
            .buffer = bytes,
            .fixed_buffer_stream = std.io.FixedBufferStream([]const u8){ .buffer = bytes, .pos = 0 },
            .reader = null,
        };
        return this;
    }

    fn _next(this: *@This()) !Event {
        var reader = this.reader orelse reader: {
            this.reader = this.fixed_buffer_stream.reader();
            break :reader this.reader.?;
        };

        var frame = try reader.readInt(i64, .Little);
        var asize = try reader.readInt(u32, .Little);
        var atype = try reader.readInt(u32, .Little);
        var byte_pos = try this.fixed_buffer_stream.getPos();
        try reader.skipBytes((@divTrunc(asize, 8) + 1) * 8, .{});
        var buffer = if (asize > 0) this.buffer[byte_pos .. byte_pos + asize] else &[_]u8{};

        return Event{
            .ev = .{ .time = .{ .frames = frame }, .body = .{
                .size = asize,
                .type = atype,
            } },
            .msg = buffer,
        };
    }

    fn next(this: *@This()) ?Event {
        return this._next() catch |e| switch (e) {
            error.EndOfStream => return null,
        };
    }
};

const AtomEventWriter = struct {
    sequence: *c.LV2_Atom_Sequence,
    buffer: []u8,
    fixed_buffer_stream: FBS,
    writer: ?FBS.Writer,

    const FBS = std.io.FixedBufferStream([]u8);

    fn init(sequence: *c.LV2_Atom_Sequence) @This() {
        const bytes = @alignCast(1, @ptrCast([*]u8, sequence)[@sizeOf(c.LV2_Atom_Sequence) .. @sizeOf(c.LV2_Atom_Sequence) + sequence.atom.size]);
        var this = @This(){
            .sequence = sequence,
            .buffer = bytes,
            .fixed_buffer_stream = std.io.FixedBufferStream([]u8){ .buffer = bytes, .pos = 0 },
            .writer = null,
        };
        return this;
    }

    fn writeAtom(writer: anytype, event: *const c.LV2_Atom_Event) !void {
        try writer.writeInt(i64, event.time.frames, .Little);
        try writer.writeInt(u32, event.body.size, .Little);
        try writer.writeInt(u32, event.body.type, .Little);
    }

    fn writeBytes (writer: anytype, msg: []const u8) !void {
        const aligned = ((msg.len / 8) + 1) * 8;
        var i: usize = 0;
        for (msg) |byte| {
            i += 1;
            try writer.writeByte(byte);
        }
        while (i < aligned) : (i += 1) {
            try writer.writeByte(0);
        }
    }

    fn append(this: *@This(), event: *const c.LV2_Atom_Event, msg: []const u8) !void {
        var writer = this.writer orelse this.fixed_buffer_stream.writer();
        const total_size = @sizeOf(c.LV2_Atom_Event) + event.body.size;

        try writeAtom(writer, event);
        try writeBytes(writer, msg);

        this.sequence.atom.size += total_size + (8 - (total_size % 8));
    }
};

// Struct for 3 byte MIDI event, used for writing notes
const MIDINoteEvent = extern struct {
    event: c.LV2_Atom_Event,
    msg: [3]u8,
};

export fn run(instance: c.LV2_Handle, sample_count: u32) void {
    _ = sample_count;
    if (instance == null) return;
    const self = @ptrCast(*Fifths, @alignCast(@alignOf(*Fifths), instance));

    // Initially self.out_port contains a Chunk with size set to capacity

    // Get the capacity
    var writer = AtomEventWriter.init(self.out_port);

    // Write an empty Sequence header to the output
    c.lv2_atom_sequence_clear(self.out_port);
    self.out_port.atom.type = self.in_port.atom.type;

    // Read incoming events
    var iter = AtomEventReader.init(self.in_port);
    while (iter.next()) |ev| {
        if (ev.ev.body.type == self.uris.midi_Event) {
            const msg_type = if (ev.msg.len > 1) ev.msg[0] else continue;
            switch (c.lv2_midi_message_type(&msg_type)) {
                c.LV2_MIDI_MSG_NOTE_ON,
                c.LV2_MIDI_MSG_NOTE_OFF,
                => {
                    writer.append(&ev.ev, ev.msg) catch @panic("eh");

                    if (ev.msg[1] <= 127 - 7) {
                        // Make a note one 5th (7 semitones) higher than input
                        // We could simply copy the value of ev here...
                        var fifth = MIDINoteEvent{
                            .event = ev.ev,
                            .msg = .{
                                ev.msg[0], // Same status
                                ev.msg[1] + 7, // Pitch up 7 semitones
                                ev.msg[2], // Same velocity
                            }
                        };

                        writer.append(&fifth.event, &fifth.msg) catch @panic("eh");
                    }
                },
                else => {
                    writer.append(&ev.ev, ev.msg) catch @panic("eh");
                },
            }
        }
    }
}

export fn cleanup(instance: c.LV2_Handle) void {
    if (instance == null) return;
    const self = @ptrCast(*Fifths, @alignCast(@alignOf(*Fifths), instance));

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
