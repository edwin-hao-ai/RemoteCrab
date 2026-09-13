// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "iBridgeCore",
    // Shared UI strings live in Sources/iBridgeCore/Resources/
    // Localizable.xcstrings (en source + zh-Hans). `IBLocale` resolves
    // them against `Bundle.module`, so both apps follow the system
    // language without duplicating translations.
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
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
            path: "Sources/iBridgeCore",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "iBridgeCoreTests",
            dependencies: ["iBridgeCore"],
            path: "Tests/iBridgeCoreTests"
        )
    ]
)