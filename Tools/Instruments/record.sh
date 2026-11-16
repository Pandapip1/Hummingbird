#!/usr/bin/env bash
# Records a Hummingbird trace with the instruments worth having together:
# Time Profiler, Hangs, Points of Interest, os_signpost, Allocations, Network
# Connections, HTTP Traffic and the Hummingbird instrument (our signposts as
# lanes and tables). Open the result in Instruments; File > Save as Template
# keeps this set as a reusable template.
#
#   Tools/Instruments/record.sh --attach Hummingbird
#   Tools/Instruments/record.sh --device <udid> --attach Hummingbird
#   Tools/Instruments/record.sh --launch -- /path/to/Hummingbird.app
#
# Arguments are passed to `xctrace record` after the instrument list; add
# --time-limit 30s to stop on its own. The trace goes to .build/instruments.
set -euo pipefail
repository="$(cd "$(dirname "$0")/../.." && pwd)"
package="$("$repository/Tools/Instruments/build.sh" | tail -1)"
output="$repository/.build/instruments/Hummingbird-$(date +%Y%m%d-%H%M%S).trace"
xcrun xctrace record \
  --package "$package" \
  --template "Time Profiler" \
  --instrument "Hangs" \
  --instrument "Points of Interest" \
  --instrument "os_signpost" \
  --instrument "Allocations" \
  --instrument "Network Connections" \
  --instrument "HTTP Traffic" \
  --instrument "Hummingbird" \
  --output "$output" \
  "$@"
echo "$output"
