const std = @import("std");
const c = @import("c.zig");

pub const FeatureQuery = struct {
    uri: [*:0]const u8,
    required: bool,
};


pub fn queryFeatures(alloc: std.mem.Allocator, features: [*]const ?[*]const c.LV2_Feature, wanted: []const FeatureQuery) ![]?*anyopaque {
    var found = try alloc.alloc(?*anyopaque, wanted.len);
    for (wanted) |want, i| {
        found[i] = c.lv2_features_data(features, want.uri);
    }

    return found;
}

pub const Event = struct {
    ev: c.LV2_Atom_Event,
    msg: []const u8,
};

pub const AtomEventReader = struct {
    sequence: *const c.LV2_Atom_Sequence,
    buffer: []const u8,
    fixed_buffer_stream: FBS,
    reader: ?FBS.Reader,

    const FBS = std.io.FixedBufferStream([]const u8);

    pub fn init(sequence: *const c.LV2_Atom_Sequence) @This() {
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

    pub fn next(this: *@This()) ?Event {
        return this._next() catch |e| switch (e) {
            error.EndOfStream => return null,
        };
    }
};

pub const AtomEventWriter = struct {
    sequence: *c.LV2_Atom_Sequence,
    buffer: []u8,
    fixed_buffer_stream: FBS,
    writer: ?FBS.Writer,

    const FBS = std.io.FixedBufferStream([]u8);

    pub fn init(sequence: *c.LV2_Atom_Sequence) @This() {
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

    pub fn append(this: *@This(), event: *const c.LV2_Atom_Event, msg: []const u8) !void {
        var writer = this.writer orelse this.fixed_buffer_stream.writer();
        const total_size = @sizeOf(c.LV2_Atom_Event) + event.body.size;

        try writeAtom(writer, event);
        try writeBytes(writer, msg);

        this.sequence.atom.size += total_size + (8 - (total_size % 8));
    }
};
