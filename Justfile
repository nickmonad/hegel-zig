dev shell='fish':
    nix develop --command {{ shell }}

run:
    zig build run

build:
    zig build

test:
    zig build test

hegel cmd='version':
    @just hegel-{{ cmd }}

[private]
hegel-version:
    @$HEGEL_SERVER_COMMAND --version
