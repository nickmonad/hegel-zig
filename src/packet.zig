const std = @import("std");
const Io = std.Io;
const CRC32 = std.hash.crc.Crc32;
const cbor = @import("cbor");

const PACKET_HEADER_SIZE: usize = 20;
const PACKET_MAGIC: u32 = 0x4845474C; // "HEGL" in big-endian
const PACKET_REPLY_BIT: u32 = 1 << 31;
const PACKET_TERMINATOR: u8 = 0x0A;

const Packet = @This();

stream_id: u32,
/// Message ID can be null while constructing a Packet!
/// This isn't ideal, but it allows us to defer setting the message ID at the client layer,
/// where the generation and sequence can be controlled in one place.
/// It is assumed to be set in .write()
message_id: ?u32 = null,
is_reply: bool = false,
payload: []const u8,

pub const Meta = struct {
    stream_id: u32,
    message_id: ?u32 = null,
    is_reply: bool = false,
};

pub fn encode(arena: std.mem.Allocator, meta: Meta, value: anytype) !Packet {
    var w: Io.Writer.Allocating = .init(arena);
    try cbor.writeValue(&w.writer, value);

    return .{
        .stream_id = meta.stream_id,
        .message_id = meta.message_id,
        .is_reply = meta.is_reply,
        .payload = w.written(),
    };
}

pub fn write(self: Packet, w: *Io.Writer) !void {
    // NOTE: message_id must be set (non-null).
    const message_id = id: {
        if (self.is_reply) {
            break :id (self.message_id.? | PACKET_REPLY_BIT);
        } else {
            break :id self.message_id.?;
        }
    };

    var header: [PACKET_HEADER_SIZE]u8 = undefined;
    @memcpy(header[0..4], std.mem.asBytes(&std.mem.nativeToBig(u32, PACKET_MAGIC)));
    @memset(header[4..8], 0); // checksum temporarily set to 0, prior to calculation
    @memcpy(header[8..12], std.mem.asBytes(&std.mem.nativeToBig(u32, self.stream_id)));
    @memcpy(header[12..16], std.mem.asBytes(&std.mem.nativeToBig(u32, message_id)));
    @memcpy(header[16..20], std.mem.asBytes(&std.mem.nativeToBig(u32, @intCast(self.payload.len))));

    // calculate checksum
    var hasher: CRC32 = .init();
    hasher.update(&header);
    hasher.update(self.payload);
    const checksum = hasher.final();

    // set checksum
    @memcpy(header[4..8], std.mem.asBytes(&std.mem.nativeToBig(u32, checksum)));

    // write out encoded packet
    _ = try w.write(&header);
    _ = try w.write(self.payload);
    _ = try w.write(&.{PACKET_TERMINATOR});

    try w.flush();
}

/// Decode the Packet from the given reader.
/// Allocator is used to copy payload, to decouple from Reader lifetime.
/// Caller owns copied payload on returned Packet.
pub fn read(r: *Io.Reader, gpa: std.mem.Allocator) !Packet {
    var header: [PACKET_HEADER_SIZE]u8 = @splat(0);
    var n = try r.readSliceShort(&header);
    if (n < header.len) {
        return error.NotEnoughData;
    }

    // decode header fields
    const raw_magic = std.mem.readInt(u32, header[0..4], .big);
    const raw_checksum = std.mem.readInt(u32, header[4..8], .big);
    const raw_stream_id = std.mem.readInt(u32, header[8..12], .big);
    const raw_message_id = std.mem.readInt(u32, header[12..16], .big);
    const raw_payload_len = std.mem.readInt(u32, header[16..20], .big);

    if (raw_magic != PACKET_MAGIC) {
        return error.InvalidPacket;
    }

    // read payload
    const payload = try gpa.alloc(u8, raw_payload_len);
    n = try r.readSliceShort(payload);
    if (n < payload.len) {
        return error.NotEnoughData;
    }

    // read terminator
    const term = try r.takeByte();
    if (term != PACKET_TERMINATOR) {
        return error.InvalidPacket;
    }

    // copy header, setting checksum to 0 for re-calculation
    var header_copy = header;
    @memset(header_copy[4..8], 0);

    // re-calculate checksum
    var hasher: CRC32 = .init();
    hasher.update(&header_copy);
    hasher.update(payload);

    const checksum = hasher.final();
    if (raw_checksum != checksum) {
        return error.InvalidPacket;
    }

    // coerce message_id
    const is_reply = raw_message_id & PACKET_REPLY_BIT != 0;
    const message_id: u32 = raw_message_id & ~PACKET_REPLY_BIT;

    return .{
        .stream_id = raw_stream_id,
        .message_id = message_id,
        .is_reply = is_reply,
        .payload = payload,
    };
}

pub fn debug(self: Packet, name: []const u8, gpa: std.mem.Allocator) void {
    const is_cbor = cbor.match(self.payload, cbor.any) catch false;

    std.debug.print("Packet ({s}) {{\n", .{name});
    std.debug.print("  stream_id = {d}\n", .{self.stream_id});
    std.debug.print("  message_id = {any}\n", .{self.message_id});
    std.debug.print("  is_reply = {any}\n", .{self.is_reply});
    std.debug.print("  payload = {s}\n", .{
        if (is_cbor)
            cbor.toJsonAlloc(gpa, self.payload) catch unreachable
        else
            self.payload,
    });
    std.debug.print("}}\n", .{});
}

test "endian sanity" {
    // assuming we're running on a little-endian machine
    const one_little = [_]u8{ 0x01, 0x00, 0x00, 0x00 };
    try std.testing.expectEqualSlices(u8, &one_little, std.mem.asBytes(&@as(u32, 1)));

    const one_big = [_]u8{ 0x00, 0x00, 0x00, 0x01 };
    try std.testing.expectEqualSlices(u8, &one_big, std.mem.asBytes(&std.mem.nativeToBig(u32, 1)));
}

test "packet round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const packets = [_]Packet{
        .{
            .stream_id = 0,
            .message_id = 0,
            .is_reply = false,
            .payload = "hegel_zig",
        },
        .{
            .stream_id = 1,
            .message_id = 42,
            .is_reply = true,
            .payload = "hegel_what_now?",
        },
    };

    for (packets) |p| {
        var w: Io.Writer.Allocating = .init(alloc);
        try p.write(&w.writer);

        var r: Io.Reader = .fixed(w.written());
        const decoded: Packet = try .read(&r, alloc);

        try std.testing.expectEqualDeep(p, decoded);
    }
}

// Sanity checking some results from cbor libray v1.2.0
// See https://github.com/neurocyte/cbor/issues/5
// If these start failing after a cbor upgrade, we need to re-evaluate
// our core extraction logic in Client.receive()

const NumberResult = struct {
    result: u64,
};

test "cbor extract number from boolean, match returns false, no error" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const json =
        \\{"result": true}
    ;

    const cbor_data = try cbor.fromJsonAlloc(alloc, json);

    var result: NumberResult = undefined;
    const ok = try cbor.match(cbor_data, cbor.extractAlloc(&result, alloc));

    try std.testing.expect(!ok);
}

const ListResult = struct {
    result: []const u64,
};

test "cbor extract list from boolean, match has error" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const json =
        \\{"result": true}
    ;

    const cbor_data = try cbor.fromJsonAlloc(alloc, json);

    var result: ListResult = undefined;
    try std.testing.expectError(
        error.InvalidArrayType,
        cbor.match(cbor_data, cbor.extractAlloc(&result, alloc)),
    );
}
