// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RemoteCrabCameraExtension",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "RemoteCrabCameraExtension",
            type: .extension,
            targets: ["RemoteCrabCameraExtension"]
        )
    ],
    targets: [
        .target(
            name: "RemoteCrabCameraExtension",
            dependencies: ["RemoteCrabCore"],
            path: "Sources/RemoteCrabCameraExtension",
            linkerSettings: [
                .linkedFramework("CoreMediaIO")
            ]
        )
    ]
)