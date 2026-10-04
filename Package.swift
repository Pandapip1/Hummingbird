// swift-tools-version: 5.10
import PackageDescription

// Hummingbird builds in three layers:
//   CQuickJS     – vendored QuickJS-NG, the JavaScript engine used wherever JavaScriptCore is not available.
//   HummingbirdKit   – one module with two folders. Core/ is the plugin host, models and services (no UI imports);
//                  UI/ is the screens: real SwiftUI on Apple platforms, SwiftOpenUI (Vendor/SwiftOpenUI) elsewhere.
// The iOS app target lives in project.yml (XcodeGen) and consumes this package; the Linux/GTK4 executable is below.

let nonApple: [Platform] = [.linux, .android, .windows]

var products: [Product] = [
    .library(name: "HummingbirdKit", targets: ["HummingbirdKit"]),
]
var targets: [Target] = [
    .target(
        name: "CQuickJS",
        path: "Sources/CQuickJS",
        exclude: ["LICENSE", "VERSION"],
        cSettings: [
            .define("_GNU_SOURCE"),
            .unsafeFlags(["-w", "-fwrapv"]),   // upstream code, built as shipped
        ]
    ),
    .systemLibrary(
        name: "CJavaScriptCoreGTK",
        path: "Sources/CJavaScriptCoreGTK",
        pkgConfig: "javascriptcoregtk-6.0",
        providers: [.apt(["libjavascriptcoregtk-6.0-dev"])]
    ),
    .target(
        name: "HummingbirdKit",
        dependencies: [
            "CQuickJS",
            .target(name: "CJavaScriptCoreGTK", condition: .when(platforms: [.linux])),
            .product(name: "SwiftSoup", package: "SwiftSoup"),
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: nonApple)),
            .product(name: "_CryptoExtras", package: "swift-crypto", condition: .when(platforms: nonApple)),
            .product(name: "SwiftOpenUI", package: "SwiftOpenUI", condition: .when(platforms: nonApple)),
            .product(name: "WebKit", package: "SwiftOpenUI", condition: .when(platforms: nonApple)),
        ],
        path: "Sources/HummingbirdKit",
        resources: [.copy("Core/Plugin/Resources/prelude.js")],
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
        ],
        path: "Tests/HummingbirdKitTests"
    ),
]

#if os(Linux)
products.append(.executable(name: "Hummingbird-gtk", targets: ["HummingbirdGTK"]))
targets.append(
    .executableTarget(
        name: "HummingbirdGTK",
        dependencies: [
            "HummingbirdKit",
            .product(name: "SwiftOpenUI", package: "SwiftOpenUI"),
            .product(name: "BackendGTK4", package: "SwiftOpenUI"),
        ],
        path: "Sources/HummingbirdGTK"
    )
)
#endif

let package = Package(
    name: "Hummingbird",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: products,
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(path: "Vendor/SwiftOpenUI"),
    ],
    targets: targets
)
