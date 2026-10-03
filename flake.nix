{
  description = "Hummingbird — a Grayjay-style plugin host: SwiftUI on iOS, SwiftOpenUI/GTK4 on Linux";

  inputs = {
    # The GTK build needs Vendor/SwiftOpenUI, and flake source copying skips
    # submodule content unless the flake asks for it.
    self.submodules = true;

    # Swift 6.2 is only in unstable; the Linux build needs >= 6.0 for Observation.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
  };

  outputs =
    inputs@{ flake-parts, self, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ ./nix/devshell.nix ];

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin" # nixpkgs 26.11 dropped x86_64-darwin
      ];

      perSystem =
        { lib, pkgs, ... }:
        {
          # Only the GTK app is packaged. The iOS app needs Xcode, which cannot
          # come from nixpkgs, so on macOS this flake is a dev shell only.
          packages = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (
            let
              # Only what the SwiftPM build actually reads. Without this, src is the
              # whole repo and a docs-only commit changes the derivation hash.
              src = lib.fileset.toSource {
                root = ./.;
                fileset = lib.fileset.unions [
                  ./Package.swift
                  ./Sources
                  # The manifest declares a test target, and SwiftPM validates every
                  # declared path even for a --product build.
                  ./Tests
                  # The SwiftOpenUI path dependency, submodule content included.
                  ./Vendor
                ];
              };

              hummingbird-gtk = pkgs.callPackage ./nix/package.nix {
                inherit src;
                buildLibs = (import ./nix/deps.nix { inherit pkgs lib; }).linuxBuildLibs;
              };
            in
            {
              inherit hummingbird-gtk;
              default = hummingbird-gtk;
            }
          );

          formatter = pkgs.nixfmt-rfc-style;
        };
    };
}
