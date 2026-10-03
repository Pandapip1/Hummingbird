# Debug source

A plugin that serves one hardcoded video, so the playback path can be exercised
against a fixed, offline input.

It exists because the video bugs are hard to compare between runs: every run
played different content, so three renderer probes produced three different
failures and none of them could be attributed. A known item removes that
variable, and makes the path testable headlessly.

The video is a 10 second 320x240 test pattern with a sine tone, muxed H.264 in
MP4 — deliberately the easiest case, needing none of the features GtkVideo
lacks (no separate audio and video streams, no custom headers, no DASH).

## Use

```sh
./Tests/debug-plugin/serve.sh
```

Then in the app: **Sources → + →** `http://127.0.0.1:8742/DebugPlugin.json`

The config carries no signature, which the installer allows; it will warn that
the plugin is unsigned.

`test.mp4` is generated on first run rather than committed, so no binary lands
in the repo. It is gitignored.
