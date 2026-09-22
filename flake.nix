{
  description = "droplet — weather radar visualizer built with Godot";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        # The NEXRAD pipeline CLI (fetch, decode, dealias, VAD, basemap, fixtures).
        nexrad = pkgs.rustPlatform.buildRustPackage {
          pname = "nexrad";
          version = "0.1.0";
          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [ ./Cargo.toml ./Cargo.lock ./nexrad/Cargo.toml ./nexrad/src ];
          };
          cargoLock.lockFile = ./Cargo.lock;
        };
      in
      {
        packages.default = nexrad;

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            godot
            godot-export-templates-bin
            gdtoolkit_4
            cargo
            rustc
            rustfmt
            clippy
          ];

          shellHook = ''
            export GODOT_EXPORT_TEMPLATES="${pkgs.godot-export-templates-bin}/share/godot/export_templates"
            # `cargo build --release` puts the nexrad CLI here; the fetch panel runs it from PATH.
            export PATH="$PWD/nexrad/target/release:$PATH"
            echo "droplet dev shell — godot $(godot --version 2>/dev/null | head -n1)"
          '';
        };
      }
    );
}
