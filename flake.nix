{
  description = "Hummingbird — a Grayjay-style plugin host: SwiftUI on iOS, SwiftOpenUI/GTK4 on Linux";

  inputs = {
    # Swift 6.2 is only in unstable; the Linux build needs >= 6.0 for Observation.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ ./nix/devshell.nix ];

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin" # nixpkgs 26.11 dropped x86_64-darwin
      ];

      perSystem = { pkgs, ... }: {
        formatter = pkgs.nixfmt-rfc-style;
      };
    };
}
