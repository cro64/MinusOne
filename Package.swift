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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "CAtomics"),
        .executableTarget(
            name: "MinusOne",
            dependencies: [
                "CAtomics",
                .product(name: "Sparkle", package: "Sparkle")
            ],
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
            dependencies: ["MinusOne"],
            path: "Tests/MinusOneUITests"
        )
    ]
)
