{
  description = "Hegel for Zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    hegel.url = "git+https://github.com/hegeldev/hegel-core?dir=nix&ref=refs/tags/v0.9.1"; # git+https instead of github so that we can use the ref parameter
    flake-compat.url = "https://flakehub.com/f/edolstra/flake-compat/1.tar.gz";
  };

  outputs = { self, nixpkgs, hegel, ... }:
    let
      forAllSystems = nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed;
    in
    {
      # TODO: This "forAllSystems" makes no sense given I'm forcing x86_64 linux in the zig install
      # I copied most of this setup from hegel-rust. Definitely need to fix!
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          zig = pkgs.stdenv.mkDerivation {
            pname = "zig";
            version = "0.16.0";

            src = pkgs.fetchurl {
              url = "https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz";
              sha256 = "sha256-cOSWZKdDdLSLUebz/fv0N/Y5XUJQkFBYi9SavlK6PQA=";
            };

            dontConfigure = true;
            dontBuild = true;

            installPhase = ''
              mkdir -p $out/bin
              cp -r ./lib $out/
              cp ./zig $out/bin/
              cp -r ./doc $out/ || true
            '';
          };
        in
        {
          default = pkgs.mkShell {
            buildInputs = [
                pkgs.python3
                zig
            ];

            HEGEL_SERVER_COMMAND = pkgs.lib.getExe hegel.packages.${system}.default;

            shellHook = ''
              echo "zig $(zig version)"
              echo "$($HEGEL_SERVER_COMMAND --version)"
            '';
          };
        }
      );
    };
}
