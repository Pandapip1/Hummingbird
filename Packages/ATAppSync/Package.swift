// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ATAppSync",
    platforms: [.iOS(.v18), .macOS(.v15), .tvOS(.v18), .visionOS(.v2)],
    products: [.library(name: "ATAppSync", targets: ["ATAppSync"])],
    dependencies: [
        .package(path: "../ATProtoKit"),
        .package(path: "../../Vendor/SwiftOpenUI"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .systemLibrary(
            name: "CDNSService",
            providers: [
                .apt(["libavahi-compat-libdnssd-dev"]),
                .brew(["avahi"]),
            ]
        ),
        .target(
            name: "ATAppSync",
            dependencies: [
                "CDNSService",
                .product(name: "ATProtoKit", package: "ATProtoKit"),
                .product(name: "CredentialStorage", package: "SwiftOpenUI"),
                .product(name: "os", package: "SwiftOpenUI", condition: .when(platforms: [.linux])),
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
