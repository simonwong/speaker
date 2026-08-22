// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Speaker",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "SpeakerCore", targets: ["SpeakerCore"]),
        .library(
            name: "SpeakerProviderEvidence",
            targets: ["SpeakerProviderEvidence"]
        ),
        .executable(name: "SpeakerApp", targets: ["SpeakerApp"]),
        .executable(name: "SpeakerCoreSpecs", targets: ["SpeakerCoreSpecs"]),
        .executable(name: "SpeakerAppScenarioSpecs", targets: ["SpeakerAppScenarioSpecs"]),
        .executable(name: "SpeakerAppUISpecs", targets: ["SpeakerAppUISpecs"]),
        .executable(
            name: "SpeakerBrandAssetGenerator",
            targets: ["SpeakerBrandAssetGenerator"]
        ),
        .executable(name: "SpeakerProviderSmoke", targets: ["SpeakerProviderSmoke"]),
        .executable(
            name: "SpeakerProviderEvidenceVerifier",
            targets: ["SpeakerProviderEvidenceVerifier"]
        ),
        .executable(
            name: "SpeakerProviderEvidenceSpecs",
            targets: ["SpeakerProviderEvidenceSpecs"]
        ),
        .executable(
            name: "SpeakerUpdateSignatureVerifier",
            targets: ["SpeakerUpdateSignatureVerifier"]
        ),
        .executable(
            name: "SpeakerReleaseEvidenceProtector",
            targets: ["SpeakerReleaseEvidenceProtector"]
        ),
        .executable(
            name: "SpeakerDeliverySmokeTarget",
            targets: ["SpeakerDeliverySmokeTarget"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.4"
        ),
    ],
    targets: [
        .target(name: "SpeakerCore"),
        .target(name: "SpeakerProviderEvidence"),
        .target(
            name: "SpeakerAppFeatures",
            dependencies: ["SpeakerCore"]
        ),
        .executableTarget(
            name: "SpeakerApp",
            dependencies: [
                "SpeakerCore",
                "SpeakerAppFeatures",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .executableTarget(
            name: "SpeakerCoreSpecs",
            dependencies: ["SpeakerCore"],
            path: "Tests/SpeakerCoreSpecs"
        ),
        .executableTarget(
            name: "SpeakerAppScenarioSpecs",
            dependencies: ["SpeakerCore", "SpeakerAppFeatures"],
            path: "Tests/SpeakerAppScenarioTests"
        ),
        .executableTarget(
            name: "SpeakerAppUISpecs",
            dependencies: ["SpeakerAppFeatures", "SpeakerCore"],
            path: "Tests/SpeakerAppUISpecs"
        ),
        .executableTarget(
            name: "SpeakerBrandAssetGenerator",
            dependencies: ["SpeakerAppFeatures"],
            path: "Tools/SpeakerBrandAssetGenerator"
        ),
        .executableTarget(
            name: "SpeakerProviderSmoke",
            dependencies: ["SpeakerCore", "SpeakerProviderEvidence"],
            path: "Tools/SpeakerProviderSmoke"
        ),
        .executableTarget(
            name: "SpeakerProviderEvidenceVerifier",
            dependencies: ["SpeakerProviderEvidence"],
            path: "Tools/SpeakerProviderEvidenceVerifier"
        ),
        .executableTarget(
            name: "SpeakerProviderEvidenceSpecs",
            dependencies: ["SpeakerProviderEvidence"],
            path: "Tests/SpeakerProviderEvidenceSpecs"
        ),
        .executableTarget(
            name: "SpeakerDeliverySmokeTarget",
            path: "Tools/SpeakerDeliverySmokeTarget"
        ),
        .executableTarget(
            name: "SpeakerUpdateSignatureVerifier",
            path: "Tools/SpeakerUpdateSignatureVerifier"
        ),
        .executableTarget(
            name: "SpeakerReleaseEvidenceProtector",
            path: "Tools/SpeakerReleaseEvidenceProtector"
        ),
    ]
)
