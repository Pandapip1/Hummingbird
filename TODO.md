# TODO

Running list of known problems. Confirmed causes say so; leads say they are leads.

## Product roadmap

The target is a dependable multi-source video client with roughly Grayjay-level
day-to-day usefulness, while retaining Hummingbird's own UI and architecture.
Polycentric identity, comments and other Polycentric-backed social features are
explicitly out of scope.

### Core usability

- [ ] Persist fetched feeds, details, thumbnails and playback progress in a local
      database. Render cached data immediately and refresh it in the background.
- [ ] Add a persistent play queue with play-next, reorder, remove, repeat and
      shuffle controls. Restore the queue and current item after relaunch.
- [ ] Finish the custom player: independent video/audio/subtitle selection,
      request headers, quality selection, playback speed, subtitle styling,
      fullscreen and platform-appropriate picture in picture.
- [ ] Bring the GStreamer player controls to feature and behavior parity with
      the iOS controls, including every transport, track, subtitle, speed,
      fullscreen and picture-in-picture action available on Apple platforms.
- [ ] Add downloads for offline playback, including progress, pause/resume,
      storage limits and cleanup.
- [ ] Make source installation, login, captcha and failure recovery usable on
      every supported platform, with clear per-source health/status reporting.
- [ ] Add a manual update button to each plugin detail page, with visible
      checking, success and failure states.

### Library and discovery

- [ ] Add subscription groups and filters, chronological/unwatched views, and
      background refresh with notifications.
- [ ] Add playlist import/export, remote playlist browsing, queue-to-playlist,
      and reliable reorder/delete controls on GTK.
- [ ] Add search history, suggestions, filters, and a unified URL/open flow.
- [ ] Add per-channel notification and subscription settings plus bulk import,
      export and migration tools.
- [ ] Add comments and live chat where a source exposes them. These use source
      APIs only; no Polycentric integration.

### Platform completeness

- [ ] Build and exercise the Apple target, then finish AVPlayer controls and PiP.
- [ ] Create and validate an Android entry point and media backend.
- [ ] Add keyboard shortcuts, media keys, accessibility labels/focus order, and
      responsive desktop layouts.
- [ ] Package a self-contained Linux application with icons, codecs and runtime
      dependencies available outside the development shell.

## GTK/Linux UI

- [x] **Video playback no longer crashes or hangs.** With the debug source, the
      aspect-ratio fix and a correct dev-shell environment, it plays on both cairo
      and GPU. So the earlier catastrophes were a combination of: running outside the
      dev shell (no playbin3 → fatal abort), the unbounded black player
      (`.aspectRatio` was a no-op), and content variation — not an Asahi driver bug.
      The later direct GStreamer surface, pipeline-clock gating and sample-driven
      presentation fixed black frames, runaway playback and choppy cadence.

- [x] **Playing a video popped back to Home after ~1s.** Fixed by scoping
      GTK composite observation to body evaluation, ending it before rendering
      descendants. Previously every ancestor subscribed to descendant reads:
      writing history rebuilt the whole tab tree, destroyed the player and lost
      Home's unbound navigation. The earlier cross-tab theory was unsupported:
      the "HomeView" debug log was actually in SearchView. Explicit Home path
      binding did not solve it. Neither the navigation-context experiment nor
      the global onDisappear suppression was needed; both were removed.
      Verified in the app under Xvfb: full 10s playback, history writes at ~1.5s
      and ~6.6s, detail remains visible. Regression test fails before the fix and
      passes after it, including repeated changes. Bindable projections register
      dependencies during body evaluation so controls keep external updates.
      Committed/pushed: SwiftOpenUI 58a5f01, Hummingbird 4ccecfb. Main 22/22
      tests pass; fork 783 tests has only the two known layout failures.

