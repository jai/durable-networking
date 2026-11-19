// swift-tools-version: 6.2
import PackageDescription

// DurableNetworking: the one network stack for Jai's apps (README.md). Hosts give it endpoints and models; kits take
// its `HTTPTransport` and `StreamingTransport` from their host and never touch `URLSession` themselves.
let package = Package(
    name: "DurableNetworking",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "DurableNetworking", targets: ["DurableNetworking"]),
        // Fault injection for demos and tests (Demo/, docs/end-to-end-walkthrough.md). No app links it.
        .library(name: "DurableNetworkingTesting", targets: ["DurableNetworkingTesting"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-clocks", from: "1.0.0"),
    ],
    targets: [
        .target(name: "DurableNetworking", swiftSettings: [.enableUpcomingFeature("ExistentialAny")]),
        .target(
            name: "DurableNetworkingTesting", dependencies: ["DurableNetworking"],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(name: "DurableNetworkingTests", dependencies: [
            "DurableNetworking", .product(name: "Clocks", package: "swift-clocks"),
        ], path: "Tests/DurableNetworkingTests/Unit"),
        .testTarget(name: "DurableNetworkingIntegrationTests", dependencies: ["DurableNetworking"],
                    path: "Tests/DurableNetworkingTests/Integration"),
        .testTarget(name: "DurableNetworkingTestingTests", dependencies: ["DurableNetworkingTesting"]),
    ],
    swiftLanguageModes: [.v6]
)
