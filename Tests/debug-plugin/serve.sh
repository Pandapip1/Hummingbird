#!/usr/bin/env bash
# Serves the debug plugin, and the test video it points at, on 127.0.0.1:8742.
#
#   ./Tests/debug-plugin/serve.sh
#
# then in the app: Sources -> + -> http://127.0.0.1:8742/DebugPlugin.json
#
# The video is generated rather than committed, so nothing binary lives in the
# repo. Needs ffmpeg and python3, both of which `nix develop` does not carry --
# the script fetches them through nix when missing.
set -euo pipefail
PORT=8742
DIR="$(cd "$(dirname "$0")" && pwd)"
VIDEO="$DIR/test.mp4"

if [ ! -f "$VIDEO" ]; then
    echo "Generating $VIDEO"
    nix shell nixpkgs#ffmpeg --command ffmpeg -loglevel error -y \
        -f lavfi -i "testsrc=duration=10:size=320x240:rate=15" \
        -f lavfi -i "sine=frequency=440:duration=10" \
        -pix_fmt yuv420p -c:v libx264 -c:a aac -shortest "$VIDEO"
fi

echo "Serving $DIR on http://127.0.0.1:$PORT"
echo "Install in the app with: http://127.0.0.1:$PORT/DebugPlugin.json"
exec nix shell nixpkgs#python3 --command python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$DIR"