- [x] **Running the binary outside the dev shell aborts on playback** with
      `GstPlay: 'playbin3' element not found`, because GStreamer finds no plugins
      without `GST_PLUGIN_SYSTEM_PATH_1_0`. Confirmed: playbin3 *is* in our plugin
      set (libgstplayback.so, gst-plugins-base) and the variable is set inside
      `nix develop`, so `hb-run` and the packaged `nix run .` (wrapped) are fine —
      only a bare `.build/...` invocation from an ordinary shell fails.
      GStreamer treats it as fatal and aborts, so the symptom is an opaque crash.
      Fixed: the GTK backend probes for playbin3 before opening media and reports
      a recoverable player error. Verified with an empty GStreamer registry;
      SwiftOpenUI 6358c06 and Hummingbird 54b92f9.

- [x] **`gtk_editable_select_region: assertion 'GTK_IS_EDITABLE (editable)' failed`**
      at startup. Something calls an editable-only API on a widget that is not a
      GtkEditable — likely the TextField/search field path. Focus restoration now
      verifies the matched widget is still GtkEditable before calling the API.
      Committed/pushed in SwiftOpenUI 9df66a6 and Hummingbird 4364b50; GTK focus
      tests pass (11/11).


- [x] **Feed titles and metadata use the available row width.** Custom GTK
      `NavigationLink` labels now preserve a child's horizontal expansion, and the
      feed's text column explicitly fills the remaining width. This prevents titles
      from collapsing to one-character ellipses. Verified in Hummingbird itself
      under Xvfb with a two-line-capable title and metadata row.

- [x] **Feed thumbnails load and retain a 16:9 card layout.** The debug source now
      exposes a deterministic SVG thumbnail, with a plugin regression assertion.
      An isolated Hummingbird run under Xvfb fetched and displayed it at full card
      width with the duration badge, title and metadata intact.

- [ ] **Log noise: `VK_SUBOPTIMAL_KHR` on every tab/menu transition.** Benign — the
      swapchain is being recreated for a redraw and GTK handles it — but it floods
      the log during normal use, like the CSS parser warnings did.


- [x] **The plugin settings page needs a scrollbar** — GTK Form now places its
      natural-height content in a vertically scrolling GtkScrolledWindow, so long
      settings remain reachable. Build and 22/22 Hummingbird tests pass.


- [x] **Tab bar inset** — fixed (`49a4cc3`) using GTK's own convention: the `.toolbar`
      style class (`padding: 4px; border-spacing: 4px`), not the 6px I first picked by
      eye. px is the right unit — GTK px are logical and scale — but the value belongs
      in the theme. `.toolbar` also sets `background-color: $bg_color`, GTK's colour
      rather than the painted window's, so that one declaration is overridden.
      Measured 4px in from the border: tab button before, window background after.
