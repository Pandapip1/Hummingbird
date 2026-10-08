// swift-tools-version: 5.10
import PackageDescription

let requestedBackend = Context.environment["SWIFTOPENUI_BACKEND"]?.lowercased()
#if os(Linux)
let gtkBackendEnabled = requestedBackend == nil || requestedBackend == "gtk"
#else
let gtkBackendEnabled = requestedBackend == "gtk"
#endif
var backendSwiftSettings: [SwiftSetting] = gtkBackendEnabled ? [.define("BACKEND_GTK")] : []
#if os(Linux)
if gtkBackendEnabled { backendSwiftSettings.append(.define("BACKEND_GTK_WEBKIT")) }
#endif

// Hummingbird builds in three layers:
//   HummingbirdKit   – one module with two folders. Core/ is the plugin host, models and services (no UI imports);
//                  UI/ is the screens: real SwiftUI on Apple platforms, SwiftOpenUI (Vendor/SwiftOpenUI) elsewhere.
// The iOS app target lives in project.yml (XcodeGen) and consumes this package; the Linux/GTK4 executable is below.

let nonApple: [Platform] = [.linux, .android, .windows]

var products: [Product] = [
    .library(name: "HummingbirdKit", targets: ["HummingbirdKit"]),
    .library(name: "DebugKit", targets: ["DebugKit"]),
    .library(name: "DynamicTabbingKit", targets: ["DynamicTabbingKit"]),
    .library(name: "AdvancedVideoPlayerKit", targets: ["AdvancedVideoPlayerKit"]),
]
var targets: [Target] = [
    .target(
        name: "DebugKit",
        path: "Sources/DebugKit"
    ),
    .target(
        name: "DynamicTabbingKit",
        dependencies: [.product(name: "BrowserTabs", package: "SwiftOpenUI")],
        path: "Sources/DynamicTabbingKit"
    ),
    .target(
        name: "AdvancedVideoPlayerKit",
        dependencies: [.product(name: "SwiftOpenUI", package: "SwiftOpenUI")],
        path: "Sources/AdvancedVideoPlayerKit",
        swiftSettings: backendSwiftSettings
    ),
    .systemLibrary(
        name: "CJavaScriptCoreGTK",
        path: "Sources/CJavaScriptCoreGTK",
        pkgConfig: "javascriptcoregtk-6.0",
        providers: [.apt(["libjavascriptcoregtk-6.0-dev"])]
    ),
    .systemLibrary(
        name: "CSQLite",
        path: "Sources/CSQLite",
        pkgConfig: "sqlite3",
        providers: [.apt(["libsqlite3-dev"])]
    ),
    .target(
        name: "HummingbirdKit",
        dependencies: [
            "DebugKit",
            "DynamicTabbingKit",
            "AdvancedVideoPlayerKit",
            "CSQLite",
            .target(name: "CJavaScriptCoreGTK", condition: .when(platforms: [.linux])),
            .product(name: "SwiftSoup", package: "SwiftSoup"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "_CryptoExtras", package: "swift-crypto", condition: .when(platforms: nonApple)),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "QRCodeGenerator", package: "swift-qrcode-generator"),
            .product(name: "SwiftOpenUI", package: "SwiftOpenUI"),
            .product(name: "WebKit", package: "SwiftOpenUI", condition: .when(platforms: nonApple)),
        ],
        path: "Sources/HummingbirdKit",
        resources: [.copy("Core/Plugin/Resources/prelude.js")],
        swiftSettings: backendSwiftSettings,
        linkerSettings: [
            // The Swift 6.1 Linux toolchain's libswiftObservation.so references a runtime symbol that libswiftCore.so
            // does not export (it is only called on a fatal-error path), so the link needs this to succeed.
            .unsafeFlags(["-Xlinker", "--allow-shlib-undefined"], .when(platforms: [.linux])),
        ]
    ),
    .testTarget(
        name: "HummingbirdKitTests",
        dependencies: [
            "HummingbirdKit",
            .product(name: "SwiftOpenUI", package: "SwiftOpenUI", condition: .when(platforms: nonApple)),
            .product(name: "WebKit", package: "SwiftOpenUI", condition: .when(platforms: nonApple)),
            .product(name: "BackendGTK4", package: "SwiftOpenUI", condition: .when(platforms: [.linux])),
            .product(name: "CAdwaita", package: "SwiftOpenUI", condition: .when(platforms: [.linux])),
        ],
        path: "Tests/HummingbirdKitTests"
    ),
]

if gtkBackendEnabled {
products.append(.executable(name: "Hummingbird-gtk", targets: ["HummingbirdGTK"]))
var gtkExecutableDependencies: [Target.Dependency] = [
    "HummingbirdKit",
    .product(name: "SwiftOpenUI", package: "SwiftOpenUI"),
    .product(name: "BackendGTK4", package: "SwiftOpenUI"),
    .product(name: "CGTK", package: "SwiftOpenUI"),
    .product(name: "CGTKBridge", package: "SwiftOpenUI"),
]
#if os(Linux)
gtkExecutableDependencies.append(.product(name: "WebKit", package: "SwiftOpenUI"))
#endif
targets.append(
    .executableTarget(
        name: "HummingbirdGTK",
        dependencies: gtkExecutableDependencies,
        path: "Sources/HummingbirdGTK",
        swiftSettings: backendSwiftSettings
    )
)
}

let package = Package(
    name: "Hummingbird",
    platforms: [.iOS("26.0"), .macOS("26.0"), .tvOS("26.0"), .visionOS("26.0")],
    products: products,
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/fwcd/swift-qrcode-generator.git", from: "1.0.0"),
        .package(path: "Vendor/SwiftOpenUI"),
    ],
    targets: targets
)
