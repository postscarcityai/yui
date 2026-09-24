// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YuiLines",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "YuiLines", targets: ["YuiLines"])],
    targets: [
        .target(name: "YuiLines"),
        .testTarget(
            name: "YuiLinesTests",
            dependencies: ["YuiLines"],
            resources: [.copy("Resources/conformance")]
        ),
    ]
)
