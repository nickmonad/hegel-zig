const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const cbor = @import("cbor");

const hegel = @import("hegel");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.arena.allocator();

    var client: *hegel.Client = try alloc.create(hegel.Client);
    try client.init(io, alloc);

    assert(client.connection.initialized);
    client.deinit();
}
