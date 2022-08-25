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

    fn log(self: @This()) void {
        std.log.warn("atom_Path URID is {}", .{self.atom_Path});
        std.log.warn("atom_Resource URID is {}", .{self.atom_Resource});
        std.log.warn("atom_Sequence URID is {}", .{self.atom_Sequence});
        std.log.warn("atom_URID URID is {}", .{self.atom_URID});
        std.log.warn("atom_eventTransfer URID is {}", .{self.atom_eventTransfer});
        std.log.warn("midi_Event URID is {}", .{self.midi_Event});
        std.log.warn("patch_Set URID is {}", .{self.patch_Set});
        std.log.warn("patch_property URID is {}", .{self.patch_property});
        std.log.warn("patch_value URID is {}", .{self.patch_value});
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
    self.uris.log();
    // self.uris.midi_MidiEvent = self.map.map.?(self.map.handle, c.LV2_MIDI__MidiEvent);

    std.log.info("[instantiate] seq {} atom {} body {} u64 {}", .{ @alignOf(c.LV2_Atom_Sequence), @alignOf(c.LV2_Atom), @alignOf(c.LV2_Atom_Sequence_Body), @alignOf(u64) });

    std.log.info("[instantiate] complete", .{});
    return @ptrCast(c.LV2_Handle, self);
}

export fn connect_port(instance: c.LV2_Handle, port: u32, data: ?*anyopaque) void {
    if (data == null) return;
    const self = @ptrCast(*Fifths, @alignCast(@alignOf(*Fifths), instance));

    switch (@intToEnum(PortIndex, port)) {
        .Input => {
            self.in_port = @ptrCast(*const c.LV2_Atom_Sequence, @alignCast(@alignOf(c.LV2_Atom_Sequence), data));
            // std.log.info("[connect] {}, {}", .{ @ptrToInt(self.in_port), @ptrToInt(self.in_port) % @alignOf(u64) });
            // std.debug.assert(@ptrToInt(self.in_port) % @alignOf(u64) == 0);
        },
        .Output => self.out_port = @ptrCast(*c.LV2_Atom_Sequence, @alignCast(@alignOf(c.LV2_Atom_Sequence), data)),
    }
}

const AtomIter = struct {
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
        // size = try this.reader.readInt(u32, .Little);
        // t = try this.reader.readInt(u32, .Little);
        // _ = try this.reader.readInt(u32, .Little); // time type
        // _ = try this.reader.readInt(u32, .Little); // padding
        return this;
    }

    const Event = struct {
        ev: c.LV2_Atom_Event,
        msg: []const u8,
    };

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
        std.log.info("{}: {} {}", .{ frame, asize, atype });
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

fn dump_sequence(sequence: *const c.LV2_Atom_Sequence) !void {
    if (sequence.atom.size <= 8) {
        return;
    }
    // const bytes = @ptrCast([*]const u8, sequence)[0 .. @sizeOf(c.LV2_Atom_Sequence) + sequence.atom.size];
    // var a: usize = 0;
    // var i: usize = 0;
    // while (i < sequence.atom.size + @sizeOf(c.LV2_Atom_Sequence)) : (i += 1) {
    //     if (i - a == 8) {
    //         std.log.info("{} {} {} {} {} {} {} {}", .{ bytes[a], bytes[a + 1], bytes[a + 2], bytes[a + 3], bytes[a + 4], bytes[a + 5], bytes[a + 6], bytes[a + 7] });
    //         a = i;
    //     }
    //     if (i == @sizeOf(c.LV2_Atom_Sequence)) std.log.info("", .{});
    //     if (i > @sizeOf(c.LV2_Atom_Sequence) and i % @sizeOf(u64) == 0) std.log.info("", .{});
    // }
    var iter = AtomIter.init(sequence);
    while (iter.next()) |ev| {
        std.log.info("{} {} {} {any}", .{
            ev.ev.time.frames,
            ev.ev.body.type,
            ev.ev.body.size,
            ev.msg,
        });
    }
}

