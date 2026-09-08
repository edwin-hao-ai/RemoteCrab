// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "iBridgeCore",
    platforms: [
        .iOS(.v26),
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "iBridgeCore",
            targets: ["iBridgeCore"]
        )
    ],
    targets: [
        .target(
            name: "iBridgeCore",
            path: "Sources/iBridgeCore"
        )
    ]
)