# Featurevisor Swift SDK v2 (`featurevisor-swift2`)

Swift port of Featurevisor JavaScript SDK v2, with a Swift Package containing:

- `FeaturevisorSDK`: core SDK and shared types
- `featurevisor-swift`: CLI for testing, benchmarking and distribution checks

Compatible with Featurevisor v2 projects and above.

## Installation

Add this package to your Swift project using Swift Package Manager.

```swift
.package(url: "https://github.com/featurevisor/featurevisor-swift2.git", from: "0.1.0")
```

Then import:

```swift
import FeaturevisorSDK
```

## Initialization

```swift
import FeaturevisorSDK

let datafile = try DatafileContent.fromJSON(jsonString)

let f = createInstance(
    InstanceOptions(
        datafile: datafile,
        context: [
            "userId": .string("123"),
            "country": .string("nl"),
        ]
    )
)
```

## Evaluate

```swift
let enabled = f.isEnabled("my_feature")
let variation = f.getVariation("my_feature")
let color = f.getVariableString("my_feature", "bgColor")
```

## Context

```swift
f.setContext(["userId": .string("234")]) // merge
f.setContext(["userId": .string("999")], replace: true) // replace
```

## Sticky

```swift
f.setSticky([
    "my_feature": EvaluatedFeature(
        enabled: true,
        variation: "treatment",
        variables: ["bgColor": .string("blue")]
    )
])
```

## Datafile Helpers

```swift
let datafile = try DatafileContent.fromJSON(jsonString)
let pretty = try datafile.toJSON(pretty: true)
```

## CLI Usage

Build and run CLI:

```bash
swift run featurevisor-swift test --projectDirectoryPath=/path/to/featurevisor-project
swift run featurevisor-swift benchmark --projectDirectoryPath=/path/to/featurevisor-project --environment=production --feature=my_feature --context='{"userId":"123"}' --n=1000
swift run featurevisor-swift assess-distribution --projectDirectoryPath=/path/to/featurevisor-project --environment=production --feature=my_feature --populateUuid=userId --n=1000
```

`test` supports:

- `--with-scopes`
- `--with-tags`
- `--keyPattern=...`
- `--assertionPattern=...`
- `--onlyFailures`
- `--showDatafile`
- `--inflate=...`
- `--schema-version=...`

## Run tests

```bash
swift test
```

## Test against example-1

```bash
swift run featurevisor-swift test \
  --projectDirectoryPath=$(pwd)/monorepo/examples/example-1 \
  --with-scopes \
  --with-tags
```

## Development status

This repository now includes the full package structure and core SDK/CLI implementation. Remaining work is focused on deep parity with every TypeScript unit test and exact command output parity.

## License

MIT (same as Featurevisor project). See [LICENSE](LICENSE).
