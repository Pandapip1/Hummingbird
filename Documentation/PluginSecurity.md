# Plugin security: threat model and containment

Hummingbird runs third-party Grayjay-compatible plugins: JavaScript in JavaScriptCore, plus a config that
declares hosts, packages and sign-in. The design assumes a plugin can be fully hostile. **If a malicious
plugin is loaded, enabled and run in any context, the damage it can do to availability, confidentiality and
integrity must be as small as possible.**

This document covers what is implemented, what is designed but not built yet (marked **Not implemented**),
and what risk remains on each platform.

## 1. Attacker

| Attacker | What they control |
|---|---|
| Malicious plugin | The whole script, and the whole config: `id`, `allowUrls`, `packages`, `allowEval`, `authentication`, `captcha`, settings and their defaults. |
| Compromised update | A new version of a plugin the user trusts, possibly signed with a different key or not signed at all. |
| Synced plugin | A `SyncedPlugin` record from another of the user's devices, or from a compromised sync journal (PDS or LAN peer). The record names a `sourceURL`, the enabled state and settings. |
| Hostile server | Any server on a domain the plugin allow-lists. It controls responses, redirects and `Set-Cookie`. |
| Attacker-controlled DNS | The plugin's own domains can resolve to any address and change answer at any time (rebinding). |

**Out of scope:** a compromised OS or app binary, and malicious code inside the app's own dependencies.

## 2. Assets

- **Other plugins' secrets:** sign-in cookies and headers, and captcha tokens (`SourceAuth` in the credential store, held in memory by `PluginManager`).
- **The user's profile:** library, history, playlists and subscriptions.
- **Sync material:** the sync journal, the AppSync identity, and LAN peer identity keys.
- **Keychain items and files**, inside the app sandbox and outside it.
- **Network services the plugin should not reach:**
  - LAN, loopback and tailnet services.
  - The app's own loopback servers: `PluginMediaProxy` and `LocalMediaServer` on 127.0.0.1.
  - Cloud instance metadata endpoints.
- **Availability:** the main thread, other plugins, battery, memory, and the network budget.
- **UI integrity:** system-looking messages, other plugins' identity, links that leave the app, and the address bar, which must open URLs only through plugins.
- **Other web sessions:** the OAuth and sign-in web views, and system cookies.

## 3. Entry points (everything a plugin can touch)

| Entry | Notes |
|---|---|
| `__hostCall` (the only native door, `PluginWorker.handleHostCall`) | `log`, `toast`, `isLoggedIn`, `hasPackage`, `unsupportedFeature`, `sleep`, `http`, `browser.*` (`initialize`, `addScriptOnLoad`, `load`, `waitTillLoaded`, `run`, `runWithReturn`), `setTimeout`, `dom.parse/get/call/release`, `util.*` (base64, md5, sha256, uuid) |
| HTTP | Every request and every redirect hop. Cookie jars per client. Request modifiers. |
| Plugin browser (`Browser` package) | A hidden WebKit page. It navigates, loads subresources and calls back into the plugin. |
| Sign-in and captcha sheets | `WebAuthSpec` and `WebAuthView`. The captcha URL can come from the plugin at run time (`CaptchaRequiredException`). |
| Returned data | Items, details, comments, channels, descriptions, thumbnails, media and subtitle URLs, `unlockUrl`, channel links, error messages, toasts. |
| Request modifiers | `modifyRequest`, which sits in front of every media range request. |
| State | `saveState` / `enable(savedState)`, `reloadData` (`ReloadRequiredException`), settings, packages, timers, promises. |
| Install, update and sync | Config and script downloads, the signature, ID collisions, synced records. |
| Install-time dry run | `checkScript` evaluates the script's top level before the user accepts the preview. It is as contained as any run: no sign-in, no approvals. |

## 4. What plugins legitimately need (Grayjay) vs what we allow

Grayjay's model, which we stay compatible with:

