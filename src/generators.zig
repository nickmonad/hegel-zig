const std = @import("std");
const cbor = @import("cbor");

const Packet = @import("packet.zig");
const Client = @import("client.zig").Client;

pub fn IntOptions(comptime T: type) type {
    return struct {
        min: T = std.math.minInt(T),
        max: T = std.math.maxInt(T),
    };
}

pub fn Int(comptime T: type, opts: IntOptions(T)) type {
    return struct {
        const Self = @This();

        generated: T = undefined,
        opts: IntOptions(T) = opts,

        pub const Result = struct {
            result: T,
        };

        pub const Schema = struct {
            type: []const u8 = "integer",
            min_value: T,
            max_value: T,
        };

        pub fn schema(self: Self) Schema {
            return .{
                .min_value = self.opts.min,
                .max_value = self.opts.max,
            };
        }

        pub fn read(packet: Packet, alloc: std.mem.Allocator, _: *Client) !?T {
            var result: Result = undefined;
            if (try cbor.match(packet.payload, cbor.extractAlloc(&result, alloc))) {
                return result.result;
            }

            try checkError(packet);
            return null;
        }
    };
}

pub const ListOptions = struct {
    min_size: u32 = 0,
    max_size: ?u32 = null,
    unique: bool = false,
};

pub fn List(comptime G: type, opts: ListOptions) type {
    return struct {
        const Self = @This();
        const T: type = @FieldType(G, "generated");

        generator: G = .{},
        generated: []const T = undefined,
        opts: ListOptions = opts,

        pub const Result = struct {
            result: []const T,
        };

        pub const Schema = struct {
            type: []const u8 = "list",
            elements: G.Schema,
            min_size: u32,
            max_size: ?u32,
            unique: bool,
        };

        pub fn schema(self: Self) Schema {
            return .{
                .elements = self.generator.schema(),
                .min_size = self.opts.min_size,
                .max_size = self.opts.max_size,
                .unique = self.opts.unique,
            };
        }

        pub fn read(packet: Packet, alloc: std.mem.Allocator, _: *Client) !?([]const T) {
            var result: Result = undefined;
            if (try cbor.match(packet.payload, cbor.extractAlloc(&result, alloc))) {
                return result.result;
            }

            try checkError(packet);
            return null;
        }
    };
}

fn checkError(packet: Packet) !void {
    var err: struct { @"error": []const u8, type: []const u8 } = undefined;
    if (try cbor.match(packet.payload, cbor.extract(&err))) {
        if (std.mem.eql(u8, err.type, "StopTest")) {
            return error.StopTest;
        }
    }
}
