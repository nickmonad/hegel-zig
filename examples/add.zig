const std = @import("std");
const hegel = @import("hegel");

const Test = hegel.Test;
const TestCase = hegel.TestCase;
const Int = hegel.Int;

test "hegel:add" {
    try Test(.{ .name = "man, I really hope addition works!", .test_cases = 500 }, struct {
        fn run(tc: *TestCase) anyerror!void {
            const a = try tc.draw(Int(u64, .{ .max = 1000000 }));
            const b = try tc.draw(Int(u64, .{ .min = 1000, .max = 1000000 }));

            try tc.expectEqual(@src(), a + b, b + a);
        }
    }.run);
}