- Each plugin runs in its own JS engine.
- Plugin HTTP is restricted to the config's `allowUrls`, or "everywhere".
- `eval` is opt-in (`allowEval`).
- Optional packages: Http, DOMParser, Utilities, Browser.
- RSA `scriptSignature` / `scriptPublicKey`. Unsigned plugins work, with a warning; updates must match the original key.
- Sign-in and captcha through a web view that captures named cookies and headers.

Where Hummingbird is **stricter** than Grayjay:

- Non-public destinations are denied by default, even for "everywhere" or wildcard entries:
  - loopback, LAN, CGNAT/Tailscale, link-local, ULA and similar ranges;
  - DNS answers are checked, not just names;
  - cloud metadata is never reachable.
- Call deadlines, a fresh context per call, and bounds on output, HTTP and timers.
- Outputs are contained before the UI sees them. HTML is never rendered.
- The plugin browser and sign-in sheets are held to the allow-list.
- Key pinning also covers ID takeover: a different publisher's copy of a plugin does not inherit sign-in, settings or approvals.
- Synced installs that carry warnings need confirmation on this device.

## 5. Mitigations

Tests are in `Tests/HummingbirdKitTests/`. Hostile end-to-end plugins are in `MaliciousPluginTests.swift`.

### 5.1 Availability

| Threat | Mitigation | Where | Tests |
|---|---|---|---|
| A call blocks the plugin or the app, or calls share state | **One fresh context per call (task 34).** Every top-level call gets a JS context of its own, with its own serial queue: prelude, plugin script and `enable` with the host-held config, settings and saved state, then the call. No other call ever uses it. Only that call's continuations (its pagers, details, modifiers, trackers, promises; routed by the serial in their handles) reach it later, and it ends with its last handle (`releaseHandle`, pager release), after `sessionIdleLifetime` idle, or past `maximumRetainedSessions` (least recently used). Saved state is taken after each call and handed to the next (explicit, host-held). Calls run in parallel; nothing runs on the main actor. **Script caching:** fresh contexts are created in pooled JavaScript virtual machines (`PluginLimits.maximumIdleMachines` per plugin; `JSMachine`), whose code cache spares compiling the plugin again; a machine serves one call at a time, and one whose call threw, missed its deadline or was stopped is dropped, never pooled. A context in a reused machine still has a global object of its own. | `PluginRuntime` (`freshWorker`, `finish`, `retain`), `PluginWorker` | `PluginRuntimeIsolationTests`, `MaliciousPluginTests` (globals planted by one call are never seen by another; concurrent calls), `PluginMachinePoolTests` (the same in pooled machines; failed and stopped calls' machines dropped) |
| State leaks between contexts | Workers share only explicitly passed state: config, settings, saved state, reload data, and the plugin's `HostHTTP` (its cookie jars plus auth/captcha). JS globals are per context. | `PluginRuntime.sharedHTTP`, `PluginWorker.startLocked` | `MaliciousPluginTests` |
| Handles reach the wrong context | Handles are `serial << 32 \| local` (`__jb.setHandleBase`). Follow-up calls are routed to the worker that made the handle. A handle from a retired worker fails with "session has ended". | `PluginWorker.handleShift`, `PluginRuntime.worker(forHandle:)` | `RuntimeTests` |
| Infinite loop or slow call | Every call has a deadline: `callTimeout` 60 s, plus `enableTimeout` 90 s on a fresh context; request modifiers get 10 s. On a miss the caller gets `PluginError.timeout` at once. A worker that missed while *running* is **abandoned**: taken out of service, and its host calls fail fast from then on (`http` errors, `sleep` returns, timers and browser calls ignored). Its context closes when the script returns. Timeouts are injectable for tests (`PluginRuntime.Timeouts`). | `PluginWorker.perform`, `PluginRuntime.abandon` | `MaliciousPluginTests` |
| Repeated hangs | When `maximumHungWorkers` (2) abandoned workers are still running, the plugin is suspended (`PluginError.unresponsive`, shown with retry). `PluginManager.runtime(for:)` builds a fresh runtime up to `maximumUnresponsiveRestarts` (3) times per session. After that the source stays failed until it is turned off and on. | `PluginRuntime`, `PluginManager` | `MaliciousPluginTests` |
| Output bombs | Result JSON at most 32 MB, checked before parsing. At most 500 items per page. A pager stops after 200 pages whatever `hasMore` says. Strings and lists are clamped. Error payloads are clamped (`Payload.bounded`). | `PluginWorker.unwrap`, `PluginPager`, `PluginOutput` | `PluginOutputContainmentTests`, `MaliciousPluginTests` |
| Host-side memory the script can grow | DOM: 16 MB input and 200k nodes. Utilities: 64 MB input. 256 pending timers per context, each at most 1 h. `sleep` at most 30 s and never past the deadline. At most 64 HTTP clients and 512 cookies per jar. | `HostPackages.swift`, `PluginWorker`, `HostHTTP` | `MaliciousPluginTests` |
| Network floods | Batches hold at most 64 requests. 12 requests in flight per plugin. Token bucket of 30 req/s with a burst of 120. Request body at most 16 MB, response body at most 48 MB (cancelled mid-stream). At most 64 headers, 16 KB each. Everything is bounded by the call deadline. The egress proxy allows 24 connections. | `HostHTTP`, `PluginEgressProxy` | `HostHTTPRateLimitTests`, `MaliciousPluginTests` |
| Log and toast floods | Logs: 200 lines/s per context, 8 KB per line, redacted (`LogRedaction`), debug level. Toasts: 6 per minute per plugin, 200 characters. | `PluginWorker`, `PluginToastLimiter` | `PluginOutputContainmentTests` |

