# Debugging Hummingbird

Hummingbird has no debug server of its own. Logs go to unified logging (the
systemd journal on Linux), timing goes to Instruments through signposts,
crashes and hangs come from MetricKit, and app state is read in lldb.

## Logs

Every component logs to the subsystem `com.eightybps.hummingbird` with
`os.Logger`. On Linux, `import os` resolves to SwiftOpenUI's stand-in, which has
the same API.

| Category | What |
|---|---|
| `player` | loading content, source selection, plugin reloads, UMP refreshes and UMP progress lines |
| `avplayer` | AVPlayer item status, error-log entries, failures to play to the end |
| `plugin` | alerts (toasts), compatibility patches, unsupported capabilities, call timeouts |
| `plugin.console` | plugins' own `log()` output (debug level, private) |
| `plugin.browser` | the hidden browser page (content rules) |
| `http` | opt-in traces (see below) and non-2xx plugin responses when `HUMMINGBIRD_PLUGIN_VERBOSE=1` |
| `media-proxy` | the local media proxy (cache failures) |
| `routing` | which plugin handles a URL; content rows opened |
| `account` | AT Protocol sign-in |
| `permissions` | the permission record |
| `performance` | MetricKit diagnostics, render stalls |
| `appsync.lan` | refused LAN sync requests (ATAppSync) |

**Privacy.** Interpolated strings are private unless marked `.public`. Only
values we chose (plugin IDs, event names, states, counts) and hosts are public.
URLs, titles, toasts, plugin output and error descriptions are private, so a
sysdiagnose or `log collect` from a user's device doesn't contain them. Private
values show when the debugger is attached, or with a logging profile that
enables private data. Secrets are never logged. The HTTP traces replace
`authorization`, `cookie`, token and session header values with `<redacted>`
before logging the rest as private.

Stream or read the logs:

```sh
# Live; add --level debug for plugin console output and traces
log stream --predicate 'subsystem == "com.eightybps.hummingbird"'
log stream --level debug --predicate 'subsystem == "com.eightybps.hummingbird" AND category == "player"'

# The last hour, from the store
log show --last 1h --predicate 'subsystem == "com.eightybps.hummingbird"'

# A booted simulator, or a device
xcrun simctl spawn booted log stream --predicate 'subsystem == "com.eightybps.hummingbird"'
sudo log collect --device --last 1h --output hummingbird.logarchive   # then open in Console.app
```

Console.app shows the same entries: filter on the subsystem, and turn on
Action > Include Info/Debug Messages.

Opt-in HTTP traces (debug level, `http` category):

| Variable | Traces |
|---|---|
| `HUMMINGBIRD_HTTP_TRACE=1` | YouTube `/youtubei/v1/player` and `/next` requests and responses |
| `HUMMINGBIRD_UMP_TRACE=1` | googlevideo SABR/UMP requests and responses |
| `HUMMINGBIRD_UMP_TRACE=response` | UMP responses only |
| `HUMMINGBIRD_PLUGIN_VERBOSE=1` | plugin HTTP failures (non-2xx) |

## Instruments

Signposts (`OSSignposter`, same subsystem) mark the slow paths:

| Category | Intervals | Events |
|---|---|---|
| `plugin` | `PluginCall` (plugin, function, kind; ends ok or failed), `BrowserPageLoad`, `BrowserScript` (BotGuard minting runs here) | `PluginTimeout` (the 60 s deadline) |
| `player` | `LoadContent`, `ResolveSource`, `UMPRefresh` | `UMPRefreshExhausted` |
| `media-proxy` | `ProxyRequest` (status), `UMPSegment` (track, bytes), `UMPPrefetch` | `UMPCacheHit` |
| `account` | `OAuthSignIn`, `OAuthAuthorize`, `SaveCredential`, `KeychainRead` | |
| `sync` | `SyncPass`, `LANPull`, `PDSPull` | |
| `appsync.lan` | `LANRequest`, `LANServe` | |
| `performance` | `RenderStall` (debug builds: the main thread answering 250 ms or more late) | |

To see them, either add the **os_signpost** instrument (filter on the
subsystem) or use the Hummingbird instrument, which shows them as a timeline
lane per category plus Intervals, Summary by Name and Events tables:

