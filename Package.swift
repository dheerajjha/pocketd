// swift-tools-version: 6.0
import PackageDescription

// PocketdKit deliberately depends on nothing but an HTTP server. The inference
// backend enters through the `InferenceEngine` protocol, which means the whole
// API surface — routes, DTOs, auth, streaming — is testable on a Linux or macOS
// runner in seconds, without compiling llama.cpp or booting a simulator. The
// real engine lives in the app target, where the heavy dependency belongs.
let package = Package(
    name: "pocketd",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PocketdKit", targets: ["PocketdKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/swhitty/FlyingFox.git", .upToNextMinor(from: "0.27.1"))
    ],
    targets: [
        .target(
            name: "PocketdKit",
            dependencies: [
                .product(name: "FlyingFox", package: "FlyingFox"),
                .product(name: "FlyingSocks", package: "FlyingFox")
            ]
        ),
        .testTarget(
            name: "PocketdKitTests",
            dependencies: ["PocketdKit"]
        )
    ]
)