### 5.2 Confidentiality

| Threat | Mitigation | Where | Tests |
|---|---|---|---|
| Reaching unapproved hosts | `PluginNetworkPolicy` applies to every request and every redirect hop. Only http(s). The allow-list supports `host`, `host:port`, `.domain`, `*.domain`, full URLs and `everywhere`. | `PluginNetworkPolicy.check`, `HostHTTP.mayReach`, `TaskGuard` | `MaliciousPluginTests` |
| SSRF into LAN, loopback, tailnet, metadata | One central classifier, `AddressClassifier`, judges the **resolved** address.<br>Non-public ranges:<br>• IPv4: 0/8, 10/8, 100.64/10 (CGNAT, Tailscale), 127/8, 169.254/16, 172.16/12, 192.0.0/24, 192.0.2/24, 192.168/16, 198.18/15, 198.51.100/24, 203.0.113/24, 224/4, 240/4, broadcast.<br>• IPv6: ::, ::1, fc00::/7 (Tailscale fd7a:115c:a1e0::/48), fe80::/10, fec0::/10, ff00::/8, 2001:db8::/32, 100::/64, 64:ff9b:1::/48, anything outside 2000::/3.<br>• Embedded IPv4 is checked for ::ffff:0:0/96, ::/96, 64:ff9b::/96, 6to4 2002::/16 and Teredo.<br>Metadata (169.254.169.254, 169.254.170.2, 100.100.100.200, fd00:ec2::254) is **always** refused, even if a name answers with it among other addresses. | `NetworkAddressScope.swift` | `NetworkAddressScopeTests` |
| Unapproved local access | Exact-host approvals (`LocalHostApproval`), bound to the addresses or CIDRs the host resolved to when the user approved it. A later answer outside them is refused with "now points to X… approve the new address". Wildcards and "everywhere" never qualify. Approvals are made in three places:<br>• the install preview ("This source connects to your local network: host:port → addr"; installing approves the addresses shown);<br>• the source's settings: Check / Approve / Revoke, or an address or CIDR the user types for a declared host;<br>• never through sync (`InstalledPlugin.localHostApprovals`).<br>The system local-network permission gate still applies for LAN scopes. | `PluginManager` (approvals), `SourcesViews.LocalNetworkApprovalsSection` | `MaliciousPluginTests`, `HostHTTPRateLimitTests` |
| DNS rebinding / TOCTOU | **Egress proxy.** Each runtime has a loopback HTTP CONNECT proxy. Per connection it resolves once, checks that address, and connects to exactly it. TLS stays end to end (SNI and certificates unchanged). Plugin `URLSession`s and the plugin browser's `WKWebsiteDataStore` use it through Network.framework `ProxyConfiguration` with `allowFailover = false`. If it cannot start, requests fail closed. | `PluginEgressProxy` | `PluginEgressProxyTests` |
| Ambient credentials | Plugin sessions are ephemeral with no cookie storage, cache or credential storage. Every auth challenge except server trust gets `.rejectProtectionSpace`, so no HTTP auth, client certificates or proxy credentials are offered. A plugin cannot set `Host`, `Content-Length`, `Transfer-Encoding`, `Proxy-*`, `Connection` or similar headers, or values containing CR/LF/NUL. | `HostHTTP.containedConfiguration`, `TaskGuard` | `MaliciousPluginTests` |
| Other plugins' secrets | One runtime per plugin, with its own `HostHTTP` cookie jars and only its own `SourceAuth`. Auth cookies and headers go only to matching domains. `Set-Cookie` and other non-whitelisted response headers are hidden unless the plugin is signed in or has `allowAllHttpHeaderAccess` (which warns at install). | `HostHTTP` | `MaliciousPluginTests` |
| ID takeover of another plugin's sign-in | `PluginManager.sameSigner`: the same signing key, or for unsigned plugins the same source. Anything else that installs, updates or sync-replaces under an existing ID has its credentials deleted (`forget`), and does not inherit settings or approvals. Plugin IDs must match `^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`. | `PluginManager.commit`, `confirmSyncedReplacement` | `MaliciousPluginTests` |
| Plugin browser exfiltration or navigation | Fresh `.nonPersistent()` store, proxied. Navigation in every frame is restricted to allow-listed http(s), plus `about:blank`/`srcdoc` and `data:`. Non-public literals and local names need an approval. Downloads, undisplayable responses and new windows are refused. A per-plugin `WKContentRuleList` blocks all subresources outside the allow-list, and always blocks non-public literals and local names; if the rules don't compile, the page doesn't load. Scripts are limited to 4 MB, on-load scripts to 64, callbacks to 16 MB. | `PluginBrowserPolicy`, `PluginBrowserPackage` | `PluginWebContainmentTests` |
| Sign-in and captcha sheets | Fresh non-persistent store per sheet. Navigation is limited to http(s) within `allowedDomains`, the allow-list hosts (never "everywhere"), and the start and completion hosts. A plugin-supplied captcha URL must be within its own hosts. Only the configured cookies and headers are exported, and only for the sheet's own domains. | `WebAuthSpec`, `WebAuthView` | `PluginWebContainmentTests`, `WebAuthSpecTests` |
| Files, keychain, sync keys | No host call exposes files, the keychain, the profile or sync. `file:` and other schemes are refused everywhere. The synced record type (`SyncedPlugin`) structurally excludes credentials. | — | `MaliciousPluginTests` |
| Secrets in logs | `PluginLog` accepts only `RedactedText`. Plugin IDs in log lines go through `pluginLogID`, which strips control and bidi characters. | `PluginLog.swift`, `PluginRuntime.swift` | `PluginLogRedactionTests` |
| Referenced content (subtitles, media) | `PluginRuntime.contentSession()` / `fetchReferenced(_:)`: a contained session through a proxy with `policy.forReferencedContent` (any public host; non-public addresses only when approved). Subtitles use it now; the old `URLSession.shared` sent the app's cookies. | `PluginRuntime` | `MaliciousPluginTests` |