- [ ] **(Deferred — agreed direction, not now.) Stop painting the window from the
      declared palette and let GTK's colours win everywhere**, keeping the declared
      palette only for surfaces we draw ourselves (materials/cards). Today we paint
      the window 38,37,37 from `window_bg_color` while every GTK widget uses GTK's
      own family (window #353535, toolbar and buttons from that), so each widget that
      paints itself clashes and gets overridden one at a time — the tab bar is the
      first instance. Gavin: do this eventually, other things first.
      the start, not introduced by any of this work. Seen directly in a headless
      capture of the Home feed. Looks like the label is being measured or allocated at
      a tiny width and then ellipsized, rather than a data problem.


- [x] **Rows are separate cards again** — fixed (`d1fbb29`), confirmed in a headless
      capture of Home rather than assumed.
- [ ] **The resize on clicking + still happens**, so valign START was not the whole
      story. The regression test does prove the list box now hugs (480pt → one row's
      worth in an 800pt window), so whatever changes on rebuild is something else.
      Next suspicion: the first render may run before the environment carries the
      theme palette, so the first pass paints/sizes from the no-palette branch and the
      rebuild takes the palette branch. Check whether `getCurrentEnvironment()
      .themePalette` is non-nil during the very first body build, not just at window
      creation. Needs a screenshot of the current state to confirm the direction.


- [x] **Sources list card stretched to the viewport** — fixed (`22b4239`). Not the row
      height, as the before/after screenshots showed: a GtkListBox fills whatever its
      viewport allocates, so inside a stretched scrolled window the rounded card
      covered everything until an unrelated rebuild shrank it. valign START makes it
      hug; the card is now drawn in cardBackground (matching SwiftUI inset-grouped and
      libadwaita .boxed-list). Regression test asserts allocated height in an 800pt
      window: 480pt before, one row after.
      `background: @view_bg_color` and installed it at `PRIORITY_USER`, the same
      priority as the per-widget background the List sets from the palette, so which
      won depended on provider order. Home looked fine only because its rows paint
      their own backgrounds over the top; Library's plain rows let it through.

- [x] **Window background painted from the palette** (`cb3bea5`). Measured cause:
      between rows (our List background) was 38,37,37 = COSMIC's declared
      `window_bg_color`, while GTK's real window was 53,53,53 (`#353535`). Those
      `@define-color` names are a **libadwaita** convention that plain GTK4 never
      paints with, so sampling them gave colours GTK does not use. The window is now
      painted from the same palette, so window, raised surfaces and text agree, and
      `.scrollContentBackground(.hidden)` is honoured rather than dangling unused.
      Needs your eyes to confirm it actually looks right.
      NavStack+Group+List, so none of those drop it. Remaining suspects are TabView's GtkStack
      and the window/scene root. Note both of my attempts so far were wrong: removing
      `GTKViewHost.init`'s explicit `vexpand = 0` was a no-op (the post-build code overwrote it
      anyway), and the `compute_expand` change, while more correct in principle, did not fix
      the symptom — the three tests I wrote for it pass with and without it, so they are
      vacuous as regression tests and should be replaced once the real cause is found.


      So the List is painting `window_bg_color` where the rows should carry it, and the rows are
      getting the surface meant for the backdrop. Re-check which of the app's row views sets a
      material/card background against what the List itself now paints (`60aa8ea`).

- [x] **Codepoints read from the font** — done (`748769b`). A bounds-checked
      TrueType reader (sfnt directory, cmap 4/12, GSUB ligature lookups incl. type 7
      extensions, coverage 1/2); resolution runs forward so the non-invertible
      mapping does not matter. All 74 mapped names resolve, inside the PUA, and each
      draws the same glyph as the upstream .codepoints file — cross-checked against
      that file, not just asserted. The hand-kept table is gone.

- [x] **Lists rendered on `view_bg_color` (pure black on COSMIC)** — fixed (`60aa8ea`).
      That is the surface themes reserve for sidebars and dedicated views, and GTK's default
      styling for a bare list picks it up. COSMIC Files proves the convention: its sidebar is
      that black, while the file list sits on `window_bg_color`. A List now paints the window
      background, which matches the desktop and matches SwiftUI, where List is opaque over the
      system background.

- [x] **`.scrollContentBackground(_:)` implemented** (`60aa8ea`), with SwiftUI's signature and
      its `.automatic` default, so the background is on by default and a caller opts out.

- [x] **Hierarchy/material colour mapping corrected** (`60aa8ea`). The first attempt mixed the
      foreground toward `window_bg_color`, which is only right when content happens to sit on
      that background and wrong on a card or a list. SwiftUI fades the *label colour* per tier
      and lets it composite, so tiers are now the theme foreground at 1.0 / 0.6 / 0.3 / 0.18
      and materials the card background at an opacity per thickness.

- [x] **Missing icons** — fixed (`266bab2`). Sixteen of thirty-two SF Symbols the app uses had
      no mapping and fell through to the placeholder. All thirty-two map now. The font
      registers fine and Pango resolves the family, so this was purely missing entries.

