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

      # See nix/sysprof-capture-stub.nix: without this SwiftPM silently fails to
      # find gtk/gtk.h. Only glib's .pc chain needs it, so Linux only.
      sysprofCaptureStub = pkgs.callPackage ./sysprof-capture-stub.nix { };

      # GtkVideo decodes through GStreamer, so the GTK MediaBackend needs these
      # on GST_PLUGIN_SYSTEM_PATH_1_0 at run time, not just at link time.
      gstPlugins = with pkgs.gst_all_1; [
        gstreamer
        gst-plugins-base
        gst-plugins-good
        gst-plugins-bad
        gst-plugins-ugly
        gst-libav
      ];

      # What the GTK4 backend resolves through pkg-config.
      gtkDeps =
        (with pkgs; [
          gtk4
          glib
          cairo
          pango
          gdk-pixbuf
          graphene
          harfbuzz
          fontconfig
          freetype
          libepoxy
          librsvg # gdk-pixbuf SVG loader, for icon assets

          # Not linked against directly: these appear only in the
          # Requires.private chains of glib, gio, pango, fontconfig and libX11.
          # The pkg-config binary ignores those for a dynamic link, but SwiftPM
          # parses .pc files itself, always walks the private chain, and drops
          # *every* flag for the module if one entry is unresolvable.
          pcre2
          util-linux # provides mount.pc, required by gio
          libselinux
          libsepol # required by libselinux.pc
          fribidi
          libthai
          libdatrie # provides datrie-0.2.pc, required by libthai.pc
          libxdmcp
        ])
        ++ gstPlugins;

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
          (mk "hb-test" ''
            ${lib.optionalString isLinux ''
              # SwiftOpenUI's GTK4 render tests need a display; give them a
              # throwaway one only when the caller has none of their own.
              if [ -z "''${DISPLAY:-}" ] && [ -z "''${WAYLAND_DISPLAY:-}" ]; then
                exec xvfb-run -a swift test "$@"
              fi
            ''}
            exec swift test "$@"
          '')
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
              xvfb-run
            ]
          )
          # nixpkgs only builds xcodegen on aarch64-darwin; elsewhere fall back
          # to whatever the user installed themselves.
          ++ lib.optionals (lib.meta.availableOn pkgs.stdenv.hostPlatform pkgs.xcodegen) [
            pkgs.xcodegen
          ];

        buildInputs =
          (with pkgs; [
            # HummingbirdKit, CQuickJS and SwiftSoup
            zlib
            libxml2
            curl
            sqlite
          ])
          ++ lib.optionals isLinux gtkDeps;

        env = lib.optionalAttrs isLinux {
          GST_PLUGIN_SYSTEM_PATH_1_0 = lib.makeSearchPathOutput "lib" "lib/gstreamer-1.0" gstPlugins;
          GDK_PIXBUF_MODULE_FILE = "${pkgs.librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache";
        };

        # Everything here goes to stderr: `nix develop --command hb-build` runs
        # the hook too, and this should not land in piped stdout.
        shellHook = ''
          # Keep the helper scripts anchored to the checkout even after a cd.
          export HUMMINGBIRD_ROOT="$PWD"

          ${lib.optionalString isLinux ''
            export PKG_CONFIG_PATH="${sysprofCaptureStub}/lib/pkgconfig''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
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
