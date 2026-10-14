// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ATAppSync",
    platforms: [.iOS("17.4"), .macOS("14.4"), .tvOS("17.4"), .visionOS("1.1")],
    products: [.library(name: "ATAppSync", targets: ["ATAppSync"])],
    dependencies: [
        .package(path: "../ATProtoKit"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(
            name: "ATAppSync",
            dependencies: [
                .product(name: "ATProtoKit", package: "ATProtoKit"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .testTarget(name: "ATAppSyncTests", dependencies: ["ATAppSync", .product(name: "Crypto", package: "swift-crypto")]),
    ],
    swiftLanguageModes: [.v6]
)
