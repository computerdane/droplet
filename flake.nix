{
  description = "droplet — weather radar visualizer built with Godot";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    # nixpkgs' Godot builds for Linux and Apple Silicon; the pinned nixpkgs has
    # dropped x86_64-darwin entirely.
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (pkgs.stdenv.hostPlatform) isDarwin isLinux;
        # The NEXRAD pipeline CLI (fetch, decode, dealias, VAD, basemap, fixtures).
        nexrad = pkgs.rustPlatform.buildRustPackage {
          pname = "nexrad";
          version = "0.1.0";
          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              ./Cargo.toml
              ./Cargo.lock
              ./nexrad/Cargo.toml
              ./nexrad/src
              ./nexrad-wasm/Cargo.toml
              ./nexrad-wasm/src
            ];
          };
          cargoLock.lockFile = ./Cargo.lock;
          cargoBuildFlags = [ "-p" "nexrad" ];
          cargoTestFlags = [ "-p" "nexrad" ];
          meta.mainProgram = "nexrad";
        };
        basemapSources = map pkgs.fetchurl [
          {
            url = "https://www2.census.gov/geo/tiger/GENZ2023/shp/cb_2023_us_state_500k.zip";
            hash = "sha256-SptPXPmTzSNzisSbWPu1VvHwl/z15ASp3BA0jdQfdDI=";
          }
          {
            url = "https://www2.census.gov/geo/tiger/GENZ2023/shp/cb_2023_us_county_500k.zip";
            hash = "sha256-mdZZex/Hdn3u9i4B0o2LXcvVeOFRhV99wNFzy/W/CGg=";
          }
          {
            url = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_10m_populated_places_simple.geojson";
            hash = "sha256-/T+oZ6Mgy9XFtrtbxVCv7sKTn7LO9ojlCABygqVaxC8=";
          }
        ];
        basemap = pkgs.runCommand "droplet-basemap" {} ''
          mkdir -p data/raw/basemap
          ${pkgs.lib.concatMapStringsSep "\n" (src: "cp ${src} data/raw/basemap/${src.name}") basemapSources}
          ${nexrad}/bin/nexrad basemap
          cp -r data/basemap "$out"
        '';
        project = pkgs.stdenvNoCC.mkDerivation {
          pname = "droplet-project";
          version = "0.1.0";
          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              ./project.godot ./scenes ./scripts ./shaders
            ];
          };
          nativeBuildInputs = [ pkgs.godot ];
          # Import at build time so launch never needs to write into the Nix store.
          buildPhase = ''
            export HOME="$TMPDIR/godot-home"
            mkdir -p "$HOME"
            godot --headless --path . --import
          '';
          installPhase = ''
            mkdir -p "$out"
            cp -r project.godot scenes scripts shaders .godot "$out/"
          '';
        };
        # XDG variables win when set; otherwise each platform's usual locations.
        cacheHome = if isDarwin then "$HOME/Library/Caches" else "$HOME/.cache";
        dataHome = if isDarwin then "$HOME/Library/Application Support" else "$HOME/.local/share";
        launcher = pkgs.writeShellApplication {
          name = "droplet";
          text = ''
            export DROPLET_ROOT="''${DROPLET_ROOT:-''${XDG_CACHE_HOME:-${cacheHome}}/droplet}"
            export DROPLET_EXPORT_DIR="''${DROPLET_EXPORT_DIR:-''${XDG_DATA_HOME:-${dataHome}}/droplet/exports}"
            export DROPLET_NEXRAD="${nexrad}/bin/nexrad"
            export DROPLET_BASEMAP="${basemap}"
            mkdir -p "$DROPLET_ROOT/data/volumes" "$DROPLET_EXPORT_DIR"
          '' + (if isDarwin then ''
            # Godot 4.7's Metal driver crashes (SIGBUS) compiling its built-in shaders on
            # Apple Silicon, so default to Vulkan (MoltenVK) unless a driver is given.
            driver=(--rendering-driver vulkan)
            for arg in "$@"; do
              case "$arg" in --rendering-driver | --rendering-driver=*) driver=() ;; esac
            done
            exec ${pkgs.godot}/bin/godot --path ${project} "''${driver[@]}" "$@"
          '' else ''
            exec ${pkgs.godot}/bin/godot --path ${project} "$@"
          '');
        };
        droplet = pkgs.symlinkJoin {
          name = "droplet-0.1.0";
          # The .desktop menu entry is a freedesktop (Linux) convention.
          paths = [ launcher ] ++ pkgs.lib.optional isLinux (pkgs.makeDesktopItem {
            name = "droplet";
            desktopName = "Droplet";
            comment = "Weather radar visualizer";
            exec = "droplet";
            terminal = false;
            categories = [ "Science" "Geoscience" ];
          });
          meta = {
            description = "NEXRAD weather radar visualizer";
            mainProgram = "droplet";
            platforms = pkgs.lib.platforms.linux ++ [ "aarch64-darwin" ];
          };
        };
      in
      {
        packages = { inherit droplet nexrad; default = droplet; };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            godot
            godot-export-templates-bin
            gdtoolkit_4
            cargo
            rustc
            rustfmt
            clippy
            # wasm build of the decoder (nexrad-wasm/, web/build.sh): nixpkgs' rustc already
            # ships the wasm32-unknown-unknown std; lld links it, wasm-bindgen-cli must match
            # the crate's pinned wasm-bindgen exactly.
            lld
            wasm-bindgen-cli_0_2_127
            binaryen
          ] ++ lib.optionals isLinux [
            # golden screenshots (tests/golden.sh): software GL under a virtual X server, with
            # this flake's Mesa rather than the host driver, so every machine renders alike.
            xvfb-run
          ] ++ [
            # PR automation and offline Chromium smoke tests use this same locked toolset.
            nodejs_24
          ] ++ lib.optionals isLinux [
            # nixpkgs' Chromium is Linux-only.
            chromium
          ] ++ [
            actionlint
            shellcheck
          ];

          shellHook = ''
            export GODOT_EXPORT_TEMPLATES="${pkgs.godot-export-templates-bin}/share/godot/export_templates"
          '' + pkgs.lib.optionalString isLinux ''
            export DROPLET_GL_LIBS="${pkgs.libglvnd}/lib:${pkgs.mesa}/lib"
          '' + ''
            # `cargo build --release` puts the nexrad CLI here; the fetch panel runs it from PATH.
            export PATH="$PWD/nexrad/target/release:$PATH"
            echo "droplet dev shell — godot $(godot --version 2>/dev/null | head -n1)"
          '';
        };
      }
    );
}
