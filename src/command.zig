const std = @import("std");

const HEGEL_SERVER_VERSION = "0.9.1";

pub const Options = struct {
    debug: bool = false,
};

// First, check if HEGEL_SERVER_COMMAND is set in the environment.
// If it is, use that. Otherwise, use `uv tool run` to invoke the server.
pub fn hegelCommand(arena: std.mem.Allocator, env: std.process.Environ, opts: Options) []const []const u8 {
    if (env.getAlloc(arena, "HEGEL_SERVER_COMMAND")) |cmd| {
        return &.{
            cmd,
            "--verbosity",
            if (opts.debug) "debug" else "normal",
        };
    } else |_| {
        return &.{
            "uv",
            "tool",
            "run",
            "--from",
            "hegel-core==0.9.1",
            "hegel",
            "--verbosity",
            if (opts.debug) "debug" else "normal",
        };
    }
}
