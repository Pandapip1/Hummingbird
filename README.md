# Jaybird

A SwiftUI iOS app that loads and runs [Grayjay](https://grayjay.app)-style plugins: JavaScript sources that expose
home feeds, search, channels, video details and playback streams.

> **Status: written without a compiler.** The development environment had no Swift toolchain or Xcode, so the Swift code
> has never been built or run. The JavaScript plugin runtime (`prelude.js`) is tested under Node (`node Tests/prelude.test.js`,
> and `node Tests/load-real-plugin.test.js <plugin-dir>`). The XCTest suites in `JaybirdTests/` are also unrun.
> Expect to fix some compile errors on first build.

## Build

```sh
brew install xcodegen
xcodegen generate        # creates Jaybird.xcodeproj from project.yml
open Jaybird.xcodeproj   # iOS 17+, SwiftSoup is fetched through Swift Package Manager
```

## How it works

| Piece | Where |
|---|---|
| Plugin runtime (globals plugins expect: `Type`, `PlatformVideo`, pagers, exceptions, `http`, ...) | `Jaybird/Plugin/Resources/prelude.js` |
| One JavaScriptCore context per plugin on a serial queue; HTTP, DOMParser and Utilities packages implemented natively | `Jaybird/Plugin/` |
| Install flow with RSA-SHA512 script signature check and a validation dry run | `PluginManager.swift`, `ScriptSignature.swift` |
| `allowUrls` enforcement (including on redirects), per-plugin cookie jars, Keychain-stored login | `HostHTTP.swift`, `SourceAuth.swift` |
| WKWebView login and captcha capture | `Views/WebAuthView.swift` |
| AVPlayer playback (HLS and MP4; separate audio joined with `AVMutableComposition`), subtitles, playback trackers | `Jaybird/Player/` |
| Subscriptions, playlists, watch later, history, JSON export/import, merged subscription feed | `Services/`, `Models/Library.swift` |

## Not supported

WebM/VP9/Opus streams, DASH and Widevine (AVPlayer cannot play them), WebSockets, the JSDOM/Browser packages,
subscription groups, background refresh and live chat. `HttpImp` is an alias of the normal HTTP client. Whether
redirect handling matches the Android app exactly is unverified.

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
