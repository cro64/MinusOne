// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MinusOne",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MinusOne", targets: ["MinusOne"])
    ],
    targets: [
        .target(name: "CAtomics"),
        .executableTarget(
            name: "MinusOne",
            dependencies: ["CAtomics"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreML"),
                .linkedFramework("Accelerate")
            ]
        ),
        .testTarget(
            name: "MinusOneUITests",
            dependencies: [],
            path: "Tests/MinusOneUITests"
        )
    ]
)