// Struct for 3 byte MIDI event, used for writing notes
const MIDINoteEvent = extern struct {
    event: c.LV2_Atom_Event,
    msg: [3]u8,
};

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

fn atomEventAppend(sequence: *c.LV2_Atom_Sequence, writer: anytype, event: *const c.LV2_Atom_Event, msg: []const u8) !void {
    const total_size = @sizeOf(c.LV2_Atom_Event) + event.body.size;

    try writeAtom(writer, event);
    try writeBytes(writer, msg);

    sequence.atom.size += total_size + (8 - (total_size % 8));
    std.log.info("[run] new size {}", .{sequence.atom.size});
}

export fn run(instance: c.LV2_Handle, sample_count: u32) void {
    // std.log.info("[run] start", .{});
    _ = sample_count;
    if (instance == null) return;
    const self = @ptrCast(*Fifths, @alignCast(@alignOf(*Fifths), instance));

    // Initially self.out_port contains a Chunk with size set to capacity

    // Get the capacity
    const out_capacity = self.out_port.atom.size;
    // std.log.info("out_capacity={}", .{out_capacity});
    var out = std.io.FixedBufferStream([]u8){.buffer = @ptrCast([*]u8, self.out_port)[@sizeOf(c.LV2_Atom_Sequence)..out_capacity], .pos = 0};
    var writer = out.writer();

    // Write an empty Sequence header to the output
    c.lv2_atom_sequence_clear(self.out_port);
    self.out_port.atom.type = self.in_port.atom.type;

    std.debug.assert(self.in_port.atom.size % @alignOf(u64) == 0);
    std.debug.assert(self.out_port.atom.size % @alignOf(u64) == 0);

    dump_sequence(self.in_port) catch |e| switch (e) {
        error.EndOfStream => {},
    };

    // std.log.info("[run] after dump", .{});

    // Read incoming events
    var iter = AtomIter.init(self.in_port);
    while (iter.next()) |ev| {
        if (ev.ev.body.type == self.uris.midi_Event) {
            std.log.info("[run] midi event", .{});
            const msg_type = if (ev.msg.len > 1) ev.msg[0] else continue;
            std.log.info("[run] message type {}", .{msg_type});
            switch (c.lv2_midi_message_type(&msg_type)) {
                c.LV2_MIDI_MSG_NOTE_ON,
                c.LV2_MIDI_MSG_NOTE_OFF,
                => {
                    std.log.info("[run] adding fifth...", .{});
                    // Forward note to output
                    // writeAtom(writer, &ev.ev) catch @panic("eh");
                    // writeBytes(writer, ev.msg) catch @panic("eh");
                    atomEventAppend(self.out_port, writer, &ev.ev, ev.msg) catch @panic("eh");

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

                        // writeAtom(writer, &fifth.event) catch @panic("eh");
                        // writeBytes(writer, ev.msg) catch @panic("eh");
                        atomEventAppend(self.out_port, writer, &fifth.event, &fifth.msg) catch @panic("eh");
                    }
                },
                else => {
                    std.log.info("[run] forwarding...", .{});
                    // writeAtom(writer, &ev.ev) catch @panic("eh");
                    // writeBytes(writer, ev.msg) catch @panic("eh");
                    atomEventAppend(self.out_port, writer, &ev.ev, ev.msg) catch @panic("eh");
                    // Forward all other MIDI events directly
                    // _ = c.lv2_atom_sequence_append_event(self.out_port, out_capacity, &ev.ev);
                },
            }
        } else {
            std.log.info("[run] {} frames: {} is not a note", .{ ev.ev.time.frames, ev.ev.body.type });
        }
    }

    // self.out_port.atom.size = @intCast(u32, out.getPos() catch {});

    dump_sequence(self.out_port) catch |e| switch (e) {
        error.EndOfStream => {},
    };

    std.log.info("[run] end", .{});
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
