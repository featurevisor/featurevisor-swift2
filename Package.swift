// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "featurevisor-swift2",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "Featurevisor",
            targets: ["Featurevisor"]
        ),
        .executable(
            name: "featurevisor",
            targets: ["FeaturevisorCLI"]
        ),
    ],
    targets: [
        .target(
            name: "Featurevisor",
            path: "Sources/Featurevisor"
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
            name: "FeaturevisorCLITests",
            dependencies: ["FeaturevisorCLI", "Featurevisor"],
            path: "Tests/FeaturevisorCLITests"
        ),
    ]
)
