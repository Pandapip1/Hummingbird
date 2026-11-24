#!/usr/bin/env bash
# Regenerates the WebM DASH fixture (6 s, 320x180 VP9 and stereo Opus, 2 s
# segments) in the layout plugin-generated sources use: the manifest names
# https://grayjay.internal/{video,audio}/internal/init.webm and /$Number$.webm.
set -euo pipefail
cd "$(dirname "$0")"
work=$(mktemp -d)
nix shell nixpkgs#ffmpeg --command ffmpeg -y -hide_banner -loglevel error \
  -f lavfi -i "testsrc2=s=320x180:r=30" -f lavfi -i "sine=f=440:sample_rate=48000" -t 6 \
  -map 0:v -map 1:a -c:v libvpx-vp9 -b:v 150k -g 60 -keyint_min 60 -row-mt 1 -deadline realtime \
  -c:a libopus -b:a 48k -ac 2 -f dash -dash_segment_type webm -seg_duration 2 -use_template 1 -use_timeline 1 \
  -init_seg_name 'init-$RepresentationID$.webm' -media_seg_name 'chunk-$RepresentationID$-$Number$.webm' \
  -adaptation_sets "id=0,streams=v id=1,streams=a" "$work/manifest.mpd"
mkdir -p video audio
cp "$work/init-0.webm" video/init.webm
cp "$work/init-1.webm" audio/init.webm
for f in "$work"/chunk-0-*.webm; do n=${f##*-}; cp "$f" "video/$n"; done
for f in "$work"/chunk-1-*.webm; do n=${f##*-}; cp "$f" "audio/$n"; done
awk 'BEGIN{k=""} /contentType="video"/{k="video"} /contentType="audio"/{k="audio"}
  {gsub(/initialization="init-\$RepresentationID\$\.webm" media="chunk-\$RepresentationID\$-\$Number\$\.webm"/,
        "initialization=\"https://grayjay.internal/" k "/internal/init.webm\" media=\"https://grayjay.internal/" k "/internal/$Number$.webm\""); print}' \
  "$work/manifest.mpd" > manifest.mpd
