// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Speaker",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "SpeakerCore", targets: ["SpeakerCore"]),
        .executable(name: "SpeakerApp", targets: ["SpeakerApp"]),
        .executable(name: "SpeakerCoreSpecs", targets: ["SpeakerCoreSpecs"]),
    ],
    targets: [
        .target(name: "SpeakerCore"),
        .executableTarget(
            name: "SpeakerApp",
            dependencies: ["SpeakerCore"]
        ),
        .executableTarget(
            name: "SpeakerCoreSpecs",
            dependencies: ["SpeakerCore"],
            path: "Tests/SpeakerCoreSpecs"
        ),
    ]
)
