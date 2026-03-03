// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "featurevisor-swift2",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "FeaturevisorSDK",
            targets: ["FeaturevisorSDK"]
        ),
        .executable(
            name: "featurevisor-swift",
            targets: ["FeaturevisorCLI"]
        ),
    ],
    targets: [
        .target(
            name: "FeaturevisorSDK",
            path: "Sources/FeaturevisorSDK"
        ),
        .executableTarget(
            name: "FeaturevisorCLI",
            dependencies: ["FeaturevisorSDK"],
            path: "Sources/FeaturevisorCLI"
        ),
        .testTarget(
            name: "FeaturevisorSDKTests",
            dependencies: ["FeaturevisorSDK"],
            path: "Tests/FeaturevisorSDKTests"
        ),
        .testTarget(
            name: "FeaturevisorCLITests",
            dependencies: ["FeaturevisorCLI", "FeaturevisorSDK"],
            path: "Tests/FeaturevisorCLITests"
        ),
    ]
)
