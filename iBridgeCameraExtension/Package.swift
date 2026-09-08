// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "iBridgeCameraExtension",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "iBridgeCameraExtension",
            type: .extension,
            targets: ["iBridgeCameraExtension"]
        )
    ],
    targets: [
        .target(
            name: "iBridgeCameraExtension",
            dependencies: ["iBridgeCore"],
            path: "Sources/iBridgeCameraExtension",
            linkerSettings: [
                .linkedFramework("CoreMediaIO")
            ]
        )
    ]
)