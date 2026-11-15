// swift-tools-version: 6.2
import PackageDescription

// DurableNetworking: the one network stack for Jai's apps (README.md). Hosts give it endpoints and models; kits take
// its `HTTPTransport` and `StreamingTransport` from their host and never touch `URLSession` themselves.
let package = Package(
    name: "DurableNetworking",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "DurableNetworking", targets: ["DurableNetworking"])],
    targets: [
        .target(name: "DurableNetworking", swiftSettings: [.enableUpcomingFeature("ExistentialAny")]),
        .testTarget(name: "DurableNetworkingTests", dependencies: ["DurableNetworking"]),
    ],
    swiftLanguageModes: [.v6]
)
