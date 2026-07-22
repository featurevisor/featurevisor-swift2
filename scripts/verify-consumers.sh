#!/usr/bin/env bash

set -euo pipefail

package_path="$(cd "$(dirname "$0")/.." && pwd)"
work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT

create_consumer() {
  local name="$1"
  local dependencies="$2"
  local products="$3"
  local imports="$4"
  local source="$5"
  local directory="$work_directory/$name"

  mkdir -p "$directory/Sources/$name"
  cat > "$directory/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "$name",
    platforms: [.macOS(.v11)],
    dependencies: [$dependencies],
    targets: [
        .executableTarget(
            name: "$name",
            dependencies: [$products]
        )
    ]
)
EOF
  cat > "$directory/Sources/$name/main.swift" <<EOF
$imports

$source
EOF
  swift build --package-path "$directory"
}

create_consumer \
  "CoreConsumer" \
  '.package(path: "'"$package_path"'")' \
  '.product(name: "Featurevisor", package: "featurevisor-swift2")' \
  'import Featurevisor' \
  'let featurevisor = createFeaturevisor(); print(featurevisor.getRevision())'

create_consumer \
  "OpenFeatureConsumer" \
  '.package(path: "'"$package_path"'"), .package(url: "https://github.com/open-feature/swift-sdk.git", from: "0.5.0")' \
  '.product(name: "Featurevisor", package: "featurevisor-swift2"), .product(name: "FeaturevisorOpenFeature", package: "featurevisor-swift2"), .product(name: "OpenFeature", package: "swift-sdk")' \
  $'import Featurevisor\nimport FeaturevisorOpenFeature\nimport OpenFeature' \
  'let provider = FeaturevisorOpenFeatureProvider(); print(provider.metadata.name ?? "Featurevisor")'
