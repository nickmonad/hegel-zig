const std = @import("std");
const cbor = @import("cbor");

const Packet = @import("packet.zig");
const Client = @import("client.zig").Client;

pub fn IntOptions(comptime T: type) type {
    return struct {
        min: ?T = null,
        max: ?T = null,
    };
}

pub fn Int(comptime T: type, opts: IntOptions(T)) type {
    return struct {
        const Self = @This();

        generated: T = undefined,
        opts: IntOptions(T) = opts,

        pub const Schema = struct {
            type: []const u8 = "integer",
            min_value: ?T,
            max_value: ?T,
        };

        pub const Result = struct {
            result: T,
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

            return null;
        }
    };
}