### 5.3 Integrity

| Threat | Mitigation | Where | Tests |
|---|---|---|---|
| Results as code or markup | Each decoded type conforms to `PluginOutput` and is contained against the producing plugin (`PluginOutputContext`). HTML becomes plain text (`PluginText.plain`: script and style contents dropped, entities decoded once, bidi overrides U+202A–E and U+2066–9 stripped). | `PluginOutput.swift`, `Models/*.swift` | `PluginOutputContainmentTests` |
| Spoofing another plugin | `platformID.pluginId` (and author and comment ids) is overwritten with the producing plugin's ID. | `PlatformID.contain` | `PluginOutputContainmentTests` |
| Dangerous URLs | Images: http(s), no userinfo, not non-public by form unless approved (no allow-list; CDNs vary). Media: http(s) only; where they may connect is decided at fetch time. Links opened outside the app (`unlockUrl`, channel links, share URLs) must pass `policy.mayReference`: allow-listed, http(s), never local. Content URLs are opaque references handed back to plugins; the address bar resolves URLs through plugins only. | `PluginOutputContext` | `PluginOutputContainmentTests` |
| Spoofing system UI | Toasts are `PluginToast(pluginName:message:)`, single line, bounded and shown attributed to the plugin (`ToastBanner`). | `RootView.swift` | `PluginOutputContainmentTests` |
| Hostile request modifier | `PluginRuntime.modifyRequest(handle:url:headers:)` returns a `ContainedRequest`. The URL must be http(s) with no userinfo, on the original host or the allow-list, and not a non-public literal or local name unless approved. At most 32 headers, token names only, no transport headers, no CR/LF, at most 8 KB each. Time-limited. `PlayerModel` uses only this. | `PluginRuntime.swift`, `PlayerModel.swift` | `MaliciousPluginTests` |
| Writing other state | There is no host API for settings, saved state, library or profile. A plugin's `saveState` is kept only for itself, at most 1 MB. Library changes happen only through explicit user actions (Import buttons). | — | `MaliciousPluginTests` |
| Silent installs via sync | A *new* synced plugin that asks for more than ordinary access (eval, everywhere, all-header access) or names local-network hosts waits for "Install / Don't Install" on this device (`needsConfirmationWhenSynced`). An unsigned plugin that asks for nothing more installs as on the other device and runs contained. Replacing this device's copy from another source always asks. Signature checks run as for a manual install, and an invalid signature fails. | `PluginManager.applySynced`, `SourcesViews.SyncInstallRow` | `MaliciousPluginTests.testSyncedPluginsAskingForMoreWaitForTheUser` |

