// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CaptureService",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "capture-service", targets: ["CaptureService"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "CaptureService",
            dependencies: [],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("VideoToolbox")
            ]
        )
    ]
)
