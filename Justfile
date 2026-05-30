dev shell='fish':
    nix develop --command {{ shell }}

run:
    zig build run

build:
    zig build

test:
    zig build test --summary all

example name='add':
    zig build {{ name }} --summary all

clean:
    rm -rf .zig-cache zig-out .hegel hegel*.log

hegel cmd='version':
    @just hegel-{{ cmd }}

[private]
hegel-version:
    @$HEGEL_SERVER_COMMAND --version
