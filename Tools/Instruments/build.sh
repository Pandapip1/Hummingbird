#!/usr/bin/env bash
# Builds Hummingbird's Instruments package into .build/instruments.
set -euo pipefail
repository="$(cd "$(dirname "$0")/../.." && pwd)"
output="$repository/.build/instruments/Hummingbird.instrdst"
mkdir -p "$(dirname "$output")"
developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
"$developer_dir/usr/bin/instrumentbuilder" \
  -i "$repository/Tools/Instruments/Hummingbird.instrpkg" \
  -o "$output"
echo "$output"
