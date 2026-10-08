{ runCommand }:

# GStreamer's Darwin pkg-config metadata names libunwind even though unwinding
# is supplied by the Apple platform runtime and nixpkgs ships no libunwind.pc.
# SwiftPM insists every private Requires entry resolve before using any flags.
runCommand "libunwind.pc" { } ''
  mkdir -p "$out/lib/pkgconfig"
  cp ${./pkgconfig-stubs/libunwind.pc} "$out/lib/pkgconfig/libunwind.pc"
''