- [x] **Follow the desktop's dark/light preference** — fixed (`4aaea87`). The preference only
      appears in the XDG appearance portal: on this COSMIC session GtkSettings reports
      `gtk-theme-name = Adwaita` / `prefer-dark = FALSE` and the GNOME GSettings key reads
      `'default'`, while the portal returns `color-scheme = 1`.
      `SWIFTOPENUI_COLOR_SCHEME=dark|light` overrides it.
      Note for the record: the GTK theme *was* dark throughout — `gtk_widget_get_color()`
      returns white and `window_bg_color` is 0.149. COSMIC applies dark through its GTK4
      stylesheet, not through `prefer-dark`, which is why probing GtkSettings briefly made the
      original "light constants on dark chrome" diagnosis look wrong. It was not wrong.

- [ ] **The "add a source" flow is visibly broken.** Not re-checked since the icon, colour and
      sizing fixes, all of which affect it.

- [x] **Popups open at the wrong default size and are painful to resize.** Sheets
      now measure their content after rendering and choose a natural default,
      clamped to 320–900 by 180–760, instead of always opening at 400×300.
      GTK build passes.

- [x] **`.aspectRatio` is a no-op in GTK — and it is very likely why clicking a video
      turns the window black.** The player is
      `ZStack { Color.black; ... }.aspectRatio(16/9, .fit)`. Color renders as a box
      with hexpand/vexpand = 1, and aspectRatio constrains nothing, so the black
      rectangle is unbounded. Measured headlessly: in a 640x480 window the player is
      allocated the whole 640x480, where 16:9 of 640 is 360.
      That matches the report exactly — completely black, window decorations pushed
      off screen. Implemented with GtkAspectFrame (`ab3d61a`).
- [ ] **Two fork tests fail on this toolchain, and did before any of this work:**
      `GTK4RenderTests.testExplicitGridSharedLayoutAppliesHomogeneousSpanPlacements` and
      `GTKLayoutParityTests.testCompareAllScenariosAgainstReference`.

## Plugin runtime

- [x] **Debug source with one hardcoded video** — done, in `Tests/debug-plugin/`.
      `./Tests/debug-plugin/serve.sh` generates a 10s 320x240 H.264/AAC MP4 and
      serves it with the plugin on 127.0.0.1:8742; install via Sources → + →
      `http://127.0.0.1:8742/DebugPlugin.json`. Deliberately the easiest possible
      case — muxed, no separate audio stream, no custom headers — so it needs none of
      the features GtkVideo lacks, and playback failures cannot be blamed on the
      content. The video is generated, not committed, and gitignored.
      `DebugPluginTests` asserts it passes the same `validate()` the installer runs
      and returns one 10s video, so it cannot drift from the plugin API unnoticed.

- [x] **Home refetched forever and eventually hung** — fixed (`9feba21`). Confirmed by
      instrumenting the app: 75 idle seconds gave 45 loadMore calls, 18 past the
      in-flight guard, items growing 35 → 273. Cause: `.onAppear` on the last row is a
      lazy-list idiom, and this backend realises every row immediately, so each append
      realised a new last row that fetched again. The in-flight guard could not help,
      since every completed page produces a new last row. The automatic trigger now
      applies only where List is lazy, with an explicit "Load more" control
      elsewhere. Same instrumentation after the fix: zero loadMore calls in 75 idle
      seconds. Making the fork's List lazy would fix it properly and restore
      infinite scroll on GTK — worth doing eventually.

- [x] **`load()` ran 4 times at startup**, where `.task(id:)` should run once. Home
      now owns its feed and reload gate in the long-lived `AppModel`; repeated view
      tasks for the same enabled-source IDs share the in-flight or loaded result.
      Pull-to-refresh still forces one new load. This removes duplicate plugin and
      network work even if a backend recreates the task-hosting view.