## 6. Compile-time enforcement

| Mistake | What makes it a compile error |
|---|---|
| Sending plugin HTTP to an unchecked URL | `AuthorizedRequest` has a `fileprivate` init. Only `PluginNetworkPolicy.authorize` makes one, and `HostHTTP` sends only `AuthorizedRequest.urlRequest`. |
| Showing plugin data without containment | `PluginRuntime.decode` / `decodeOffMain`, `call`, `pager`, `handlePager` and `PluginPager` require `T: PluginOutput`. `callRaw` and `callHandle` return `PluginResult`, not `Data`. A new model type must say how it is contained. |
| Opening a plugin string as a link | `ExternalURLLink` takes `NavigableURL`, which is built only by `navigableURL(_:)` or `init?(appOwned: StaticString)`. `ContentItem.unlockURL` and `ChannelInfo.links` are `NavigableURL`, set only by `contain`. |
| Unattributed toast | `PluginManager.toast` is `PluginToast?`, which requires a plugin name. |
| Applying a modifier's raw output | `ContainedRequest` is the only modifier result. The old private decoding in `PlayerModel` is gone. |

## 7. Stopping runaway scripts: process isolation and the engine time limit

One API, `PluginExecutionLimits` (Sources/PluginEngine), gives every build the strongest enforcement it has:

