// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "featurevisor-swift2",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
    ],
    products: [
        .library(
            name: "Featurevisor",
            targets: ["Featurevisor"]
        ),
        .library(
            name: "FeaturevisorOpenFeature",
            targets: ["FeaturevisorOpenFeature"]
        ),
        .executable(
            name: "featurevisor",
            targets: ["FeaturevisorCLI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/open-feature/swift-sdk.git", .upToNextMinor(from: "0.7.0"))
    ],
    targets: [
        .target(
            name: "Featurevisor",
            path: "Sources/Featurevisor"
        ),
        .target(
            name: "FeaturevisorOpenFeature",
            dependencies: [
                "Featurevisor",
                .product(name: "OpenFeature", package: "swift-sdk")
            ],
            path: "Sources/FeaturevisorOpenFeature"
        ),
        .executableTarget(
            name: "FeaturevisorCLI",
            dependencies: ["Featurevisor"],
            path: "Sources/FeaturevisorCLI"
        ),
        .testTarget(
            name: "FeaturevisorTests",
            dependencies: ["Featurevisor"],
            path: "Tests/FeaturevisorTests"
        ),
        .testTarget(
            name: "FeaturevisorOpenFeatureTests",
            dependencies: [
                "FeaturevisorOpenFeature",
                .product(name: "OpenFeature", package: "swift-sdk")
            ],
            path: "Tests/FeaturevisorOpenFeatureTests",
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "FeaturevisorCLITests",
            dependencies: ["FeaturevisorCLI", "Featurevisor"],
            path: "Tests/FeaturevisorCLITests"
        ),
    ]
)