- [ ] **(Later, architectural.) Cache fetched content in a database.** Everything
      fetched should land in a DB. A request for updated content should kick off a
      cache update, but view generation should happen immediately from what is
      already stored, with DB updates triggering a view regeneration rather than the
      view waiting on the network.


- [ ] **Join independent video and audio streams in the GStreamer pipeline.**
      The direct appsink player has replaced GtkVideo, so this no longer requires
      creating an intermediate muxed file. Build separate source/decode branches,
      share one pipeline clock, and route selected audio and video streams to their
      respective sinks. Apply request-modifier headers to each source independently.

- [x] **Player architecture: replace GtkVideo with a shared custom player surface.**
      Keep a platform-neutral SwiftOpenUI media API, implement Apple playback with
      AVPlayer/AVKit, and implement Linux playback with direct GStreamer. The API
      must support replacing the source, selecting independent video/audio/CC
      tracks, external subtitles, and picture-in-picture. Apple can use native
      AVPictureInPictureController; Linux will need a separate floating-window
      implementation because GTK/GStreamer do not provide OS PiP. Do not expose
      AVFoundation or AVKit types from the shared API.
      Shared `MediaTrack` and PiP APIs, the Apple `AVMediaPlayerDriver`, custom
      controls, and the direct GTK GStreamer/appsink surface are implemented.
      GTK presentation is sample-driven and clock-synchronised. Remaining player
      capabilities are tracked in the product roadmap and stream-joining item.
