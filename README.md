> [!IMPORTANT]
> This client is not officially supported by the Hegel core team.

# Hegel for Zig

[![Casual Maintenance Intended](https://casuallymaintained.tech/badge.svg)](https://casuallymaintained.tech/)

Hegel is a property-based testing library for Zig. Hegel is based on [Hypothesis](https://github.com/hypothesisworks/hypothesis),
using the [Hegel protocol](https://hegel.dev/).

* [Hegel website](https://hegel.dev)

## Installation

TODO

At runtime, `hegel-zig` requires a running [hegel-core](https://github.com/hegeldev/hegel-core) server component.
....

Hegel will use [uv](https://docs.astral.sh/uv/) to install the required [hegel-core](https://github.com/hegeldev/hegel-core)
server component. If `uv` is already on your path, it will use that, otherwise it will download a private copy of it
to ~/.cache/hegel and not put it on your path. See https://hegel.dev/reference/installation for details.

## Quickstart

Here's a quick example of how to write a Hegel test:

```zig
pub fn todo() void {}
```

This test will fail when run with `zig test`! Hegel will produce a minimal failing test case for us:

```
TODO, show hegel.log output
```

Hegel reports the minimal example showing that our sort is incorrectly dropping duplicates.
If we remove `result = slices.Compact(result)` from `mySort()`, this test will then pass (because it's just comparing the standard sort against itself).
