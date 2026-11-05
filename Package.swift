// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PagerNetwork",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "PagerNetwork", targets: ["PagerNetwork"])],
    targets: [
        .target(name: "PagerNetwork"),
        .executableTarget(name: "net-probe", dependencies: ["PagerNetwork"]),
        .testTarget(name: "PagerNetworkTests", dependencies: ["PagerNetwork"]),
    ]
)
