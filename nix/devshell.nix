# Dev shell for every variant this repo builds:
#   * HummingbirdKit + its tests (SwiftPM)             — Linux and macOS
#   * Hummingbird-gtk, the SwiftOpenUI/GTK4 executable — Linux only
#   * the iOS app (XcodeGen + Xcode)                   — macOS only
{ ... }:
{
  perSystem =
    {
      lib,
      pkgs,
      system,
      ...
    }:
    let
      inherit (pkgs.stdenv.hostPlatform) isLinux isDarwin;
      deps = import ./deps.nix { inherit pkgs lib; };

      # One command per variant, so building does not depend on remembering
      # flags. Extra arguments pass through to the underlying tool.
      scripts =
        let
          mk =
            name: text:
            pkgs.writeShellScriptBin name ''
              set -euo pipefail
              cd "''${HUMMINGBIRD_ROOT:-$PWD}"
              ${text}
            '';
        in
        [
          (mk "hb-build" ''exec swift build "$@"'')
          (mk "hb-test" ''exec swift test "$@"'')
        ]
        ++ lib.optionals isLinux [
          (mk "hb-run" ''exec swift run Hummingbird-gtk "$@"'')
        ]
        ++ lib.optionals isDarwin [
          (mk "hb-xcode" ''
            xcodegen generate
            echo "Hummingbird.xcodeproj regenerated from project.yml"
          '')
          (mk "hb-build-ios" ''
            xcodegen generate
            exec xcodebuild \
              -project Hummingbird.xcodeproj \
              -scheme Hummingbird \
              -destination "generic/platform=iOS Simulator" \
              -derivedDataPath .build/DerivedData \
              build "$@"
          '')
        ];
    in
    {
      devShells.default = pkgs.mkShell {
        nativeBuildInputs =
          (with pkgs; [
            pkg-config
            git
          ])
          ++ scripts
          # On Linux the toolchain comes from nixpkgs: swift is the compiler and
          # swiftpm the `swift build` / `swift package` driver, shipped separately.
          #
          # On macOS it deliberately does not. The iOS and macOS SDKs only come
          # with Xcode, and putting a second swift on PATH there shadows the one
          # that matches those SDKs.
          ++ lib.optionals isLinux (
            with pkgs;
            [
              swift
              swiftpm
              swift-format
              xvfb
              # Not linked against anything — run-time tools the test suite shells
              # out to for DebugPluginAudioPlaybackTests' isolated PipeWire
              # instance (IsolatedAudioSession), same role as xvfb-run above.
              pipewire
              wireplumber
              dbus # private session bus for the isolated PipeWire integration test
              pulseaudio # pactl/parecord: Pulse-protocol clients that talk to pipewire-pulse
              # Tests/debug-plugin's range_server.py (GTKPlaybackTests,
              # DebugPluginAudioPlaybackTests) and generating test.mp4 on demand
              # both need python3/ffmpeg; neither was previously in this shell
              # (serve.sh's own comment: "Needs ffmpeg and python3, both of which
              # `nix develop` does not carry"), which is exactly what let
              # GTKPlaybackTests quietly depend on a developer having run
              # `serve.sh` by hand at least once outside the shell.
              python3
              ffmpeg
            ]
          )
          # nixpkgs only builds xcodegen on aarch64-darwin; elsewhere fall back
          # to whatever the user installed themselves.
          ++ lib.optionals (lib.meta.availableOn pkgs.stdenv.hostPlatform pkgs.xcodegen) [
            pkgs.xcodegen
          ];

        buildInputs = deps.baseLibs ++ lib.optionals isLinux deps.gtkLibs;

        env = lib.optionalAttrs isLinux {
          GST_PLUGIN_SYSTEM_PATH_1_0 = lib.makeSearchPathOutput "lib" "lib/gstreamer-1.0" deps.gstPlugins;
          # SwiftPM's system-library importer does not consume pkg-config
          # include flags for transitive C headers, so expose GStreamer dev
          # headers explicitly to the GTK backend build.
          CPATH = lib.makeSearchPath "include/gstreamer-1.0" [
            pkgs.gst_all_1.gstreamer.dev
            pkgs.gst_all_1.gst-plugins-base.dev
          ];
          GDK_PIXBUF_MODULE_FILE = "${pkgs.librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache";
        };

        # Everything here goes to stderr: `nix develop --command hb-build` runs
        # the hook too, and this should not land in piped stdout.
        shellHook = ''
          # Keep the helper scripts anchored to the checkout even after a cd.
          export HUMMINGBIRD_ROOT="$PWD"
          export XDG_DATA_DIRS="${deps.iconTheme}/share:''${XDG_DATA_DIRS:-}"
          ${lib.optionalString isLinux ''
            export GIO_EXTRA_MODULES="${pkgs.glib-networking}/lib/gio/modules:''${GIO_EXTRA_MODULES:-}"
            # JSC's default 4 GiB structure heap and 512 MiB JIT reservation
            # consume real commit budget when Linux disables overcommit. Keep
            # JIT enabled, and let callers override these embedding defaults.
            export JSC_structureHeapSizeInKB="''${JSC_structureHeapSizeInKB:-262144}"
            export JSC_jitMemoryReservationSize="''${JSC_jitMemoryReservationSize:-67108864}"
          ''}

          ${lib.optionalString isDarwin ''
            if ! xcrun -f xcodebuild >/dev/null 2>&1; then
              echo "warning: no Xcode found — the iOS variant needs Xcode and an iOS SDK" >&2
            fi
          ''}

          if [ ! -e Vendor/SwiftOpenUI/Package.swift ]; then
            echo "warning: Vendor/SwiftOpenUI is empty — run 'git submodule update --init'" >&2
          fi

          echo "Hummingbird dev shell (${system}) — swift $(swift --version 2>/dev/null | sed -n 's/.*version \([0-9.]*\).*/\1/p' | head -1)" >&2
          echo "  hb-build, hb-test${lib.optionalString isLinux ", hb-run (GTK app)"}${lib.optionalString isDarwin ", hb-xcode, hb-build-ios"}" >&2
        '';
      };
    };
}
