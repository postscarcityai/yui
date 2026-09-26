// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YuiSound",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "YuiSound", targets: ["YuiSound"])],
    targets: [
        .target(name: "YuiSound"),
        .testTarget(name: "YuiSoundTests", dependencies: ["YuiSound"], resources: [.copy("Resources/theory-golden.json")]),
    ]
)