```sh
Tools/Instruments/build.sh      # builds .build/instruments/Hummingbird.instrdst
open .build/instruments/Hummingbird.instrdst   # installs it into Instruments
```

`Tools/Instruments/record.sh` records a trace with Time Profiler, Hangs, Points
of Interest, os_signpost, Allocations, Network Connections, HTTP Traffic and
the Hummingbird instrument together, then prints the trace's path:

```sh
Tools/Instruments/record.sh --attach Hummingbird --time-limit 30s
Tools/Instruments/record.sh --device <udid> --attach Hummingbird
open .build/instruments/Hummingbird-*.trace
```

In Instruments, File > Save as Template turns that set into a reusable
template. The repository doesn't include a `.tracetemplate`, because Instruments
only writes that binary format from its UI.

The SwiftUI template is useful for slow view updates. Hangs and Hitches show
hangs with their stacks, and the `RenderStall` intervals line up with them.

### Main-thread stalls in debug builds

Debug builds on every platform run `MainThreadWatchdog`: a background
thread that pings the main queue and times the reply, like the system's hang
detection. A reply 250 ms or more late is a stall. Each stall becomes a
`RenderStall` signpost interval, a `render_stall ms=… <context>` log entry in
the `performance` category (the active tab, its route, the player's state),
and a record in `<caches>/Stalls/stalls.json` (the newest 500, none older than
7 days). Settings › Diagnostics exports those records with the MetricKit
reports, under `"stalls"`, so a device's stalls can be shared with one tap.
Time the app is inactive or in the background (SwiftOpenUI's
`ApplicationActivity`, which every backend reports), system sleep, and time
the whole process was stopped (a breakpoint) are not counted. The watchdog does
not run under XCTest.

## Crashes, hangs and MetricKit

- **Distributed builds (TestFlight, App Store):** Xcode's Organizer shows
  crashes, hangs, disk writes, energy, launch time and terminations, and
  TestFlight feedback includes screenshots and crash logs. The app needs no
  code for this. Symbolication needs the archive's dSYMs: archive with Xcode,
  or upload dSYMs for builds made elsewhere (`DEBUG_INFORMATION_FORMAT =
  dwarf-with-dsym`, the Release default). Keep the `.xcarchive` for every
  build you distribute.
- **Every build, including xtool and Nix builds:** `PerformanceReporter`
  subscribes to MetricKit at launch on iOS, macOS and visionOS. MetricKit isn't
  available on tvOS. Each crash, hang, CPU-exception and disk-write-exception
  diagnostic is logged in the `performance` category with public-safe values
  only (kind, build, signal, duration, bytes). The payload JSON, with its call
  stacks, is kept in `<Caches>/Hummingbird/MetricKit` (newest 30 files, 8 MB at
  most). **Settings > Diagnostics > Export performance reports** shares them as
  one JSON file. Nothing is uploaded. Diagnostics usually arrive on the next
  launch; metric payloads arrive at most daily.
- **Testing payload handling:** in Xcode, Debug > Simulate MetricKit Payloads
  delivers sample payloads to the running app. `PerformanceReportTests` feeds
  stand-in diagnostics to the reporter.
- **Local macOS builds:** crash reports are in
  `~/Library/Logs/DiagnosticReports/Hummingbird-*.ips`, also listed in
  Console.app under Crash Reports.
- **Copying reports out of a container:**
  `xcrun simctl get_app_container booted com.eightybps.hummingbird data`
  (simulator), or `xcrun devicectl device copy from --device <udid> --domain-type
  appDataContainer --domain-identifier com.eightybps.hummingbird --source
  Library/Caches/Hummingbird/MetricKit --destination .` (device).

## lldb

The Hummingbird scheme loads `Tools/lldb/lldbinit`, which sources your
`~/.lldbinit` and then `Tools/lldb/hummingbird.lldb`. Anywhere else (the
command line, VS Code, Linux):

```
(lldb) command source Tools/lldb/hummingbird.lldb
```

Run `hb` commands while stopped on the main thread. Debug > Pause stops
there, and so do breakpoints in UI code. Actions take effect when you
continue.

| Command | Does |
|---|---|
| `hb state` | the newest window's active tab and route, tab and plugin counts, and the active player (playing, time, preparing, fullscreen, error); on tvOS also the focused item |
| `hb plugins` | installed plugins: id, name, version, enabled, script size, setting names |
| `hb reports` | stored MetricKit reports |
| `hb play` | toggle playback |
| `hb seek <seconds>` | skip forward or back, e.g. `hb seek 60`, `hb seek -30` |
| `hb fullscreen` | toggle fullscreen |
| `hb tabs` | toggle the tab overview |
| `hb open <url>` | open content in a new tab |
| `hb log` | how to stream the logs |

The same functions can be called directly, e.g. `expr -l Swift --
HummingbirdKit.HummingbirdDebug.state()`.

**Formatters.** `po` uses each type's Swift description: `AppModel` and
`PlayerModel` print one line, while `PluginRuntime`, `InstalledPlugin`,
`SourceAuth`, `CredentialPairingRequest` and `OAuthTokenResponse` show names
and sizes but never cookie, header, setting, secret or token values.
`SecureBytes` prints only its length. `p` and `frame variable` read memory
directly, so `hummingbird.lldb` adds summaries and child filters that give
them the same redaction, in the `hummingbird` type category:

```
(lldb) p auth
(HummingbirdKit.SourceAuth) cookies for 1 key/value pair, headers for 1 key/value pair, values redacted
(lldb) p player
(HummingbirdKit.PlayerModel) 0x… playing=false 0/0s preparing=false fullscreen=false error=nil
(lldb) type category disable hummingbird      # raw fields, when you really need them
```

**Runtime checks.** The Hummingbird scheme keeps Main Thread Checker on, so it
stops on each issue, and keeps Thread Performance Checker on. Two more schemes
run with sanitizers:

- **Hummingbird (Address Sanitizer):** Address Sanitizer plus Undefined
  Behavior Sanitizer.
- **Hummingbird (Thread Sanitizer):** Thread Sanitizer, which can't be combined
  with Address Sanitizer.

Swift 6's concurrency runtime already traps when main-actor code runs off the
main actor. For more checks, set `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` in a
scheme's environment, which makes blocking the Swift concurrency pool show up
quickly.

## Linux (GTK build)

- **Logs:** SwiftOpenUI's `os` writes each entry to the systemd journal with
  `OSLOG_SUBSYSTEM` and `OSLOG_CATEGORY` fields. It also writes to stderr when
  stderr is a terminal or the journal isn't available.

  ```sh
  journalctl --user -f OSLOG_SUBSYSTEM=com.eightybps.hummingbird
  journalctl --user OSLOG_SUBSYSTEM=com.eightybps.hummingbird OSLOG_CATEGORY=player -o json-pretty
  ```

  - `SWIFTOPENUI_LOG_LEVEL=debug|info|notice|error|fault` sets the threshold
    (`info` by default).
  - `SWIFTOPENUI_LOG_PRIVATE=1` shows private values.
  - `SWIFTOPENUI_LOG_JOURNAL=0` sends everything to stderr.
- **Signposts:** with `SWIFTOPENUI_SIGNPOSTS=1` (or the debug log level),
  intervals and events become journal entries with `SIGNPOST_TYPE`
  (`begin`/`end`/`event`), `SIGNPOST_NAME`, `SIGNPOST_ID` and, on ends,
  `SIGNPOST_DURATION_US`:

  ```sh
  journalctl --user OSLOG_SUBSYSTEM=com.eightybps.hummingbird SIGNPOST_TYPE=end -o json \
    | jq -r '[.SIGNPOST_NAME, .SIGNPOST_DURATION_US] | @tsv'
  ```

  For CPU profiles use `perf record -g` or Sysprof.
- **Crashes:** systemd-coredump keeps core dumps (`coredumpctl list
  Hummingbird-gtk`, `coredumpctl info`, `coredumpctl debug` to open one in
  the debugger). At launch, SwiftOpenUI's `MetricKit` delivers crashes since
  the last run to `PerformanceReporter` as crash diagnostics. They're logged
  and stored like on Apple platforms (under `~/.cache/Hummingbird/MetricKit`),
  with the backtrace from `coredumpctl info`. Linux has no hang or metric
  payloads.
- **lldb:** `lldb .build/debug/Hummingbird-gtk`, then `command source
  Tools/lldb/hummingbird.lldb`. The formatters and `hb` commands name only
  Hummingbird and ATProtoKit types, so they work unchanged.
