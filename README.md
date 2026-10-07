# Hummingbird

A [Grayjay](https://grayjay.app)-style plugin host: it loads JavaScript sources that expose home feeds, search,
channels, video details and playback streams. One Swift codebase builds as a SwiftUI iOS app and as a Linux (GTK4)
desktop app through [SwiftOpenUI](https://github.com/codelynx/SwiftOpenUI).

## Platform status

| Platform | UI | JS engine | Status |
|---|---|---|---|
| iOS 17+ | SwiftUI | JavaScriptCore | Written, **never built or run** (no Xcode here) |
| Linux | SwiftOpenUI GTK4 | JavaScriptCoreGTK | Builds, 20 tests pass, launches and renders (smoke-tested under Xvfb) |
| Android | SwiftOpenUI Compose backend | JavaScriptCore required | **Not attempted or verified.** `HummingbirdKit` has no JavaScriptCore backend or Android entry point yet |

The Linux smoke test only confirmed that the window opens and the empty-state Home screen renders. No real plugin
was loaded through the GTK UI, and video playback in GTK is untested.

## Build

iOS:
```sh
brew install xcodegen
xcodegen generate        # creates Hummingbird.xcodeproj from project.yml; it consumes this package's HummingbirdKit
open Hummingbird.xcodeproj
```

Linux (Swift 6.1+, GTK 4 development packages, GStreamer for video):
```sh
git submodule update --init
swift build -Xlinker --allow-shlib-undefined   # the flag is already set in Package.swift; shown for reference
swift test
swift run Hummingbird-gtk
```

Nix (both Linux and macOS, `flake.nix` + `nix/`):
```sh
git submodule update --init
nix develop              # Swift 6.2 + GTK4/GStreamer on Linux; XcodeGen + your Xcode toolchain on macOS
hb-build                 # swift build
hb-test                  # swift test (wrapped in xvfb-run when there is no display)
hb-run                   # Linux: swift run Hummingbird-gtk
hb-xcode / hb-build-ios  # macOS: regenerate Hummingbird.xcodeproj, then xcodebuild it
```
On macOS the shell does not ship a Swift toolchain on purpose: the iOS and macOS SDKs only come with Xcode,
and a second `swift` on `PATH` would shadow the one that matches them.

The Linux Nix shell and packaged launcher default JavaScriptCore's structure-heap reservation to 256 MiB
(`JSC_structureHeapSizeInKB=262144`) and its JIT-code reservation to 64 MiB
(`JSC_jitMemoryReservationSize=67108864`). WebKit subprocesses inherit these settings. This avoids charging
several GiB of unused reservations per process on systems with `vm.overcommit_memory=2`; it does not disable
JIT or cap the general JavaScript heap. Existing values of either environment variable take precedence.
Use the same variables when running a locally built executable outside the Nix shell.

## SwiftOpenUI fork

`Vendor/SwiftOpenUI` is a submodule of a fork (branch `hummingbird`) that adds the SwiftUI API Hummingbird uses and upstream lacks:
button roles, alert actions, `ContentUnavailableView`, `LabeledContent`, `ShareLink`, `AsyncImage`, `AppStorage`,
`TabView(selection:)` with `tabItem`, `.task(id:)`, `fileImporter`, and AVKit-compatible `AVPlayer`/`VideoPlayer`
(GTK4, backed by a direct GStreamer appsink pipeline),
no-op desktop modifiers, and `@Environment(Type.self)` reads outside a render pass. Unsupported things are stubs,
not implementations: `onDelete`, `onMove` and `EditButton` do nothing in GTK. `Scripts/sync-fork.sh` refreshes the
submodule from the fork. The fork is a local clone and has not been pushed to any remote.

## How it works

| Piece | Where |
|---|---|
| JS engine protocol and JavaScriptCore implementations | `Sources/HummingbirdKit/Core/Engine/` |
| Plugin runtime (`Type`, `PlatformVideo`, pagers, exceptions, `http`, ...) over a single `__hostCall` bridge | `Core/Plugin/Resources/prelude.js`, `Core/Plugin/PluginRuntime.swift` |
| Install flow with RSA-SHA512 signature check (swift-crypto off Apple) and a validation dry run | `PluginManager.swift`, `ScriptSignature.swift` |
| `allowUrls` enforcement, per-plugin cookie jars, credential store (Keychain on Apple, 0600 file elsewhere) | `HostHTTP.swift`, `SourceAuth.swift` |
| Login: WKWebView capture on iOS; manual cookie/header paste form elsewhere | `UI/Views/WebAuthView.swift`, `ManualAuthView.swift` |
| Playback seam `MediaBackend`: AVPlayer (HLS, MP4, joined audio) or GTK/GStreamer | `UI/Playback/` |
| Subscriptions, playlists, watch later, history, JSON backup, merged feed | `Core/Services/`, `Core/Models/` |

## Not supported

- Everywhere: WebM/VP9/Opus, DASH and Widevine, WebSockets, the JSDOM/Browser packages, subscription groups,
  background refresh, live chat. `HttpImp` is an alias of the normal HTTP client.
- Linux/GTK: the GStreamer backend cannot send custom HTTP headers yet, so sources with a `requestModifier` are not
  offered. It supports muxed and independent video/audio streams. QR scanning and in-app web login are absent. No lazy list
  realisation (`LazyVStack` becomes `VStack`). Swipe-to-delete and drag-to-reorder do nothing.
- Whether redirect handling matches the Android Grayjay app exactly is unverified.

## Clean-room note

Grayjay's application source was not read by the author of this code. It was built from the public plugin
documentation, third-party example plugins, and prose answers from a separate subagent that was allowed to look at
the host's behaviour. Nothing was copied from it.

## Sources

- [Grayjay plugin development guide](https://gitlab.futo.org/videostreaming/grayjay/-/blob/master/plugin-development.md) (the page would not load for the tooling, so details came from the type reference and example plugins below)
- Plugin type reference: `types/plugin.d.ts` in the Joyn plugin (`grayjay-source-joyn`, [#plugin.d.ts](https://gitlab.futo.org/videostreaming/grayjay/-/blob/master/plugin-development.md))
- Example plugin: Odysee (`grayjay-plugin-odysee`), loaded successfully by `Tests/load-real-plugin.test.js`
- [Apple: JavaScriptCore](https://developer.apple.com/documentation/javascriptcore), [AVFoundation](https://developer.apple.com/documentation/avfoundation), [WKWebView](https://developer.apple.com/documentation/webkit/wkwebview), [SecKeyVerifySignature](https://developer.apple.com/documentation/security/1643715-seckeyverifysignature)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), [SwiftSoup](https://github.com/scinfu/SwiftSoup)
- [SwiftOpenUI](https://github.com/codelynx/SwiftOpenUI) (read from a local clone; GTK4 renderer in `Sources/Backend/GTK4/Rendering/GTKRenderer.swift`)
- [swift-crypto](https://github.com/apple/swift-crypto)

## Licence

AGPL-3.0-or-later — see [LICENSE](LICENSE). The AGPL rather than the GPL because SwiftOpenUI
has a web renderer, so a build of this can be served over a network, which is exactly what
section 13 covers.
