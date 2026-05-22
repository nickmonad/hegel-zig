const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const cbor = @import("cbor");
const Client = @import("client.zig").Client;
const Packet = @import("packet.zig");

const generators = @import("generators.zig");
pub const Int = generators.Int;
pub const List = generators.List;

pub const TestOptions = struct {
    test_cases: u32,
    seed: ?[]const u8 = null,
    skip: bool = false,
    name: ?[]const u8 = null,
};

/// Runs a Hegel test case, using std.testing.*
/// values as the backing Io and Allocator instances.
/// This can only be used in the context of a Zig test.
pub fn Test(opts: TestOptions, comptime func: fn (*TestCase) anyerror!void) !void {
    try Session.init();
    defer Session.deinit();

    if (opts.skip) return;

    var client = Session.client.?;
    try client.log("--- starting test run, name = {s}, cases = {d} ---\n", .{
        if (opts.name) |name| name else "no_name",
        opts.test_cases,
    });

    var results: ?TestDone = null;
    const run = try client.testRun(.{
        .test_cases = opts.test_cases,
        .seed = opts.seed,
    });

    while (true) {
        switch (try run.event()) {
            .case => |case| {
                var tc = case;

                if (func(&tc)) {
                    try tc.complete(.valid);
                } else |_| {
                    try tc.complete(.interesting);
                }

                try client.streamClose(tc.stream_id);
            },
            .done => |done| {
                results = done;
                break;
            },
        }
    }

    try client.log("seed = \"{s}\"\n", .{results.?.seed});
    try client.log("passed = {any}, tests = {d}, invalid = {d}, interesting = {d}\n", .{
        results.?.passed,
        results.?.test_cases,
        results.?.invalid_test_cases,
        results.?.interesting_test_cases,
    });

    // Run each final replay of interesting test cases.
    for (0..(results.?.interesting_test_cases)) |_| {
        var tc = try run.replay();
        try client.log("\nfailing test case!\n", .{});

        if (func(&tc)) {
            @panic("previously failing test is now passing");
        } else |_| {
            try tc.complete(.interesting);
            try client.log("{s}:{s}:{d}\n", .{
                @errorName(tc.@"error".?),
                tc.error_origin.?.file,
                tc.error_origin.?.line,
            });
        }

        try client.streamClose(tc.stream_id);
    }

    try client.log("--- end test run ---\n", .{});
}

const Session = struct {
    // TODO: This implementation is not thread-safe!
    // We're currently assuming single-threaded test execution in Zig.
    // This may change in the future, or we'll want to use this in a more generic way,
    // so we'll need a thread-safe version.
    // This includes the Client, as well! We'll need a thread-safe way to increment
    // the "next" stream ID as we start test runs.
    var io: ?std.Io.Threaded = null;
    var gpa: ?std.heap.DebugAllocator(.{}) = null;
    var arena: ?std.heap.ArenaAllocator = null;
    var client: ?*Client = null;
    var initialized: bool = false;
    var test_count: u32 = 0;

    fn init() !void {
        if (Session.initialized) return;

        // Determine how many tests we'll run.
        // Test functions as seen via `builtin` must contain "hegel:" to be part of this count.
        for (builtin.test_functions) |test_fn| {
            if (std.mem.containsAtLeast(u8, test_fn.name, 1, "hegel:")) {
                Session.test_count += 1;
            }
        }

        Session.gpa = .init;
        Session.arena = .init(Session.gpa.?.allocator());
        errdefer Session.arena.?.deinit();
        const alloc = Session.arena.?.allocator();

        Session.io = std.Io.Threaded.init(alloc, .{});

        var c = try alloc.create(Client);
        try c.init(Session.io.?.io(), alloc, std.testing.environ, .{ .debug = true });

        Session.client = c;
        Session.initialized = true;
    }

    fn deinit() void {
        if (Session.test_count > 0) {
            Session.test_count -= 1;
        }

        if (Session.test_count == 0) {
            Session.client.?.deinit();
            Session.arena.?.deinit();

            _ = Session.gpa.?.detectLeaks();
            assert(Session.gpa.?.deinit() == .ok);
        }
    }
};

