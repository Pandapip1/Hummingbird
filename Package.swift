// swift-tools-version: 5.10
import PackageDescription

// Jaybird builds in three layers:
//   CQuickJS     – vendored QuickJS-NG, the JavaScript engine used wherever JavaScriptCore is not available.
//   JaybirdKit   – one module with two folders. Core/ is the plugin host, models and services (no UI imports);
//                  UI/ is the screens: real SwiftUI on Apple platforms, SwiftOpenUI (Vendor/SwiftOpenUI) elsewhere.
// The iOS app target lives in project.yml (XcodeGen) and consumes this package; the Linux/GTK4 executable is below.

let nonApple: [Platform] = [.linux, .android, .windows]

var products: [Product] = [
    .library(name: "JaybirdKit", targets: ["JaybirdKit"]),
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
    .target(
        name: "JaybirdKit",
        dependencies: [
            "CQuickJS",
            .product(name: "SwiftSoup", package: "SwiftSoup"),
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: nonApple)),
            .product(name: "_CryptoExtras", package: "swift-crypto", condition: .when(platforms: nonApple)),
            .product(name: "SwiftOpenUI", package: "SwiftOpenUI", condition: .when(platforms: nonApple)),
        ],
        path: "Sources/JaybirdKit",
        resources: [.copy("Core/Plugin/Resources/prelude.js")],
        linkerSettings: [
            // The Swift 6.1 Linux toolchain's libswiftObservation.so references a runtime symbol that libswiftCore.so
            // does not export (it is only called on a fatal-error path), so the link needs this to succeed.
            .unsafeFlags(["-Xlinker", "--allow-shlib-undefined"], .when(platforms: [.linux])),
        ]
    ),
    .testTarget(
        name: "JaybirdKitTests",
        dependencies: ["JaybirdKit"],
        path: "Tests/JaybirdKitTests"
    ),
]

#if os(Linux)
products.append(.executable(name: "jaybird-gtk", targets: ["JaybirdGTK"]))
targets.append(
    .executableTarget(
        name: "JaybirdGTK",
        dependencies: [
            "JaybirdKit",
            .product(name: "SwiftOpenUI", package: "SwiftOpenUI"),
            .product(name: "BackendGTK4", package: "SwiftOpenUI"),
        ],
        path: "Sources/JaybirdGTK"
    )
)
#endif

let package = Package(
    name: "Jaybird",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: products,
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(path: "Vendor/SwiftOpenUI"),
    ],
    targets: targets
)
