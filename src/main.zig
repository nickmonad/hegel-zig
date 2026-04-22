const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const cbor = @import("cbor");

const CRC32 = std.hash.crc.Crc32;
const hegel = @import("hegel");

// "HEGL" in big-endian
const PACKET_MAGIC: u32 = 0x4845474C;
const PACKET_HEADER_SIZE: usize = 20;
const PACKET_TERMINATOR: u8 = 0x0A;
const PACKET_REPLY_BIT: u32 = 1 << 31;

const STREAM_ID_CONTROL: u31 = 0;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.arena.allocator();

    var client: *Client = try alloc.create(Client);
    try client.init(io, alloc);

    assert(client.connection.initialized);
    try client.send(.{ .stream_id = STREAM_ID_CONTROL, .message_id = 0, .payload = "hegel_handshake_start" });
    client.deinit();
}

const Session = struct {
    // TODO: This implementation is not thread-safe!
    // We're currently assuming single-threaded test execution in Zig.
    // This may change in the future, or we'll want to use this in a more generic way,
    // so we'll need a thread-safe version.
    // This includes the Client, as well! We'll need a thread-safe way to increment
    // the "next" stream ID as we start test runs.
    var io: ?Io = null;
    var arena: ?std.heap.ArenaAllocator = null;
    var client: ?*Client = null;

    fn init(io_: Io, gpa: std.mem.Allocator) !void {
        if (Session.io == null) {
            Session.io = io_;
        }

        if (Session.arena == null) {
            Session.arena = .init(gpa);
        }

        if (Session.client == null) {
            var c = Session.arena.?.allocator().create(Client) catch unreachable;
            try c.init(Session.io.?, Session.arena.?.allocator());

            Session.client = c;
        }
    }

    fn deinit() void {
        Session.client.?.deinit();
        Session.arena.?.deinit();
    }
};

const TestOptions = struct {
    skip: bool = false,
    test_cases: u32 = 100,
};

/// Runs a Hegel test case, using std.testing.*
/// values as the backing Io and Allocator instances.
/// This can only be used in the context of a Zig test.
///
/// TODO: Create a TestCustom (better name?) that will accept
/// arbitrary Io and Allocator instances. That will be useful
/// if we want to create some kind of CLI to debug/inspect/play-around-with
/// Hegel outside of a Zig test suite.
fn Test(opts: TestOptions, comptime f: fn () void) !void {
    if (opts.skip) return;

    try Session.init(
        std.testing.io,
        std.testing.allocator,
    );

    // Create a test-level allocator.
    // This will keep allocations for duration of a _single_ test case.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try Session.client.?.runTest(alloc, .{ .test_cases = opts.test_cases });

    f();

    Session.deinit();
}

const Client = struct {
    io: std.Io,
    server: std.process.Child,
    connection: Connection = undefined,
    next_stream_id: u32 = 1,

    const Self = @This();

    const RunTestOptions = struct {
        test_cases: u32,
    };

    fn init(client: *Self, io: Io, arena: std.mem.Allocator) !void {
        // start Hegel server
        // const cmd = env.getPosix("HEGEL_SERVER_COMMAND") orelse @panic("env var not set!");
        // var env_cloned: std.process.Environ.Map = try .clone(env, gpa);
        // try env_cloned.put("PYTHONUNBUFFERED", "1"); // force server to output immediately

        const server: std.process.Child = try std.process.spawn(io, .{
            .argv = &.{ "/nix/store/b2yqacm5h31irdpsmiizdhx0ybi19v8a-hegel-core-0.4.1/bin/hegel", "--stdio" },
            .stdin = .pipe,
            .stdout = .pipe,
        });

        std.debug.print("hegel server pid = {d}\n", .{server.id.?});

        const buf_w = try arena.alloc(u8, 4096);
        const buf_r = try arena.alloc(u8, 4096);

        client.* = .{ .io = io, .server = server };

        var w: Io.File.Writer = client.server.stdin.?.writer(io, buf_w);
        var r: Io.File.Reader = client.server.stdout.?.reader(io, buf_r);

        client.connection = try .init(&w.interface, &r.interface, arena);
    }

    fn deinit(self: *Self) void {
        self.server.kill(self.io);
    }

    fn runTest(self: *Self, arena: std.mem.Allocator, opts: RunTestOptions) !void {
        var buf: [1024]u8 = undefined;

        const payload = try cbor.fmtBuf(&buf, .{
            .command = "run_test",
            .stream_id = self.next_stream_id,
            .test_cases = opts.test_cases,
        });

        // keep the next client-generated stream ID odd
        self.next_stream_id += 2;

        std.debug.print("payload = {s}\n", .{payload});
        const request: Packet = .{
            .stream_id = STREAM_ID_CONTROL,
            .message_id = 0,
            .payload = payload,
        };

        // TODO: probably need some timeouts around these
        // revisit when there's some real concurrency
        try self.send(request);
        const reply: Packet = try self.wait(arena);

        assert(reply.stream_id == request.stream_id);
        assert(reply.is_reply);
        assert(try cbor.match(reply.payload, true));
    }

    fn send(self: *Self, p: Packet) !void {
        return p.write(self.connection.writer);
    }

    /// Wait for a response Packet from the server.
    /// Caller owns Packet payload, using provided allocator.
    fn wait(self: *Self, alloc: std.mem.Allocator) !Packet {
        return try .read(self.connection.reader, alloc);
    }
};