| Build / platform | Enforcement | How |
|---|---|---|
| macOS app (Xcode build) | `.processTermination` | Each plugin's contexts run in its own instance of the `PluginHost` XPC service (Apps/PluginHostXPC: app sandbox, no other entitlement, so no network and no user files; `_MultipleInstances`, one process per plugin). At a deadline the app kills that process (`xpc_connection_get_pid` + SIGKILL). |
| Linux (GTK) | `.processTermination` | The app re-runs its own binary with `--plugin-host` before any GTK/WebKit/app state exists; the child closes every inherited descriptor, sets no-new-privs and a seccomp filter that refuses sockets, exec, ptrace and file creation/writing/renaming/removal (EPERM). Killed with SIGKILL. **Not run on Linux yet** (no Linux build here). |
| Direct-distribution builds, in-process (iOS/tvOS/visionOS sideloads, xtool) | `.engineTimeLimit` | JavaScriptCore's `JSContextGroupSetExecutionTimeLimit` stops the script at the call's deadline with an uncatchable termination; its context returns. Not public API: compiled only without `APP_STORE`. |
| App Store iOS / tvOS / visionOS | `.abandonment` | No process isolation (no process spawning) and no non-public API: a stuck context is abandoned (host calls fail fast) and keeps one thread busy until the script returns; bounded by `maximumHungWorkers` and `maximumUnresponsiveRestarts`. |

- **Protocol.** Host processes speak length-prefixed JSON frames (`PluginHostMessage`, `PluginHostChannel`): create/evaluate/close a context, and `hostCall`/`hostReply`. The host process holds JavaScript contexts and nothing else; every capability (HTTP through `HostHTTP` and the egress proxy, DOM, logs, timers, the browser package) stays in the app and is reached only by answered `hostCall` messages. The evaluating worker thread in the app answers its context's host calls, so they run exactly where an in-process context's would. Each hosted context lives on its own thread in the host, owning it outright.
- **Helper processes are SwiftOpenUI's.** Starting, connecting to and killing the host process, and confining it (the Linux seccomp filter), live in SwiftOpenUI `PlatformSupport` behind one API, `HelperProcess` (`Launcher.app` / `Launcher.executable`, `confineCurrentProcess`); PluginEngine has no platform branches of its own for it (`HelperPluginHostLauncher`, `PluginExecutionLimits.installPlatformIsolation`).
- **Kill semantics.** Killing a plugin's host ends every context of that plugin (their calls fail and can be retried); the next call starts a new process. Nothing keeps running, so killed loops never pile up into a suspended plugin.
- **App Store gating.** `Apps/AppManifest.swift` declares the distributions; the generated app target sets `SWIFT_ACTIVE_COMPILATION_CONDITIONS` from `HUMMINGBIRD_DISTRIBUTION` (`direct` by default; `appstore` adds `APP_STORE`). The time limit lives in a header-only C module (`CJSCExecutionLimit`, static inline functions) that only `Apps/iOS/DirectDistribution.swift` imports, under `#if !APP_STORE`: an App Store build has no reference to the symbol at all. `scripts/check-app-store-symbols` builds both distributions and checks every Mach-O file in the app with `nm`.
- Tests: `PluginProcessIsolationTests.swift` (host round trip, runaway killed at the deadline without suspending the plugin, containment unchanged in a host process, the engine time limit in-process, enforcement reporting).
- **Measurements** (opt-in): `PluginCallCostBenchmarks` (`HUMMINGBIRD_BENCHMARK=1`, `HUMMINGBIRD_YOUTUBE_PLUGIN_DIR` for the real plugin) compares a fresh JavaScriptCore context per call in-process, in a host process, and a fresh WKContentWorld in a hidden page; script caching in a reused virtual machine; WebKit realm containment and a hung realm's recovery. `scripts/measure-background-calls` (Debug iOS Simulator build, `Apps/iOS/BackgroundCallBench.swift`) checks whether each kind of call completes while the app plays audio in the background. Findings that bear on the design: WKContentWorlds of one page share its DOM, localStorage and sessionStorage, so a fresh world is not a fresh realm in the sense above (only a fresh page is); a page reaches the network directly unless content rules block everything but the host bridge; a hung WebContent process is not ended by dropping its web view (it must be killed).

## 8. Residual risks

