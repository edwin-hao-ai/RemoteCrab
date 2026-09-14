// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RemoteCrabCore",
    // Shared UI strings live in Sources/RemoteCrabCore/Resources/
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
            name: "RemoteCrabCore",
            targets: ["RemoteCrabCore"]
        )
    ],
    targets: [
        .target(
            name: "RemoteCrabCore",
            path: "Sources/RemoteCrabCore",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "RemoteCrabCoreTests",
            dependencies: ["RemoteCrabCore"],
            path: "Tests/RemoteCrabCoreTests"
        )
    ]
)