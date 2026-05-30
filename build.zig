const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // dependencies
    const cbor = b.dependency("cbor", .{});

    const hegel = b.addModule("hegel", .{
        .root_source_file = b.path("src/hegel.zig"),
        .optimize = optimize,
        .target = target, // Root module of a test executable requires us to specify a target.
        .imports = &.{
            .{ .name = "cbor", .module = cbor.module("cbor") },
        },
    });

    // "test"
    // run tests for the hegel module (during development)
    const hegel_tests = b.addTest(.{
        .root_module = hegel,
    });

    var run_hegel_tests = b.addRunArtifact(hegel_tests);
    // NOTE(nickmonad): I don't really know if this is needed or not.
    // I observed that the hegel server is spawned with and without it...
    run_hegel_tests.has_side_effects = true;

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_hegel_tests.step);

    // run example hegel tests under examples/
    // create a module and test for each example specified here.
    // Can be invoked via `zig build {example name}`
    const Example = struct {
        name: []const u8,
        path: []const u8,
    };

    const examples = [_]Example{
        .{ .name = "add", .path = "examples/add.zig" },
        .{ .name = "sort", .path = "examples/sort.zig" },
    };

    for (examples) |example| {
        const example_test = b.addTest(.{
            .root_module = b.addModule(example.name, .{
                .root_source_file = b.path(example.path),
                .target = target,
                .imports = &.{
                    .{ .name = "hegel", .module = hegel },
                },
            }),
        });

        const run_example_test = b.addRunArtifact(example_test);
        const example_step = b.step(example.name, "Run example test");
        example_step.dependOn(&run_example_test.step);
    }
}