- [x] *Clicking a video fails on the GPU and hangs:
      Marked by user as resolved. Was an artifact of running the dev shell artifact
      outside of the dev shell

      `DRM_IOCTL_ASAHI_SUBMIT failed: Invalid argument`, then the app stops
      responding.
      Correction: the `vkAcquireNextImageKHR ... VK_SUBOPTIMAL_KHR` warnings are
      **not** a video signal — Gavin confirms they appear before any video renders
      and fire when entering or leaving the menu/tab bar, i.e. on the swapchain
      being recreated for ordinary redraws. All they establish is that the Vulkan
      GSK renderer is in use. The DRM submit failure on clicking a video is a
      separate event, and which layer feeds it the bad submit is still unknown.
      reports VK_ERROR_INCOMPATIBLE_DRIVER and GTK falls back, so the failing submit
      never happens. Diagnosis has to come from reading the playback path plus
      experiments Gavin runs on the real session.

      **Reframed — this is probably not a GPU bug.** Re-run against the *same* video
      (10:29) each time:
        - `GSK_RENDERER=cairo` → **black screen, completely unresponsive.** No Vulkan
          warnings, no GPU work at all. A hang with the software renderer means the
          main loop is blocked by our own code, not by the driver.
        - `GDK_DISABLE=vulkan` (GL) → **segfault.**
        - `GDK_DISABLE=offload` (Vulkan) → **DRM_IOCTL_ASAHI_SUBMIT failed.**
      So every renderer fails on the same input, and the one with no GPU path still
      hangs. The DRM error and the segfault are most likely downstream of a frozen or
      corrupted main loop rather than the cause.
      Control: a minimal GtkVideo harness (plain GTK, local file, no SwiftOpenUI)
      plays fine under both cairo and gl in Xvfb, so GtkVideo and the cairo renderer
      are not inherently broken — the difference is our playback path.
      **Next: a backtrace.** For the hang, attach while it is black
      (`gdb -p $(pgrep -f Hummingbird-gtk)` then `thread apply all bt`); for the
      segfault, `coredumpctl gdb` then `bt`. That names the blocking call directly.
      Prime suspects: synchronous network or plugin-runtime work on the main actor
      when a video is opened.

      **Earlier results, against *different* videos each — not comparable:**
        - `GSK_RENDERER=cairo` → **no hang, but no playback either.** Investigating
          *why* it shows nothing, isolated from our app (see below). So the GPU path
          is implicated in the hang (software rendering submits nothing, so nothing
          fails), and cairo is not a usable fallback because the video does not
          render at all under it — GtkVideo's frames need a GPU-backed path.
        - `GDK_DISABLE=offload` → **still fails.** DRM_IOCTL_ASAHI_SUBMIT as before,
          so graphics offload is not the culprit. My first suspect was wrong.
        - `GDK_DISABLE=vulkan` → **segfaults.** Vulkan warnings gone, so the GL
          renderer is genuinely in use, and it crashes instead of hanging. A
          different failure, possibly the same bad frames taken down a different
          path. A backtrace would settle it (`coredumpctl gdb`, or run it under gdb).
        - **Caveat on all of the above: each run used a different video** (random
          livestreams/VODs, since the titles are unreadable). So they are not three
          results on one input, and the differences may be content-dependent — live
          HLS versus muxed VOD, different codecs — rather than renderer-dependent.
          The dmabuf theory that ties them together is therefore unsupported.
          **Before more renderer probes, pin the input.** Titles are unreadable, but
          the runtime/duration shown on each row identifies an item well enough to
          replay the same one, so this need not wait on the measure fix.
        - Remaining probe once the input is fixed: `GDK_DISABLE=dmabuf`, then
          `GDK_DISABLE=vulkan,dmabuf`.
          `GDK_DISABLE=vulkan,dmabuf`. If dmabuf import is what Asahi rejects, that
          would explain Vulkan failing the submit *and* GL crashing on the same
          buffers, while cairo — which never imports them — merely shows nothing.
          and `GDK_DISABLE=vulkan` (GL renderer instead). Whichever plays *and* does
          not hang is the fix.

      Note the variable is
      `GSK_RENDERER`, not `GSK_RENDER`; a first attempt used the latter, so GTK
      silently kept the default renderer and the result meant nothing.
        1. `GDK_DISABLE=offload` — graphics offload hands video frames straight to
           the compositor for scanout, exactly the path a player uses. First suspect.
        2. `GDK_DISABLE=dmabuf` — stops importing frames as dmabufs.
        3. `GDK_DISABLE=vulkan` — falls back to the GL renderer, and should also
           clear the VK_SUBOPTIMAL_KHR noise.
        4. `GSK_RENDERER=cairo` — software; slow, but proves whether any GPU path is
           involved at all.
      (Those flag names are GTK 4.22's real feature keys, read from gdk/gdk.c.)

      **Fix once we know which:** GTK 4.22 has
      `gtk_video_set_graphics_offload(video, GTK_GRAPHICS_OFFLOAD_DISABLED)`, so if
      offload is the culprit it can be disabled for the video widget alone rather
      than globally — a line in GTKMedia.swift plus a shim entry. If Vulkan itself is
      at fault that is a renderer choice and needs a different answer.
- [ ] **Odysee fails with "Maximum call stack size exceeded".**
      Measured, so the obvious suspects are ruled out:
      - The dispatch worker thread that runs plugin JS has an **8.06 MiB** stack, so
        the 4 MiB `JS_SetMaxStackSize` limit in `QuickJSContextHost.init` is reachable
        and sits safely inside the real stack. The limit is not misconfigured.
      - The "runtime created on one thread, JS run on another" theory (QuickJS records
        `stack_top` once, in `JS_NewRuntime`, and never refreshes it — there is no
        `JS_UpdateStackTop` call anywhere in Swift) **did not reproduce**: across repeated
        `queue.async` blocks separated by 2 s idle gaps, libdispatch reused the same worker
        thread and the stack pointer was identical every time.
      So the error is most likely genuine: Odysee really does use more than 4 MiB of QuickJS
      stack. Next step is to raise the limit to ~6 MiB (still inside the 8 MiB thread stack)
      as a diagnostic — if it then completes it is depth, if it still blows up it is runaway
      recursion, most likely in `prelude.js` or a host-call shim.

      - **The QuickJS stack bug reproduces intermittently in our own suite.** A run of
        `hb-test` failed `RuntimeTests.testRoutingChannelAndDetails` and
        `testSaveStateAndHostPackages` with "Maximum call stack size exceeded" — the
        same error Odysee gives — then two further runs passed 22/22. That is a much
        cheaper reproduction than loading Odysee, and being load- or thread-dependent
        fits a stack-limit problem. Try running the suite under load, or repeatedly,
        to get it to fail on demand.

      User note: reliably reproduced by loading debug plugin, going to any other
      page, and then going back home (repeat a few times)

## Known Linux limits

Already in the README; listed here so they are tracked rather than rediscovered.

- [ ] Video: the direct GStreamer backend does not yet apply custom HTTP headers or join
      separate audio and video, so only muxed, HLS and live sources without a request
      modifier play.
- [ ] Login and QR: web login and QR scanning are absent; login is a paste-your-cookies form.
- [ ] Lists: swipe-to-delete and reordering do nothing, and lazy lists render as plain stacks.

## Nix packaging

- [x] **Fork history tidied** — `5e1129b` was split into `d1fbb29` (list-box revert)
      and `748769b` (codepoint implementation + tests), force-pushed, and the
      submodule re-pointed in `8a981f3`. Verified the rewritten tree is identical to
      what the old tip held. Note: Hummingbird commit `203b915` still references the
      orphaned `5e1129b`, so a nix build of that specific commit would fail to fetch
      the submodule.

- [x] `adwaita-icon-theme` is part of the shared GTK runtime inputs, so the wrapped
      package and development shell find standard icons without borrowing the
      ambient desktop session's `XDG_DATA_DIRS`.
- [x] The packaged build exposes GStreamer development headers through `CPATH`,
      matching the development shell. This keeps the direct appsink backend
      buildable in the Nix sandbox.
- [ ] `nix/swiftpm-pins.nix` hardcodes `originHash`. It has to be refreshed whenever a
      dependency changes, or the sandboxed build will quietly go back to trying the network.
- [ ] The sandboxed build logs `skipping cache due to an error: Failed to clone repository`.
      Harmless — resolution is disabled and the checkouts are pre-placed — but noisy.
- [ ] `ld.bfd` emits `bad subsection length` / `could not parse subsection` warnings against
      the Swift runtime libraries. The link succeeds; switching to `lld` would likely silence
      them.

## Debugging notes

- **The app can be rendered and screenshotted headlessly**, which removes the need to
  guess from descriptions: `GDK_BACKEND=x11` under `xvfb-run` (unset WAYLAND_DISPLAY
  too, or the app connects to the real compositor and the capture comes out blank),
  then `xwd -root` and convert. `<scratchpad>/shot.sh` does it. This should be the
  first move on any visual bug — three wrong diagnoses in a row came from reasoning
  about screenshots instead of measuring or looking.

- `inputs.self.submodules = true` makes Nix fetch Vendor/SwiftOpenUI from its
  `.gitmodules` URL rather than the working tree, so **fork commits must be pushed
  before any nix command on this flake works** — `nix develop` included, not just
  `nix build`. Bumping the submodule without pushing breaks the dev shell too, with
  "Cannot find Git revision". (An earlier note here claimed the dev shell was
  unaffected; that was wrong.) The alternative is dropping `self.submodules` and
  passing `?submodules=1` only where the package needs it, at the cost of plain
  `nix run .` working.


- The GTK app connects to **Wayland** when `WAYLAND_DISPLAY` is set, so it ignores Xvfb and
  headless screenshots come out blank. Force `GDK_BACKEND=x11` to capture one.
- Develop in `nix develop` (`hb-build` does incremental SwiftPM builds). `nix build` / `nix run`
  rebuild the product from scratch, so they are for checking the packaged artifact, not for
  iterating.
