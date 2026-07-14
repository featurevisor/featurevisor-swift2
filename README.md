# Featurevisor Swift SDK <!-- omit in toc -->

This is a port of Featurevisor [Javascript SDK](https://featurevisor.com/docs/sdks/javascript/) v3.x to Swift, providing a way to evaluate feature flags, variations, and variables in your Swift applications.

This SDK is compatible with [Featurevisor](https://featurevisor.com/) v3.0 projects and v2 datafiles.

## Table of contents <!-- omit in toc -->

- [Installation](#installation)
- [Public API](#public-api)
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
  - [Merging by default](#merging-by-default)
  - [Replacing](#replacing)
  - [Loading datafiles on demand](#loading-datafiles-on-demand)
  - [Updating datafile](#updating-datafile)
  - [Interval-based update](#interval-based-update)
- [Diagnostics](#diagnostics)
  - [Levels](#levels)
  - [Handler](#handler)
- [Events](#events)
  - [`datafile_set`](#datafile_set)
  - [`context_set`](#context_set)
  - [`sticky_set`](#sticky_set)
  - [`error`](#error)
- [Evaluation details](#evaluation-details)
- [Modules](#modules)
  - [Defining a module](#defining-a-module)
  - [Registering modules](#registering-modules)
- [Child instance](#child-instance)
- [Close](#close)
- [OpenFeature](#openfeature)
- [CLI usage](#cli-usage)
  - [Test](#test)
  - [Benchmark](#benchmark)
  - [Assess distribution](#assess-distribution)
- [Development of this package](#development-of-this-package)
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

## Public API

The main runtime API is `createFeaturevisor()`:

```swift
let f: Featurevisor = createFeaturevisor(
    FeaturevisorOptions(datafile: datafileContent)
)
```

Most applications only need `createFeaturevisor`, `Featurevisor`, and `FeaturevisorOptions`. Public extension and observability types include `FeaturevisorModule`, `FeaturevisorDiagnostic`, and the datafile model types.

## Initialization

The SDK can be initialized by passing [datafile](https://featurevisor.com/docs/building-datafiles/) content directly:

```swift
import Foundation
import Featurevisor

let datafileURL = URL(string: "https://cdn.yoursite.com/datafile.json")!
let data = try Data(contentsOf: datafileURL)
let datafileContent = try DatafileContent.fromData(data)

let f = createFeaturevisor(
    FeaturevisorOptions(
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
let f = createFeaturevisor(
    FeaturevisorOptions(
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

Type specific methods do not coerce strings or booleans into numbers. They return `nil` when the value does not match the requested type.

## Getting all evaluations

You can get evaluations of all features available in the SDK instance:

```swift
let allEvaluations = f.getAllEvaluations([:])
print(allEvaluations)
```

This is handy especially when you want to pass all evaluations from a backend application to the frontend.

## Sticky

For the lifecycle of the SDK instance in your application, you can set some features with sticky values, meaning that they will not be evaluated against the fetched [datafile](https://featurevisor.com/docs/building-datafiles/):

Sticky values belong to an SDK or child instance. Evaluation options do not accept sticky overrides; use `SpawnOptions(sticky: ...)` when a child needs its own sticky state.

### Initialize with sticky

```swift
let f = createFeaturevisor(
    FeaturevisorOptions(
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

### Merging by default

By default, `setDatafile` merges the incoming datafile with the SDK instance's existing datafile:

- incoming `features` and `segments` override matching keys
- existing `features` and `segments` that are missing from the incoming datafile are kept
- `revision`, `schemaVersion`, and `featurevisorVersion` are taken from the incoming datafile

This means you can call `setDatafile` more than once with different datafiles, and the SDK instance accumulates their features and segments together.

### Replacing

Pass `replace: true` to replace the stored datafile entirely:

```swift
f.setDatafile(datafileContent, replace: true)
f.setDatafile(json: jsonString, replace: true)
```

### Loading datafiles on demand

Because merging is the default, a single SDK instance can start with a small datafile and load more datafiles later as your application needs them, instead of downloading every feature upfront.

This pairs well with [targets](https://featurevisor.com/docs/targets/), where each target produces a smaller datafile for a specific part of your application:

```swift
let f = createFeaturevisor(FeaturevisorOptions())

func loadDatafile(target: String) {
    let url = URL(string: "https://cdn.yoursite.com/production/featurevisor-\(target).json")!
    if let data = try? Data(contentsOf: url),
       let datafile = try? DatafileContent.fromData(data) {
        // merges into whatever was loaded before
        f.setDatafile(datafile)
    }
}

loadDatafile(target: "products")

// later, when the user reaches checkout
loadDatafile(target: "checkout")
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

## Diagnostics

By default, Featurevisor reports diagnostics to the console for `info` level and above with a `[Featurevisor]` prefix.

### Levels

Available diagnostic levels are `fatal`, `error`, `warn`, `info`, and `debug`.

Set the level during initialization or update it afterwards:

```swift
let f = createFeaturevisor(
    FeaturevisorOptions(logLevel: .debug)
)

f.setLogLevel(.info)
```

### Handler

Use `onDiagnostic` to send structured diagnostics to your observability system:

```swift
let f = createFeaturevisor(
    FeaturevisorOptions(
        logLevel: .info,
        onDiagnostic: { diagnostic in
            print(diagnostic.level, diagnostic.code, diagnostic.message)
        }
    )
)
```

Modules can also subscribe to diagnostics or report their own diagnostics from `setup` using the provided module API.

Every diagnostic has `level`, `code`, `message`, and an object-shaped `details` dictionary. Optional `module`, `moduleName`, and `originalError` fields describe provenance. Evaluation metadata belongs in `details`.


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

### `error`

```swift
let unsubscribe = f.on(.error) { payload in
    if case .object(let diagnostic)? = payload.params["diagnostic"] {
        print(diagnostic["message"] ?? "")
    }
}

unsubscribe()
```

The `error` event is emitted for diagnostics whose level is `error`.

## Evaluation details

If you need evaluation metadata, use:

```swift
let flagDetails = f.evaluateFlag("my_feature")
let variationDetails = f.evaluateVariation("my_feature")
let variableDetails = f.evaluateVariable("my_feature", "my_variable")
```

## Modules

Modules allow you to intercept evaluation inputs and outputs.

### Defining a module

```swift
let module = FeaturevisorModule(
    name: "my-module",
    setup: { api in
        api.reportDiagnostic(
            FeaturevisorDiagnostic(
                level: .info,
                code: "module_ready",
                message: "Module is ready"
            )
        )
    },
    before: { options in
        var updated = options
        updated.dependencies.context["someAdditionalAttribute"] = .string("value")
        return updated
    },
    bucketKey: { options in
        options.bucketKey
    },
    bucketValue: { options in
        options.bucketValue
    },
    after: { evaluation, _ in
        evaluation
    },
    close: {
        // clean up module resources
    }
)
```

### Registering modules

```swift
let f = createFeaturevisor(
    FeaturevisorOptions(
        modules: [module]
    )
)

let removeModule = f.addModule(module)
removeModule?()
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

All three commands accept repeatable `--target=<target>` options. `test` builds only the selected Target datafiles and runs untargeted assertions plus assertions for those targets. `benchmark` and `assess-distribution` run independently against every selected Target datafile. Without `--target`, existing project-wide behavior is preserved. Project definitions, test specs, Target discovery, and datafile generation continue to come from the Node.js CLI.

### Test

```bash
swift run featurevisor test \
  --projectDirectoryPath=/path/to/featurevisor-project
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

## OpenFeature

The package exposes `FeaturevisorOpenFeature` as a separate library product. Add both products to targets that use OpenFeature:

```swift
.product(name: "Featurevisor", package: "featurevisor-swift2"),
.product(name: "FeaturevisorOpenFeature", package: "featurevisor-swift2")
```

```swift
import Featurevisor
import FeaturevisorOpenFeature
import OpenFeature

let provider = FeaturevisorOpenFeatureProvider(
    options: FeaturevisorOptions(datafile: datafile)
)

await OpenFeatureAPI.shared.setProviderAndWait(
    provider: provider,
    initialContext: ImmutableContext(targetingKey: "user-123")
)

let client = OpenFeatureAPI.shared.getClient()
let enabled = client.getBooleanValue(
    key: "checkout",
    defaultValue: false
)
```

Use `checkout` for a flag, `checkout:variation` for its variation, and `checkout:title` for its `title` variable. Boolean variables use the boolean resolver. Lists, structures, and JSON variables use the object resolver.

OpenFeature's targeting key maps to `userId` by default. `targetingKeyField`, `keySeparator`, and `variationKey` can customize the mapping. Call `provider.close()` when the application owns the provider lifecycle and is finished with it.

You can also reuse an existing Featurevisor instance:

```swift
let featurevisor = createFeaturevisor(FeaturevisorOptions(datafile: datafile))
let provider = FeaturevisorOpenFeatureProvider(featurevisor: featurevisor)
```

The caller owns an instance passed this way. Closing the provider does not close it. Call `featurevisor.close()` when every consumer is finished with it. When the provider creates the instance from `options`, the provider owns and closes it. If both are supplied, `featurevisor` takes precedence over `options`.

See the [OpenFeature provider guide](https://featurevisor.com/docs/sdks/openfeature/) for resolution reasons, errors, metadata, tracking, lifecycle, and providers for other languages.

<!-- FEATUREVISOR_DOCS_END -->

## Development of this package

### Running tests

```bash
swift test
```

To verify against the local Featurevisor example-1 project:

```bash
make test-example-1
```

## License

MIT © [Fahad Heylaal](https://fahad19.com)
