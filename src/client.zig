const std = @import("std");
const assert = std.debug.assert;
const Packet = @import("packet.zig");
const hegel = @import("root.zig");
const TestRun = hegel.TestRun;

const STREAM_CONTROL: u32 = 0;

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
    pub fn init(self: *Self, io: std.Io, arena: std.mem.Allocator, log: std.Io.File) !void {
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
            .stderr = .{ .file = log },
        });

        const buf_w = try arena.alloc(u8, 4096);
        const buf_r = try arena.alloc(u8, 4096);

        self.* = .{
            .io = io,
            .arena = arena,
            .server = server,
            .streams = .init(arena),
        };

        const w: std.Io.File.Writer = self.server.stdin.?.writer(io, buf_w);
        const r: std.Io.File.Reader = self.server.stdout.?.reader(io, buf_r);

        self.connection = try .init(w, r, arena);
    }

    pub fn deinit(self: *Self) void {
        self.server.kill(self.io);
    }

    pub fn send(self: *Self, p: Packet) !void {
        const entry = try self.streams.getOrPutValue(p.stream_id, .{ .id = p.stream_id });
        var stream: *Stream = entry.value_ptr;

        const message_id = stream.next_message_id;
        stream.next_message_id += 1;

        // copy packet, keeping message_id if already set
        var copied: Packet = p;
        copied.message_id = if (p.message_id) |id| id else message_id;

        return copied.write(&self.connection.writer.interface);
    }

    pub fn reply(self: *Self, p: Packet) !void {
        assert(p.message_id.? >= 0);
        return p.write(&self.connection.writer.interface);
    }

    /// Waits on given stream ID until the expected packet payload of type T arrives. This function is "cooperative",
    /// in the sense that if it sees a packet it does not expect (on a different stream or of the wrong type)
    /// it will store the packet in the client's stream queue. All calls to this function will first check
    /// if there's an expected packet of type T on the queue, before going into a blocking wait state.
    ///
    /// Because of this, we depend heavily on the server's "liveness". The server MUST be responding with
    /// packets we expect of the correct type, otherwise we'll sit in a blocking state forever and won't
    /// allow the test run to progress. Ideally, we'll introduce some kind of timeout mechanism here, but
    /// that's a problem for another day. This would also (have to) be alleviated in a multi-threaded context, which
    /// we don't yet support.
    ///
    /// The given read function must return `null` if the provided packet does not match the expected type/shape.
    pub fn receive(
        self: *Self,
        on_stream_id: u32,
        comptime T: type,
        comptime read: fn (Packet, std.mem.Allocator, *Self) anyerror!?T,
    ) !T {
        // Check if there's already a packet matching T on the stream's queue.
        const entry = try self.streams.getOrPutValue(on_stream_id, .{ .id = on_stream_id });
        var stream: *Stream = entry.value_ptr;

        if (stream.queue.first) |first| {
            var current: ?*std.DoublyLinkedList.Node = first;

            while (current) |node| {
                const item: *QueueItem = @fieldParentPtr("node", node);
                if (try read(item.packet, self.arena, self)) |value| {
                    // Packet matches expected type T.
                    // Remove from queue and return.
                    //
                    // NOTE(nickmonad): We currently don't destroy the removed QueueItem, since we're allocated
                    // into an arena. This might have to change on very long test runs.
                    stream.queue.remove(node);
                    return value;
                }

                current = item.node.next;
            }
        }

        while (true) {
            const packet: Packet = try .read(
                &self.connection.reader.interface,
                self.arena,
            );

            if (try read(packet, self.arena, self)) |value| {
                return value;
            }

            // Queue the non-matching packet and wait for another.
            var item: *QueueItem = try self.arena.create(QueueItem);
            item.* = .{
                .node = .{},
                .packet = packet,
            };

            stream.queue.append(&item.node);
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

    pub fn streamClose(self: *Self, stream_id: u32) !void {
        // TODO: remove stream entry from queue map
        const stream_close: Packet = .{
            .stream_id = stream_id,
            .message_id = (1 << 31) - 1,
            .payload = &.{0xFE},
        };

        try self.send(stream_close);
    }
};

const Connection = struct {
    writer: std.Io.File.Writer,
    reader: std.Io.File.Reader,
    initialized: bool = false,

    const Self = @This();

    fn init(writer: std.Io.File.Writer, reader: std.Io.File.Reader, arena: std.mem.Allocator) !Self {
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