| Risk | macOS | iOS/iPadOS | tvOS | visionOS | Linux GTK |
|---|---|---|---|---|---|
| **Pure CPU loop.** Stopped by killing the plugin's host process (macOS, Linux) or by JavaScriptCore's time limit (direct builds). App Store iOS/tvOS/visionOS builds can do neither: the loop keeps one thread busy until it returns, bounded per plugin by `maximumHungWorkers` × (`maximumUnresponsiveRestarts` + 1). | no (killed) | App Store: yes; direct: no | App Store: yes; direct: no | App Store: yes; direct: no | no (killed) |
| **Memory bomb.** No per-context heap cap. In a host process (macOS, Linux) it takes down only that plugin's process; in-process (iOS, tvOS, visionOS) it can cause jetsam of the whole app. | plugin only | yes | yes | yes | plugin only |
| **DNS TOCTOU in plugin HTTP.** swift-corelibs `URLSession` ignores proxy settings, so on Linux the check happens before the connection only. The DNS answer can change in between, and a name answering with both public and unapproved private addresses is refused outright, but a fast-flipping answer can still differ between check and connect. | — | — | — | — | yes |
| **Web views unproxied.** The GTK WebKit shim has no proxy or content-rule API, and the plugin browser uses WKWebView, so on GTK neither pinning nor content rules exist. | — | — | n/a (no WebKit) | — | yes |
| **Sign-in and captcha sheets not proxied.** Their navigation is domain-restricted, but a public sign-in host resolving to a private address isn't caught. | yes | yes | n/a | yes | yes |

Further risks on all platforms:

- **Allow-listed domains can point anywhere public.** The attacker controls their DNS, and "everywhere" plugins can reach any public host. Confidentiality relies on no ambient credentials and on per-plugin jars.
- **Media and VOD downloads** (playback-owned `TrackDownloader.sharedSession`) don't use `runtime.contentSession()` yet. The session is cookieless but not proxied, so a media URL resolving to a private address is fetched. **Recommended:** route them through `contentSession()`.
- **Thumbnails** are checked by URL form only: no DNS check and no pinning in the image loader.
- **Synced library records** (`ContentItem(saved:)`) are rebuilt from sync, not from a plugin, and are not re-contained.
- **`data:` documents** are allowed in the plugin browser. Their subresources still go through the rules and the proxy.
- **The install dry run** executes the script's top level before consent. It is contained, but it does run, and it can make allow-listed HTTP requests.
- **Typed approvals** are limited to non-public addresses and at most a /16 (IPv4) or /48 (IPv6); metadata is always refused.
- **The local egress proxy** accepts CONNECT from any local process (it binds 127.0.0.1 without auth). This only reaches what the plugin's policy allows. Plugins themselves can't reach it without an approval for its exact port.
- **Pre-existing installed plugins** with IDs that fail the new validation are not re-validated.
- **Address literals and system-local names skip the proxy.** Network.framework connects loopback literals (and may connect `localhost`/`.local`) directly. Literals need no DNS, so they cannot be rebound; they are reachable only with an exact approval (checked before connecting, `PluginNetworkPolicy.precheck`). An approved `.local` name is resolved by the system at connect time, so for those names alone the address binding is checked before the connection, not pinned.
- **A compromised sync journal** can still install an unsigned, otherwise-unprivileged plugin without asking. It runs contained (its allow-listed public hosts only, no LAN, no other plugin's credentials).
- **Timers and browser callbacks** run under the same watchdog as calls; a runaway one takes its context out of service like a stuck call.

## 9. Coordination

**Playback agent:**
- Use `PluginRuntime.modifyRequest(handle:url:headers:) -> ContainedRequest` for every modifier call. Use `contentSession()` for media and VOD transports, and `fetchReferenced(_:)` for one-off files (subtitles).
- Decode details only through `PluginRuntime.decodeOffMain(_:from: PluginResult)`.
- Handles are now 64-bit (`serial << 32`). Don't narrow them.

**Age-gating / curated-DB agent:**
- Hook into `PluginManager.prepareInstall` (the preview carries `warnings` and `localHosts`) and `commit`.
- Synced installs go through `applySynced` → `SyncInstall.Confirmation` (`replacing == ""` for new installs).
- Curated-DB key pins can feed `sameSigner`.