pub const TestRun = struct {
    client: *Client,

    stream_id: u32,
    options: Options,

    pub const Options = struct {
        test_cases: u32,
        seed: ?[]const u8 = null,
        report_multiple_failures: bool = false,
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

    @"error": ?anyerror = null,
    error_origin: ?std.builtin.SourceLocation = null,

    const Event = struct {
        event: []const u8,
        stream_id: u32,
        is_final: bool,
    };

    pub const Status = enum {
        valid,
        invalid,
        interesting,
    };

    pub fn draw(self: TestCase, comptime G: type) !@FieldType(G, "generated") {
        const R: type = @FieldType(G, "generated");
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
        const result: R = try self.client.receive(self.stream_id, R, G.read);

        if (self.is_final) {
            try self.client.log("Draw: {any}\n", .{result});
        }

        return result;
    }

    pub fn assume(self: TestCase, condition: bool) !void {
        if (!condition) {
            return self.complete(.invalid);
        }
    }

    fn complete(self: TestCase, status: Status) !void {
        var origin: [256]u8 = undefined;
        const mark_complete: Packet = try .encode(
            self.client.arena,
            .{ .stream_id = self.stream_id },
            .{
                .command = "mark_complete",
                .status = switch (status) {
                    .valid => "VALID",
                    .invalid => "INVALID",
                    .interesting => "INTERESTING",
                },
                .origin = switch (status) {
                    .interesting => origin: {
                        // Format origin, using error and source location.
                        // {error}:{file}:{line} will be sent to hegel server.
                        // error and error_origin are asserted to be present.
                        break :origin try std.fmt.bufPrint(&origin, "{s}:{s}:{d}", .{
                            @errorName(self.@"error".?),
                            self.error_origin.?.file,
                            self.error_origin.?.line,
                        });
                    },
                    else => null,
                },
            },
        );

        try self.client.send(mark_complete);

        // TODO(nickmonad): wait for mark_complete_reply?
        // Currently, for some our a test cases, we're not getting a mark_complete_reply
        // in a format documented in the protocol reference.
        // Instead of { 'result': null }, we get { 'error': 'N', 'type': 'StopTest' }.
        // Apparently, we can ignore these for now, but more investigation is needed!
    }

    pub fn expect(
        self: *TestCase,
        comptime src: std.builtin.SourceLocation,
        ok: bool,
    ) !void {
        std.testing.expect(ok) catch |err| {
            self.@"error" = err;
            self.error_origin = src;

            return err;
        };
    }

    pub fn expectEqual(
        self: *TestCase,
        comptime src: std.builtin.SourceLocation,
        expected: anytype,
        actual: anytype,
    ) !void {
        std.testing.expectEqual(expected, actual) catch |err| {
            self.@"error" = err;
            self.error_origin = src;

            return err;
        };
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

test "hegel:example:int" {
    try Test(.{ .name = "example int", .test_cases = 5 }, struct {
        fn run(tc: *TestCase) anyerror!void {
            const a = try tc.draw(Int(u64, .{ .min = 10, .max = 100 }));
            const b = try tc.draw(Int(u64, .{ .min = 1000, .max = 2000 }));

            try tc.expectEqual(@src(), a + b, b + a);
        }
    }.run);
}

test "hegel:example:list" {
    try Test(.{ .name = "example list", .test_cases = 1 }, struct {
        fn run(tc: *TestCase) anyerror!void {
            const a: []const u64 = try tc.draw(List(Int(u64, .{ .min = 10, .max = 100 }), .{ .min_size = 1, .max_size = 10 }));
            try tc.expect(@src(), a.len >= 1 and a.len <= 10);
            try tc.expect(@src(), a[0] == 10);
        }
    }.run);
}
