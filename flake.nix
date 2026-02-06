{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs }:
  let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in
  {
    devShells.${system}.default = pkgs.mkShell {
      buildInputs = with pkgs; [
        zig
        zls
        wrk
        nginx
      ];
      shellHook = ''
        export ZIG_GLOBAL_CACHE_DIR="$HOME/.cache/zig"
        mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
      '';
    };
  };
}

