// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ATProtoKit",
    platforms: [.iOS(.v18), .macOS(.v15), .tvOS(.v18), .visionOS(.v2)],
    products: [.library(name: "ATProtoKit", targets: ["ATProtoKit"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(path: "../../Vendor/SwiftOpenUI"),
    ],
    targets: [
        .target(
            name: "ATProtoKit",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "CredentialStorage", package: "SwiftOpenUI"),
                .product(name: "SecureMemory", package: "SwiftOpenUI"),
                .product(name: "AuthenticationServices", package: "SwiftOpenUI", condition: .when(platforms: [.linux])),
            ]
        ),
        .testTarget(name: "ATProtoKitTests", dependencies: [
            "ATProtoKit",
            .product(name: "CredentialStorage", package: "SwiftOpenUI"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
