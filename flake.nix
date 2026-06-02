{
  description = "yawkar.github.io";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];

      perSystem =
        { pkgs, ... }:
        {
          devShells.default = pkgs.mkShell {
            nativeBuildInputs = with pkgs; [
              just
              pre-commit
              nixfmt
              statix
              zola
              lychee
            ];

            shellHook = ''
              pre-commit uninstall && pre-commit install
              echo "[FLAKE] DevShell for yawkar.github.io is loaded!"
            '';
          };
        };
    };
}
