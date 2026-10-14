// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ATProtoKit",
    platforms: [.iOS("17.4"), .macOS("14.4"), .tvOS("17.4"), .visionOS("1.1")],
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
