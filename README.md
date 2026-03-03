# Featurevisor Swift SDK <!-- omit in toc -->

This is a port of Featurevisor [Javascript SDK](https://featurevisor.com/docs/sdks/javascript/) v2.x to Swift, providing a way to evaluate feature flags, variations, and variables in your Swift applications.

This SDK is compatible with [Featurevisor](https://featurevisor.com/) v2.0 projects and above.

## Table of contents <!-- omit in toc -->

- [Installation](#installation)
- [Initialization](#initialization)
- [Evaluation types](#evaluation-types)
- [Context](#context)
  - [Setting initial context](#setting-initial-context)
  - [Setting after initialization](#setting-after-initialization)
  - [Replacing existing context](#replacing-existing-context)
  - [Manually passing context](#manually-passing-context)
- [Check if enabled](#check-if-enabled)
- [Getting variation](#getting-variation)
- [Getting variables](#getting-variables)
  - [Type specific methods](#type-specific-methods)
- [Getting all evaluations](#getting-all-evaluations)
- [Sticky](#sticky)
  - [Initialize with sticky](#initialize-with-sticky)
  - [Set sticky afterwards](#set-sticky-afterwards)
- [Setting datafile](#setting-datafile)
  - [Updating datafile](#updating-datafile)
  - [Interval-based update](#interval-based-update)
- [Logging](#logging)
  - [Levels](#levels)
  - [Customizing levels](#customizing-levels)
- [Events](#events)
  - [`datafile_set`](#datafile_set)
  - [`context_set`](#context_set)
  - [`sticky_set`](#sticky_set)
- [Evaluation details](#evaluation-details)
- [Hooks](#hooks)
  - [Defining a hook](#defining-a-hook)
  - [Registering hooks](#registering-hooks)
- [Child instance](#child-instance)
- [Close](#close)
- [CLI usage](#cli-usage)
  - [Test](#test)
  - [Benchmark](#benchmark)
  - [Assess distribution](#assess-distribution)
- [Development of this package](#development-of-this-package)
  - [Setting up](#setting-up)
  - [Running tests](#running-tests)
- [License](#license)

<!-- FEATUREVISOR_DOCS_BEGIN -->

## Installation

In your Swift application, add this package using Swift Package Manager:

```swift
.package(url: "https://github.com/featurevisor/featurevisor-swift2.git", from: "0.1.0")
```

Then add the product dependency:

```swift
.product(name: "Featurevisor", package: "featurevisor-swift2")
```

## Initialization

The SDK can be initialized by passing [datafile](https://featurevisor.com/docs/building-datafiles/) content directly:

```swift
import Foundation
import Featurevisor

let datafileURL = URL(string: "https://cdn.yoursite.com/datafile.json")!
let data = try Data(contentsOf: datafileURL)
let datafileContent = try DatafileContent.fromData(data)

let f = createInstance(
    InstanceOptions(
        datafile: datafileContent
    )
)
```

## Evaluation types

We can evaluate 3 types of values against a particular [feature](https://featurevisor.com/docs/features/):

- [**Flag**](#check-if-enabled) (`Bool`): whether the feature is enabled or not
- [**Variation**](#getting-variation) (`String`): the variation of the feature (if any)
- [**Variables**](#getting-variables): variable values of the feature (if any)

These evaluations are run against the provided context.

## Context

Contexts are [attribute](https://featurevisor.com/docs/attributes) values that we pass to SDK for evaluating [features](https://featurevisor.com/docs/features) against.

Think of the conditions that you define in your [segments](https://featurevisor.com/docs/segments/), which are used in your feature's [rules](https://featurevisor.com/docs/features/#rules).

They are plain dictionaries:

```swift
let context: Context = [
    "userId": .string("123"),
    "country": .string("nl"),
]
```

### Setting initial context

You can set context at the time of initialization:

```swift
let f = createInstance(
    InstanceOptions(
        context: [
            "deviceId": .string("123"),
            "country": .string("nl"),
        ]
    )
)
```

### Setting after initialization

You can also set more context after the SDK has been initialized:

```swift
f.setContext([
    "userId": .string("234"),
])
```

This will merge the new context with the existing one (if already set).

### Replacing existing context

If you wish to fully replace the existing context, you can pass `true` in second argument:

```swift
f.setContext(
    [
        "deviceId": .string("123"),
        "userId": .string("234"),
        "country": .string("nl"),
        "browser": .string("chrome"),
    ],
    replace: true
)
```

### Manually passing context

You can optionally pass additional context manually for each and every evaluation separately, without needing to set it to the SDK instance affecting all evaluations:

```swift
let context: Context = [
    "userId": .string("123"),
    "country": .string("nl"),
]

let isEnabled = f.isEnabled("my_feature", context)
let variation = f.getVariation("my_feature", context)
let variableValue = f.getVariable("my_feature", "my_variable", context)
```

When manually passing context, it will merge with existing context set to the SDK instance before evaluating the specific value.

## Check if enabled

Once the SDK is initialized, you can check if a feature is enabled or not:

```swift
let featureKey = "my_feature"

let isEnabled = f.isEnabled(featureKey)

if isEnabled {
    // do something
}
```

You can also pass additional context per evaluation:

```swift
let isEnabled = f.isEnabled(featureKey, [
    // ...additional context
])
```

## Getting variation

If your feature has any [variations](https://featurevisor.com/docs/features/#variations) defined, you can evaluate them as follows:

```swift
let featureKey = "my_feature"

let variation = f.getVariation(featureKey)

if variation == "treatment" {
    // do something for treatment variation
} else {
    // handle default/control variation
}
```

Additional context per evaluation can also be passed:

```swift
let variation = f.getVariation(featureKey, [
    // ...additional context
])
```

## Getting variables

Your features may also include [variables](https://featurevisor.com/docs/features/#variables), which can be evaluated as follows:

```swift
let variableKey = "bgColor"
let bgColorValue = f.getVariable("my_feature", variableKey)
```

Additional context per evaluation can also be passed:

```swift
let bgColorValue = f.getVariable("my_feature", variableKey, [
    // ...additional context
])
```

### Type specific methods

Next to generic `getVariable()` methods, there are also type specific methods available for convenience:

```swift
f.getVariableBoolean(featureKey, variableKey, context)
f.getVariableString(featureKey, variableKey, context)
f.getVariableInteger(featureKey, variableKey, context)
f.getVariableDouble(featureKey, variableKey, context)
f.getVariableArray(featureKey, variableKey, context)
f.getVariableObject(featureKey, variableKey, context)
f.getVariableJSON(featureKey, variableKey, context)
```

## Getting all evaluations

You can get evaluations of all features available in the SDK instance:

```swift
let allEvaluations = f.getAllEvaluations([:])
print(allEvaluations)
```

This is handy especially when you want to pass all evaluations from a backend application to the frontend.

## Sticky

For the lifecycle of the SDK instance in your application, you can set some features with sticky values, meaning that they will not be evaluated against the fetched [datafile](https://featurevisor.com/docs/building-datafiles/):

### Initialize with sticky

```swift
let f = createInstance(
    InstanceOptions(
        sticky: [
            "myFeatureKey": EvaluatedFeature(
                enabled: true,
                variation: "treatment",
                variables: ["myVariableKey": .string("myVariableValue")]
            ),
            "anotherFeatureKey": EvaluatedFeature(enabled: false),
        ]
    )
)
```

### Set sticky afterwards

```swift
f.setSticky([
    "myFeatureKey": EvaluatedFeature(
        enabled: true,
        variation: "treatment",
        variables: ["myVariableKey": .string("myVariableValue")]
    ),
    "anotherFeatureKey": EvaluatedFeature(enabled: false),
], replace: true)
```

## Setting datafile

You may also initialize the SDK without passing `datafile`, and set it later on:

```swift
f.setDatafile(datafileContent)
```

You can also set using raw JSON string:

```swift
f.setDatafile(json: jsonString)
```

### Updating datafile

You can set the datafile as many times as you want in your application, which will result in emitting a [`datafile_set`](#datafile_set) event that you can listen and react to accordingly.

### Interval-based update

```swift
import Foundation

let interval: TimeInterval = 5 * 60
Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
    if let data = try? Data(contentsOf: datafileURL),
       let datafile = try? DatafileContent.fromData(data) {
        f.setDatafile(datafile)
    }
}
```

## Logging

By default, Featurevisor SDK logs from `info` level and above.

### Levels

These are available log levels:

- `debug`
- `info`
- `warn`
- `error`
- `fatal`

### Customizing levels

You can set log level at initialization:

```swift
let f = createInstance(
    InstanceOptions(
        logLevel: .debug
    )
)
```

Or set it afterwards:

```swift
f.setLogLevel(.debug)
```

## Events

Featurevisor SDK implements a simple event emitter that allows you to listen to runtime events.

### `datafile_set`

```swift
let unsubscribe = f.on(.datafileSet) { payload in
    print(payload.params)
}

unsubscribe()
```

### `context_set`

```swift
let unsubscribe = f.on(.contextSet) { _ in
    // handle context updates
}

unsubscribe()
```

### `sticky_set`

```swift
let unsubscribe = f.on(.stickySet) { _ in
    // handle sticky updates
}

unsubscribe()
```

## Evaluation details

If you need evaluation metadata, use:

```swift
let flagDetails = f.evaluateFlag("my_feature")
let variationDetails = f.evaluateVariation("my_feature")
let variableDetails = f.evaluateVariable("my_feature", "my_variable")
```

## Hooks

Hooks allow you to intercept evaluation inputs and outputs.

### Defining a hook

```swift
let hook = Hook(
    name: "my-hook",
    before: { input in
        input
    },
    after: { evaluation, _ in
        evaluation
    }
)
```

### Registering hooks

```swift
let f = createInstance(
    InstanceOptions(
        hooks: [hook]
    )
)

let removeHook = f.addHook(hook)
removeHook()
```

## Child instance

You can spawn child instances with inherited context:

```swift
let child = f.spawn([
    "userId": .string("123"),
])

let enabled = child.isEnabled("my_feature")
```

## Close

To clear listeners and close resources:

```swift
f.close()
```

## CLI usage

The package also ships an executable named `featurevisor`.

### Test

```bash
swift run featurevisor test \
  --projectDirectoryPath=/path/to/featurevisor-project
```

With scoped and tagged datafiles:

```bash
swift run featurevisor test \
  --projectDirectoryPath=/path/to/featurevisor-project \
  --with-scopes \
  --with-tags
```

### Benchmark

```bash
swift run featurevisor benchmark \
  --projectDirectoryPath=/path/to/featurevisor-project \
  --environment=production \
  --feature=my_feature \
  --context='{"userId":"123"}' \
  --n=1000
```

### Assess distribution

```bash
swift run featurevisor assess-distribution \
  --projectDirectoryPath=/path/to/featurevisor-project \
  --environment=production \
  --feature=my_feature \
  --populateUuid=userId \
  --n=1000
```

<!-- FEATUREVISOR_DOCS_END -->

## Development of this package

### Setting up

This repo includes `monorepo/` and `featurevisor-go/` references. To refresh:

```bash
make update-references
```

### Running tests

```bash
swift test
```

## License

MIT © [Fahad Heylaal](https://fahad19.com)
