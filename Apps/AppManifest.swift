// The one definition of the Hummingbird app. scripts/generate-app turns it into
// everything that builds the app, so Xcode and xtool always produce the same
// Hummingbird.app:
//
//   Apps/iOS/Info.plist                      the app's Info.plist (literal values)
//   Apps/iOS/Hummingbird.entitlements        Xcode's entitlements (team-signed)
//   Apps/iOS/Hummingbird.xtool.entitlements  xtool's entitlements (ad-hoc signed)
//   project.yml                              the Xcode app target (marked region),
//                                            named "<name>-App" so it can't clash
//                                            with the package product xtool needs;
//                                            it still builds <name>.app
//   xtool.yml                                xtool's app definition
//   Package.swift                            the package product xtool builds (marked region)
//   Apps/Linux/url-schemes.json             the URL schemes, for the Linux desktop entry
//
// Edit this file, then run scripts/generate-app. The pre-commit hook and
// AppManifestTests fail while any generated file is out of date.

let manifest = AppManifest(
    // The bundle, executable and CFBundleName in both builds.
    name: "Hummingbird",
    bundleID: "com.eightybps.hummingbird",
    version: "0.1.0",
    build: "1",
    developmentTeam: "NMM6M6QVAT",
    sources: "Apps/iOS",
    icon: "Apps/iOS/Hummingbird.icon",
    resources: ["Apps/iOS/Assets.xcassets"],
    info: [
        "CFBundleDisplayName": "Hummingbird",
        "CFBundleDevelopmentRegion": "en",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundlePackageType": "APPL",
        "LSApplicationCategoryType": "public.app-category.video",
        // Expanded by team-signed (Xcode) builds only; see teamEntitlements.
        "ATProtoKeychainAccessGroup": "$(AppIdentifierPrefix)com.eightybps.hummingbird.shared",
        "UILaunchScreen": [:],
        "UIBackgroundModes": ["audio"],
        "UISupportedInterfaceOrientations": [
            "UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight",
        ],
        "NSCameraUsageDescription": "Used to scan QR codes that add plugin sources.",
        // Plugins talk to arbitrary hosts (and developers serve plugins over
        // http on the LAN), so plugin traffic cannot be restricted by ATS. The
        // per-plugin allowUrls list is the real gate.
        "NSAppTransportSecurity": ["NSAllowsArbitraryLoads": true, "NSAllowsLocalNetworking": true],
        // Local network privacy only allows the DNS-SD types listed here;
        // ATAppSync advertises and browses AppSyncAuthority.bonjourServiceType.
        "NSBonjourServices": ["_atproto-appsync._tcp"],
        "NSLocalNetworkUsageDescription": "Hummingbird uses your local network to sync with your other devices, transfer plugin sign-in credentials and load locally hosted plugins.",
        // All encryption is standard and goes through Apple's frameworks
        // (CryptoKit, Security, URLSession); see Web/DEPLOYMENT.md and
        // EncryptionExportTests.
        "ITSAppUsesNonExemptEncryption": false,
    ],
    // The URL schemes the app opens, registered on every platform from here
    // (Info.plist on Apple platforms; the desktop entry's scheme handlers on
    // Linux, from Apps/Linux/url-schemes.json).
    urlSchemes: [
        (name: "app.hummingbird.credential-login", scheme: "hummingbird"),
        (name: "com.eightybps.hummingbird.oauth", scheme: "com.eightybps.hummingbird"),
        // Plugin install links (grayjay://plugin/<config URL>): Add Source,
        // never a silent install.
        (name: "app.hummingbird.plugin-install", scheme: "grayjay"),
    ],
    // macOS sandbox entitlements, in both builds. Xcode applies them per
    // platform through its build settings (they mean nothing on iOS, where a
    // shared entitlements file containing them would break signing); xtool,
    // which builds the Mac app only, gets them in its entitlements file.
    sandbox: [
        .appSandbox,
        // Plugins, sources and account servers.
        .outgoingNetwork,
        // Device sync (AppSync over the local network) and credential pairing
        // listen for peers.
        .incomingNetwork,
        // Scanning QR codes.
        .camera,
    ],
    // Entitlements a development team must grant. An ad-hoc signed build (xtool,
    // Nix) can't carry them, as the app would not launch, so it uses the login
    // keychain fallback instead of the shared access group.
    teamEntitlements: [
        "keychain-access-groups": ["$(AppIdentifierPrefix)com.eightybps.hummingbird.shared"],
        // Age assurance (Documentation/AgeAndParentalControls.md): without it
        // Declared Age Range throws, and every Apple device would count as
        // having no age source. The App ID needs the capability.
        "com.apple.developer.declared-age-range": true,
    ],
    // Xcode-only settings: which platforms the one target builds for, and
    // signing options with no xtool counterpart.
    xcodeSettings: [
        ("TARGETED_DEVICE_FAMILY", "\"1,2,3,7\""),
        ("SUPPORTED_PLATFORMS", "\"appletvos appletvsimulator iphoneos iphonesimulator macosx xros xrsimulator\""),
        ("SUPPORTS_MACCATALYST", "NO"),
        ("SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD", "NO"),
        ("SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD", "NO"),
        ("ENABLE_HARDENED_RUNTIME", "YES"),
        ("REGISTER_APP_GROUPS", "YES"),
    ],
    // The plugin engine (PluginEngine) and JavaScriptCore's script time limit, which only builds
    // outside the App Store use (Apps/iOS/DirectDistribution.swift).
    packageProducts: ["PluginEngine", "CJSCExecutionLimit"],
    // The macOS plugin host: an XPC service with a sandbox of its own and no network
    // (Apps/PluginHostXPC), one process per plugin, killed on a deadline.
    embeddedTargets: [(target: "PluginHostXPC", platform: "macOS")],
    // How the app is distributed. Builds for the App Store set HUMMINGBIRD_DISTRIBUTION=appstore:
    // APP_STORE is then defined and nothing that is not public API is compiled in
    // (scripts/check-app-store-symbols verifies the binary).
    distributions: [(name: "direct", conditions: []), (name: "appstore", conditions: ["APP_STORE"])]
)