const Connection = struct {
    writer: *Io.Writer,
    reader: *Io.Reader,
    initialized: bool = false,

    const Self = @This();

    fn init(w: *Io.Writer, r: *Io.Reader, arena: std.mem.Allocator) !Self {
        // initialize with a (synchonrous) handshake to the server
        const handshake: Packet = .{
            .stream_id = STREAM_ID_CONTROL,
            .message_id = 0,
            .payload = "hegel_handshake_start",
        };

        try handshake.write(w);
        const reply: Packet = try .read(r, arena);
        defer arena.free(reply.payload);

        assert(reply.stream_id == handshake.stream_id);
        assert(reply.message_id == handshake.message_id);
        assert(reply.is_reply);

        return .{ .writer = w, .reader = r, .initialized = true };
    }
};

const Packet = struct {
    stream_id: u32 = undefined,
    message_id: u31 = undefined,
    is_reply: bool = false,
    payload: []const u8 = undefined,

    const Self = @This();

    fn write(self: Self, w: *Io.Writer) !void {
        const message_id = id: {
            if (self.is_reply) {
                break :id @as(u32, self.message_id) | PACKET_REPLY_BIT;
            } else {
                break :id @as(u32, self.message_id);
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

    // Decode the Packet from the given reader.
    // Allocator is used to copy payload, to decouple from Reader lifetime.
    // Caller owns copied payload on returned Packet.
    fn read(r: *Io.Reader, gpa: std.mem.Allocator) !Self {
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
        const message_id: u31 = @truncate(raw_message_id & ~PACKET_REPLY_BIT);

        return .{
            .stream_id = raw_stream_id,
            .message_id = message_id,
            .is_reply = is_reply,
            .payload = payload,
        };
    }
};

fn hexdump(data: []const u8) void {
    const print = std.debug.print;

    var ascii: [16]u8 = @splat('.');
    var last: usize = 0;
    for (data, 0..) |byte, i| {
        if (i > 0 and i % 16 == 0) {
            // at line width
            // print ascii output and end with \n
            print("|", .{});
            for (ascii) |char| {
                if (char >= 32 and char <= 126) {
                    print("{c}", .{char});
                } else {
                    print(".", .{});
                }
            }

            print("|\n", .{});
        }

        print("{x:0>2} ", .{byte});
        ascii[i % 16] = byte;

        last = i;
    }

    const remaining = 16 - (last % 16) - 1;
    for (0..remaining) |_| {
        print("{0s}{0s}{0s}", .{" "});
    }

    print("|", .{});
    for (0..((last % 16) + 1)) |i| {
        if (ascii[i] >= 32 and ascii[i] <= 126) {
            print("{c}", .{ascii[i]});
        } else {
            print(".", .{});
        }
    }

    print("|\n", .{});
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

test "hegel" {
    try Test(.{}, struct {
        fn f() void {
            return;
        }
    }.f);
}
