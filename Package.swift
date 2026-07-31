// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DualSenseBridge",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DualSenseBridge", targets: ["DualSenseBridge"]),
        .library(name: "DualSenseBridgeCore", targets: ["DualSenseBridgeCore"])
    ],
    targets: [
        .target(
            name: "CSonic",
            path: "Sources/CSonic",
            publicHeadersPath: "include"
        ),
        .target(
            name: "DualSenseBridgeCore",
            dependencies: ["CSonic"]
        ),
        .executableTarget(
            name: "DualSenseBridge",
            dependencies: [
                "DualSenseBridgeCore"
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreHaptics"),
                .linkedFramework("GameController"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "DualSenseBridgeCoreTests",
            dependencies: ["DualSenseBridgeCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
