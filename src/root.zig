//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const assert = std.debug.assert;
const cbor = @import("cbor");
const Client = @import("client.zig").Client;
const Packet = @import("packet.zig");

const generators = @import("generators.zig");
pub const Int = generators.Int;

pub const TestOptions = struct {
    skip: bool = false,
    name: ?[]const u8 = null,
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
pub fn Test(opts: TestOptions, comptime func: fn (TestCase) anyerror!void) !void {
    try Session.init(std.testing.io, std.testing.allocator);
    defer Session.deinit();

    if (opts.skip) return;

    var client = Session.client.?;
    const run = try client.testRun(.{ .test_cases = opts.test_cases });
    var results: ?TestDone = null;

    while (true) {
        switch (try run.event()) {
            .case => |tc| {
                // TODO: handle error and update status
                func(tc) catch unreachable;

                try tc.complete(.{ .status = .valid });
                try client.streamClose(tc.stream_id);
            },
            .done => |done| {
                results = done;
                break;
            },
        }
    }

    // Run each final test case.
    for (0..results.?.interesting_test_cases) |_| {
        const tc = try run.replay();
        func(tc) catch unreachable;

        try tc.complete(.{ .status = .valid });
        try client.streamClose(tc.stream_id);
    }
}

const Session = struct {
    // TODO: This implementation is not thread-safe!
    // We're currently assuming single-threaded test execution in Zig.
    // This may change in the future, or we'll want to use this in a more generic way,
    // so we'll need a thread-safe version.
    // This includes the Client, as well! We'll need a thread-safe way to increment
    // the "next" stream ID as we start test runs.
    var io: ?std.Io = null;
    var arena: ?std.heap.ArenaAllocator = null;
    var log: ?std.Io.File = null;
    var client: ?*Client = null;
    var initialized: bool = false;
    var test_count: u32 = 0;

    fn init(io_: std.Io, gpa: std.mem.Allocator) !void {
        if (Session.initialized) return;

        Session.io = io_;
        Session.arena = .init(gpa);
        Session.log = try std.Io.Dir.cwd().createFile(io_, "hegel.log", .{ .truncate = true });

        const alloc = Session.arena.?.allocator();

        var c = alloc.create(Client) catch unreachable;
        try c.init(Session.io.?, alloc, Session.log.?);

        Session.client = c;
        Session.initialized = true;
    }

    fn deinit() void {
        Session.client.?.deinit();
        Session.arena.?.deinit();
    }
};

pub const TestRun = struct {
    client: *Client,

    stream_id: u32,
    options: Options,

    pub const Options = struct {
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
                        .is_final = test_case.is_final,
                    },
                };
            }

            var test_done: TestDone.Event = undefined;
            if (try cbor.match(packet.payload, cbor.extractAlloc(&test_done, arena))) {
                const test_done_reply: Packet = try .encode(
                    arena,
                    .{
                        .stream_id = packet.stream_id,
                        .message_id = packet.message_id,
                        .is_reply = true,
                    },
                    .{
                        .result = true,
                    },
                );

                try client.send(test_done_reply);
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

    /// Receive an event from the run's stream.
    /// Asserts the returned event is a test_case. Anything else would be a protocol error from the server.
    pub fn replay(self: TestRun) !TestCase {
        const evt = try self.event();
        return evt.case;
    }
};

pub const TestCase = struct {
    client: *Client,
    stream_id: u32,
    is_final: bool,

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

    pub fn draw(self: TestCase, comptime G: type) !@FieldType(G, "generated") {
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

    pub fn assume(self: TestCase, condition: bool) !void {
        if (!condition) {
            return self.complete(.{ .status = .invalid });
        }
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

        // send...
        try self.client.send(mark_complete);

        // TODO(nickmonad): wait for mark_complete_reply?
        // Currently, for some our a test cases, we're not getting a mark_complete_reply
        // in a format documented in the protocol reference.
        // Instead of { 'result': null }, we get { 'error': 'N', 'type': 'StopTest' }.
        // Apparently, we can ignore these for now, but more investigation is needed!
    }
};

pub const TestDone = struct {
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

test "hegel" {
    try Test(.{ .test_cases = 10 }, struct {
        fn run(tc: TestCase) anyerror!void {
            const a = try tc.draw(Int(u64, .{ .min = 10, .max = 1000 }));
            const b = try tc.draw(Int(u64, .{ .min = 10, .max = 1000 }));

            try std.testing.expectEqual(a + b, b + a);
        }
    }.run);
}
