const std = @import("std");
const hegel = @import("hegel");

const Test = hegel.Test;
const TestCase = hegel.TestCase;
const List = hegel.List;
const Int = hegel.Int;

fn mySort(arena: std.mem.Allocator, list: []const u64) []const u64 {
    if (list.len <= 1) {
        return list;
    }

    // Copy...
    var copied: []u64 = arena.dupe(u64, list) catch unreachable;

    // Sort...
    std.mem.sort(u64, copied, {}, comptime std.sort.asc(u64));

    // Deduplicate in-place...
    // This is the difference from the std lib sort!
    var insert: usize = 0;
    for (1..copied.len) |i| {
        if (copied[i] != copied[insert]) {
            insert += 1;
            copied[insert] = copied[i];
        }
    }

    return copied[0..(insert + 1)];
}

test "hegel:sort" {
    try Test(.{ .name = "sort fail", .test_cases = 100 }, struct {
        fn run(tc: *TestCase) anyerror!void {
            const l1: []const u64 = try tc.draw(List(Int(u64, .{}), .{ .max_size = 1000 }));
            const l2: []const u64 = mySort(tc.arena, l1);

            std.mem.sort(u64, @constCast(l1), {}, comptime std.sort.asc(u64));
            try tc.expectEqualSlices(@src(), u64, l1, l2);
        }
    }.run);
}
