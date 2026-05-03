//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const CRC32 = std.hash.crc.Crc32;
const cbor = @import("cbor");

const PACKET_HEADER_SIZE: usize = 20;
const PACKET_MAGIC: u32 = 0x4845474C; // "HEGL" in big-endian
const PACKET_REPLY_BIT: u32 = 1 << 31;
const PACKET_TERMINATOR: u8 = 0x0A;
const STREAM_CONTROL: u32 = 0;

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
    var initialized: bool = false;

    fn init(io_: Io, gpa: std.mem.Allocator) !void {
        if (Session.initialized) return;

        Session.io = io_;
        Session.arena = .init(gpa);

        var c = Session.arena.?.allocator().create(Client) catch unreachable;
        try c.init(Session.io.?, Session.arena.?.allocator());

        Session.client = c;
        Session.initialized = true;
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
fn Test(opts: TestOptions, comptime func: fn (TestCase) anyerror!void) !void {
    if (opts.skip) return;

    try Session.init(
        std.testing.io,
        std.testing.allocator,
    );

    var client = Session.client.?;
    const run = try client.testRun(.{ .test_cases = opts.test_cases });

    while (true) {
        switch (try run.event()) {
            .case => |tc| {
                // TODO: tc.ack() (see note about deadlock in hegel-rust??)
                // need to reply to proper message_id
                // TODO: handle error and update status
                func(tc) catch unreachable;
                try tc.complete(.{ .status = .valid });
            },
            .done => |done| {
                // TODO: do something with test results?
                _ = done;
                break;
            },
        }
    }

    Session.deinit();
}

const TestRun = struct {
    client: *Client,

    stream_id: u32,
    options: Options,

    const Options = struct {
        test_cases: u32,
    };

    const Reply = struct {
        result: bool,
    };

    const Event = union(enum) {
        case: TestCase,
        done: TestDone,

        fn read(
            packet: Packet,
            arena: std.mem.Allocator,
            client: *Client,
        ) !?Event {
            var test_case: TestCase.Event = undefined;
            if (try cbor.match(packet.payload, cbor.extractAlloc(&test_case, arena))) {
                // Prepare and send test_case_reply!
                // NOTE(nickmonad): hegel-rust mentions this as critical step to "prevent deadlock".
                // It's not clear to me if this is a deadlock in hegel-rust, or the hegel-core server.
                const test_case_reply: Packet = try .encode(
                    arena,
                    .{
                        .stream_id = packet.stream_id,
                        .message_id = packet.message_id,
                        .is_reply = true,
                    },
                    .{
                        .result = null,
                    },
                );

                try client.send(test_case_reply);

                return .{
                    .case = .{
                        .client = client,
                        .stream_id = test_case.stream_id,
                    },
                };
            }

            var test_done: TestDone.Event = undefined;
            if (try cbor.match(packet.payload, cbor.extractAlloc(&test_done, arena))) {
                return .{
                    .done = test_done.results,
                };
            }

            return null;
        }
    };

    pub fn event(self: TestRun) !Event {
        return self.client.receive(self.stream_id, Event, Event.read);
    }
};

const TestCase = struct {
    client: *Client,
    stream_id: u32,

    const Event = struct {
        event: []const u8,
        stream_id: u32,
        is_final: bool,
    };

    const Status = enum {
        valid,
        invalid,
        interesting,
    };

    const Result = struct {
        status: Status,
        origin: ?std.builtin.SourceLocation = null,
    };

    fn draw(self: TestCase, comptime G: type) !@FieldType(G, "generated") {
        const generator: G = .{};
        const generate: Packet = try .encode(
            self.client.arena,
            .{ .stream_id = self.stream_id },
            .{
                .command = "generate",
                .schema = generator.schema(),
            },
        );

        try self.client.send(generate);
        return self.client.receive(self.stream_id, @FieldType(G, "generated"), G.read);
    }

    fn complete(self: TestCase, result: Result) !void {
        const mark_complete: Packet = try .encode(
            self.client.arena,
            .{ .stream_id = self.stream_id },
            .{
                .command = "mark_complete",
                .status = switch (result.status) {
                    .valid => "VALID",
                    .invalid => "INVALID",
                    .interesting => "INTERESTING",
                },
                .origin = null,
                // TODO: .origin (when interesting)
            },
        );

        // TODO: do we care about "mark_complete_reply"?
        return self.client.send(mark_complete);
    }
};

fn IntOptions(comptime T: type) type {
    return struct {
        min: ?T = null,
        max: ?T = null,
    };
}

fn Int(comptime T: type, opts: IntOptions(T)) type {
    return struct {
        const Self = @This();

        generated: T = undefined,
        opts: IntOptions(T) = opts,

        const Schema = struct {
            type: []const u8 = "integer",
            min_value: ?T,
            max_value: ?T,
        };

        const Result = struct {
            result: T,
        };

        fn schema(self: Self) Schema {
            return .{
                .min_value = self.opts.min,
                .max_value = self.opts.max,
            };
        }

        fn read(packet: Packet, alloc: std.mem.Allocator, _: *Client) !?T {
            var result: Result = undefined;
            if (try cbor.match(packet.payload, cbor.extractAlloc(&result, alloc))) {
                return result.result;
            }

            return null;
        }
    };
}

const TestDone = struct {
    passed: bool,
    test_cases: u32,
    valid_test_cases: u32,
    invalid_test_cases: u32,
    interesting_test_cases: u32,
    seed: []const u8,
    failure_blobs: []const []const u8,

    const Event = struct {
        event: []const u8,
        results: TestDone,
    };
};

const TestCaseReply = struct {
    // This should always be null, and therefore, never set explicity by the client.
    result: ?bool = null,
};

pub const Client = struct {
    io: std.Io,
    arena: std.mem.Allocator,

    server: std.process.Child,
    connection: Connection = undefined,
    next_stream_id: u32 = 1,
    streams: std.AutoHashMap(u32, Stream),

    const Self = @This();

    const Stream = struct {
        id: u32,
        next_message_id: u31 = 1,
        queue: std.DoublyLinkedList = .{},
    };

    const QueueItem = struct {
        node: std.DoublyLinkedList.Node,
        packet: Packet,
    };

    /// Initialize Hegel client. The client spawns the server and opens a connection
    /// over stdin/stdout. The provided arena allocator is for the entire test session,
    /// so the client is not responsible for freeing any memory allocated in it.
    pub fn init(self: *Self, io: Io, arena: std.mem.Allocator) !void {
        var env: std.process.Environ.Map = .init(arena);
        try env.put("PYTHONUNBUFFERED", "1");

        const server: std.process.Child = try std.process.spawn(io, .{
            .argv = &.{
                "/nix/store/n4j4s1lpa5g3xvy8107r2vb5g2yvm550-hegel-core-0.4.7/bin/hegel",
                "--stdio",
                "--verbosity",
                "debug",
            },
            .environ_map = &env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });

        // std.debug.print("hegel server pid = {d}\n", .{server.id.?});

        const buf_w = try arena.alloc(u8, 4096);
        const buf_r = try arena.alloc(u8, 4096);

        self.* = .{
            .io = io,
            .arena = arena,
            .server = server,
            .streams = .init(arena),
        };

        const w: Io.File.Writer = self.server.stdin.?.writer(io, buf_w);
        const r: Io.File.Reader = self.server.stdout.?.reader(io, buf_r);

        self.connection = try .init(w, r, arena);
    }

    pub fn deinit(self: *Self) void {
        self.server.kill(self.io);
    }

    fn send(self: *Self, p: Packet) !void {
        const entry = try self.streams.getOrPutValue(p.stream_id, .{ .id = p.stream_id });
        var stream: *Stream = entry.value_ptr;

        const message_id = stream.next_message_id;
        stream.next_message_id += 1;

        var copied: Packet = p;
        copied.message_id = message_id;

        return copied.write(&self.connection.writer.interface);
    }

    fn reply(self: *Self, p: Packet) !void {
        assert(p.message_id.? >= 0);
        return p.write(&self.connection.writer.interface);
    }

    fn receive(
        self: *Self,
        on_stream_id: u32,
        comptime T: type,
        comptime read: fn (Packet, std.mem.Allocator, *Self) anyerror!?T,
    ) !T {
        // NOTE: We depend heavily on liveness here! The server must be
        // responding with packets we expect, otherwise we'll get stuck waiting here.
        // Some kind of timeout mechanism will eventually be needed.

        // TODO: check if we already have a packet matching T on the queue
        _ = on_stream_id;

        while (true) {
            const packet: Packet = try .read(
                &self.connection.reader.interface,
                self.arena,
            );

            if (try read(packet, self.arena, self)) |value| {
                return value;
            }

            // TODO: queue unexpected and loop again
        }
    }

    pub fn testRun(self: *Self, opts: TestRun.Options) !TestRun {
        const stream_test = s: {
            const id = self.next_stream_id;
            // keep the next client-generated stream ID odd
            self.next_stream_id += 2;
            break :s id;
        };

        const run_test: Packet = try .encode(
            self.arena,
            .{ .stream_id = STREAM_CONTROL },
            .{ .command = "run_test", .stream_id = stream_test, .test_cases = opts.test_cases },
        );

        try self.send(run_test);
        // TODO: do we actually care about waiting on the run_test_reply?
        // If so, we need a client.wait(.{ .stream_id = 0 }) or something to that effect

        return .{
            .client = self,
            .stream_id = stream_test,
            .options = opts,
        };
    }

    fn streamClose(self: *Self, stream_id: u32) !void {
        // TODO: remove stream entry from queue map
        const p: Packet = .{
            .stream_id = stream_id,
            .message_id = (1 << 31) - 1,
            .payload = &.{0xFE},
        };

        try self.send(p);
    }
};

const Connection = struct {
    writer: Io.File.Writer,
    reader: Io.File.Reader,
    initialized: bool = false,

    const Self = @This();

    fn init(writer: Io.File.Writer, reader: Io.File.Reader, arena: std.mem.Allocator) !Self {
        // initialize with a (synchonrous) handshake to the server
        const handshake: Packet = .{
            .stream_id = STREAM_CONTROL,
            .message_id = 0,
            .payload = "hegel_handshake_start",
        };

        var w = writer;
        var r = reader;

        try handshake.write(&w.interface);
        const reply: Packet = try .read(&r.interface, arena);
        defer arena.free(reply.payload);

        assert(reply.stream_id == handshake.stream_id);
        assert(reply.message_id == handshake.message_id);
        assert(reply.is_reply);

        return .{ .writer = w, .reader = r, .initialized = true };
    }
};

const Packet = struct {
    stream_id: u32,
    // Message ID can be null while constructing a Packet!
    // This isn't ideal, but it allows us to defer setting the message ID at the client layer,
    // where the generation and sequence can be controlled in one place.
    // It is assumed to be set in .write()
    message_id: ?u31 = null,
    is_reply: bool = false,
    payload: []const u8,

    const Self = @This();

    const Meta = struct {
        stream_id: u32,
        message_id: ?u31 = null,
        is_reply: bool = false,
    };

    fn encode(arena: std.mem.Allocator, meta: Meta, value: anytype) !Self {
        var w: Io.Writer.Allocating = .init(arena);
        try cbor.writeValue(&w.writer, value);

        return .{
            .stream_id = meta.stream_id,
            .message_id = meta.message_id,
            .is_reply = meta.is_reply,
            .payload = w.written(),
        };
    }

    fn write(self: Self, w: *Io.Writer) !void {
        // NOTE: message_id must be set (non-null).
        const message_id = id: {
            if (self.is_reply) {
                break :id @as(u32, self.message_id.?) | PACKET_REPLY_BIT;
            } else {
                break :id @as(u32, self.message_id.?);
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

    fn debug(self: Self, name: []const u8, gpa: std.mem.Allocator) void {
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
    try Test(.{ .test_cases = 10 }, struct {
        fn run(tc: TestCase) anyerror!void {
            const a = try tc.draw(Int(u32, .{ .min = 10, .max = 100 }));
            const b = try tc.draw(Int(u32, .{ .min = 10, .max = 100 }));

            try std.testing.expectEqual(a + b, b + a);
        }
    }.run);
}

// run = client.testRun()
//
// while (run.testCase()) |case|
//   // internally, the run is keeping a list of active test test_cases
//   // even if test_done comes in and we have an "unclaimed" test case, we run that
//   // (although, this shouldn't happen until we've completed all requested cases)
//
//   f(tc: case)
//      ... tc.draw/generate
//
//   case.complete(status)
//
// while (run.replay()) |case|
//   f(tc: case)
