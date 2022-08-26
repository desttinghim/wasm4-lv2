{
  description = "WASM-4's APU in a LV2 plugin.";

  inputs = {
    zig.url = "github:mitchellh/zig-overlay";
    flake-utils.url = "github:numtide/flake-utils";
    unstable.url = "nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, zig, flake-utils, unstable }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        upkgs = unstable.legacyPackages.${system};
      in
      {

        # nix develop
        devShells.default = pkgs.mkShell {
          buildInputs = [
            zig.packages.${system}.master
            pkgs.lv2
            pkgs.lv2lint
            pkgs.jalv
            pkgs.gdb
            pkgs.valgrind
          ];
        };

      });
}
