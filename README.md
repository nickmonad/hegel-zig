> [!IMPORTANT]
> This client is not officially supported by the Hegel core team.

> [!WARNING]
> This is far from anything that could be considered "production ready". Expect bugs, incomplete features,
> and most likely some breaking changes in the near future. Zig's testing story is great, but has some aspects
> that are tricky to work with in the context of Hegel. (Not being able to cleanly handle a panic, for instance!)
> See the section on "Limitations" for more info!

# Hegel for Zig

[![Casual Maintenance Intended](https://casuallymaintained.tech/badge.svg)](https://casuallymaintained.tech/)

`hegel-zig` is a property-based testing library for Zig, based on [Hypothesis](https://github.com/hypothesisworks/hypothesis), using the [Hegel protocol](https://hegel.dev/).

## Installation

Add to your `build.zig.zon`,

```zig
.dependencies = .{
    .hegel = .{
        .url = "git+https://github.com/nickmonad/hegel-zig#<commit>",
        .hash = "...",
    },
},
```

Then in `build.zig`,

```zig
const hegel = b.dependency("hegel", .{});
my_module.addImport("hegel", hegel.module("hegel"));
```

At runtime, `hegel-zig` requires a running [hegel-core](https://github.com/hegeldev/hegel-core) server component.

Currently, `hegel-zig` will first check if `HEGEL_SERVER_COMMAND` is set in the running environment. If so, it will use that to invoke the server. If it is not set, it will invoke `uv tool run` to download and run the server. **Today, `hegel-zig` expects that at the very least, [`uv`](https://docs.astral.sh/uv/) is installed on the host system.** Other Hegel client libraries will attempt to download `uv` and install it, but we have not implemented that here yet.

For more information on the `uv` dependency, please see the [Installation reference](https://hegel.dev/reference/installation) on the Hegel website.

## Quickstart

Here's a quick example of how to write a Hegel test! The `mySort` function deduplicates elements in
the sorted slice, which the `std` sort function does not do. Hegel will detect this difference and report a minimally failing test case.

```zig
const std = @import("std");
const hegel = @import("std");

const Test = hegel.Test;
const TestCase = hegel.TestCase;
const Int = hegel.Int;
const List = hegel.List;

fn mySort(arena: std.mem.Allocator, list: []const u64) []const u64 {
    if (list.len <= 1) {
        return list;
    }

    // Copy...
    var copied: []u64 = arena.dupe(u64, list) catch unreachable;

    // Sort...
    std.mem.sort(u64, copied, {}, comptime std.sort.asc(u64));

    // Deduplicate in-place...
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
    try Test(.{ .name = "sort", .test_cases = 100 }, struct {
        fn run(tc: *TestCase) anyerror!void {
            const l1: []const u64 = try tc.draw(List(Int(u64, .{}), .{ .max_size = 1000 }));
            const l2: []const u64 = mySort(tc.arena, l1);

            std.mem.sort(u64, @constCast(l1), {}, comptime std.sort.asc(u64));
            try tc.expectEqualSlices(@src(), u64, l1, l2);
        }
    }.run);
}
```

This test will fail when run with `zig test`! The minimally failing test case will be written to
`hegel.test.log` in the working directory. This report shows us that a slice of `{ 0, 0 }` is a minimal value we can use to reproduce the failure.

```
--- starting test run (sort) with 100 cases ---
seed = "75057069797404574521494413036682449172"
passed = false, tests = 24, invalid = 0, interesting = 1

failing test case!
Draw: { 0, 0 }
root.zig:421:TestExpectedEqual
--- end test run ---
```

## Limitations

* Documentation. More to come!
* Zig does not support parallel test execution in the standard test runner. This might change in the future, but currently, tests execute sequentially. ([Tracking issue.](https://github.com/ziglang/zig/issues/15953))
* Test cases that result in a panic or `assert()` failure will not be reported or gracefully handled. It might be possible to solve this by implementing a custom test runner, which could run each test in a separate process.
* Users MUST pass `@src()` as the first argument to all `TestCase.expect*` functions. This is so the source location can be used when reporting interesting test cases to the Hegel server.
* All tests to run in Hegel MUST begin with `"hegel:"`, in the name after the `test` keyword. This is a crude, but simple way to ensure we can properly cleanup the shared client and server resources after all tests have executed.
