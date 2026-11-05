// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DotCounterCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "DotCounterCore", targets: ["DotCounterCore"])],
    targets: [
        .target(name: "DotCounterCore"),
        .testTarget(name: "DotCounterCoreTests", dependencies: ["DotCounterCore"])
    ]
)
