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
      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            godot
            godot-export-templates-bin
            gdtoolkit_4
          ];

          shellHook = ''
            export GODOT_EXPORT_TEMPLATES="${pkgs.godot-export-templates-bin}/share/godot/export_templates"
            echo "droplet dev shell — godot $(godot --version 2>/dev/null | head -n1)"
          '';
        };
      }
    );
}
