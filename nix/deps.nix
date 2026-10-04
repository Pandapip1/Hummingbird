# The system libraries the SwiftPM build needs, shared by the dev shell and the
# packaged GTK app so the two cannot drift.
{ pkgs, lib }:
let
  webkitGTK = pkgs.callPackage ./webkitgtk-swift.nix { };
  # The direct media backend decodes through GStreamer, so these are needed at run time (on
  # GST_PLUGIN_SYSTEM_PATH_1_0), not just at link time.
  gstPlugins = with pkgs.gst_all_1; [
    gstreamer
    gstreamer.dev
    gst-plugins-base
    gst-plugins-base.dev
    gst-plugins-good
    gst-plugins-bad
    gst-plugins-ugly
    gst-libav
  ];
in
rec {
  inherit gstPlugins webkitGTK;
  iconTheme = pkgs.adwaita-icon-theme;

  # Used by HummingbirdKit, CQuickJS and SwiftSoup on every platform.
  baseLibs = with pkgs; [
    zlib
    libxml2
    curl
    sqlite
  ];

  # What the SwiftOpenUI GTK4 backend resolves through pkg-config.
  gtkLibs =
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
      webkitGTK # WebKitGTK 6 with upstream ICU routed to private ELF sonames
      libsoup_3 # WebKitGTK's public pkg-config dependency

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
    ++ gstPlugins
    # Satisfies glib's Requires.private on a .pc file no nixpkgs package ships;
    # see nix/sysprof-capture-stub.nix. It lands on PKG_CONFIG_PATH through the
    # ordinary pkg-config setup hook, like any other input.
    ++ [
      iconTheme # standard GTK icons in minimal/package-only sessions
      (pkgs.callPackage ./sysprof-capture-stub.nix { })
    ];

  # Everything the Linux build of the GTK app links against.
  linuxBuildLibs = baseLibs ++ gtkLibs;
}
