# Featurevisor Swift SDK <!-- omit in toc -->

Use the Featurevisor Swift SDK to evaluate flags, variations and variables in Swift applications.

## Table of contents <!-- omit in toc -->

- [Installation](#installation)
- [Initialization](#initialization)
  - [Public API](#public-api)
  - [Evaluation types](#evaluation-types)
- [Context](#context)
  - [Setting initial context](#setting-initial-context)
  - [Setting after initialization](#setting-after-initialization)
  - [Replacing existing context](#replacing-existing-context)
  - [Manually passing context](#manually-passing-context)
- [Check if enabled](#check-if-enabled)
- [Getting variation](#getting-variation)
- [Getting variables](#getting-variables)
  - [Getting feature variables](#getting-feature-variables)
  - [Type specific methods](#type-specific-methods)
  - [Getting global variables](#getting-global-variables)
- [Conditions](#conditions)
- [Composed variables](#composed-variables)
- [Getting evaluations](#getting-evaluations)
- [Sticky](#sticky)
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
  - [`sticky_features_set` and `sticky_variables_set`](#sticky_features_set-and-sticky_variables_set)
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
- [GitHub repositories](#github-repositories)
- [Development of this package](#development-of-this-package)
  - [Running tests](#running-tests)
- [License](#license)

<!-- FEATUREVISOR_DOCS_BEGIN -->

## Installation

Upgrading an existing application? Follow the [Swift migration guide](https://featurevisor.com/docs/migrations/v4/swift/).

In your Swift application, add this package using Swift Package Manager:

```swift
.package(url: "https://github.com/featurevisor/featurevisor-swift2.git", from: "4.0.0")
```

Then add the product dependency:

```swift
.product(name: "Featurevisor", package: "featurevisor-swift2")
```

## Initialization

Fetch a [datafile](https://featurevisor.com/docs/building-datafiles/) asynchronously before creating the SDK instance:

```swift
import Foundation
import Featurevisor

let datafileURL = URL(string: "https://cdn.yoursite.com/featurevisor-all.json")!
let initializationTask = Task {
    let (data, response) = try await URLSession.shared.data(from: datafileURL)
    guard let response = response as? HTTPURLResponse,
          (200..<300).contains(response.statusCode) else {
        throw URLError(.badServerResponse)
    }
    let datafileContent = try DatafileContent.fromData(data)
    try Task.checkCancellation()

    return createFeaturevisor(
        FeaturevisorOptions(datafile: datafileContent)
    )
}

let f = try await initializationTask.value
defer { f.close() }

print(f.isEnabled("checkout", ["userId": .string("123")]))
```

This example closes the instance after one evaluation. In an application, retain it until shutdown.

Await the task from an asynchronous application lifecycle and handle loading errors there before evaluating features. [URLSession's async API](https://developer.apple.com/documentation/foundation/urlsession/data(from:delegate:)) suspends while fetching rather than blocking the calling thread. Retain the task handle if the owner may need to cancel loading with `initializationTask.cancel()`.

### Public API

The main runtime API is `createFeaturevisor()`:

```swift
let f: Featurevisor = createFeaturevisor(
    FeaturevisorOptions(datafile: datafileContent)
)
```

Most applications only need `createFeaturevisor`, `Featurevisor`, and `FeaturevisorOptions`. Public extension and observability types include `FeaturevisorModule`, `FeaturevisorDiagnostic`, and the datafile model types.

The SDK needs Swift 6.1 or later, which Xcode 16.3 and later include. It supports iOS 15, macOS 12, tvOS 15, and watchOS 8 or newer. Shared `Featurevisor`, child instance, and OpenFeature provider state is safe to use from concurrent callers. Module, diagnostic, event, and tracking callbacks are `@Sendable`. Callback implementations must synchronize any mutable state they capture.

These minimums follow the optional OpenFeature Swift SDK 0.7 integration. Applications selecting only the `Featurevisor` product do not link OpenFeature.

See the [SwiftUI iOS example application](https://github.com/featurevisor/featurevisor-example-ios) for a small application that fetches a datafile and evaluates a flag, variation, and variable.

### Evaluation types

Featurevisor evaluates four kinds of values:

- [**Flag**](#check-if-enabled) (`Bool`): whether the feature is enabled or not
- [**Variation**](#getting-variation) (`String`): the variation of the feature (if any)
- [**Feature variable**](#getting-feature-variables): a configuration value owned by a feature
- [**Global variable**](#getting-global-variables): a configuration value evaluated independently of a feature

These evaluations are run against the provided context.

## Context

Contexts are [attribute](https://featurevisor.com/docs/attributes) values you pass to the SDK for evaluating [features](https://featurevisor.com/docs/features) against.

Conditions compare these attributes using the [operators](https://featurevisor.com/docs/operators/), including `empty` and `notEmpty`.

Date comparisons accept [portable timestamp strings](https://featurevisor.com/docs/operators/#timestamps), not Foundation `Date` values. Include a time and an explicit timezone. Both `before` and `after` are strict and return `false` for invalid inputs.

They are plain dictionaries:

```swift
let context: Context = [
    "userId": .string("123"),
    "country": .string("nl"),
]
```

### Setting initial context

Set context when you create the instance:

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

Add context later:

```swift
f.setContext([
    "userId": .string("234"),
])
```

This will merge the new context with the existing one (if already set).

### Replacing existing context

Replace the context by passing `replace: true`:

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

Pass context to one evaluation without changing the instance context:

```swift
let context: Context = [
    "userId": .string("123"),
    "country": .string("nl"),
]

let isEnabled = f.isEnabled("checkout", context)
let variation = f.getVariation("checkout", context)
let variableValue = f.getVariable("checkout", "bgColor", context)
```

When manually passing context, it will merge with existing context set to the SDK instance before evaluating the specific value.

## Check if enabled

Check whether a feature is enabled:

```swift
let featureKey = "checkout"

let isEnabled = f.isEnabled(featureKey)

if isEnabled {
    // do something
}
```

Pass additional context to one evaluation:

```swift
let isEnabled = f.isEnabled(featureKey, [
    // ...additional context
])
```

## Getting variation

Evaluate a feature's [variations](https://featurevisor.com/docs/features/#variations):

```swift
let featureKey = "checkout"

let variation = f.getVariation(featureKey)

if variation == "treatment" {
    // do something for treatment variation
} else {
    // handle default/control variation
}
```

Pass additional context to one evaluation:

```swift
let variation = f.getVariation(featureKey, [
    // ...additional context
])
```

## Getting variables

### Getting feature variables

Evaluate a feature's [variables](https://featurevisor.com/docs/features/#variables):

```swift
let variableKey = "bgColor"
let bgColorValue = f.getVariable("checkout", variableKey)
```

Pass additional context to one evaluation:

```swift
let bgColorValue = f.getVariable("checkout", variableKey, [
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

### Getting global variables

Global variables use the same methods with a single variable key:

```swift
let message = f.getVariableString("welcomeMessage", context)
let value = f.getVariable("checkoutSettings", context)
let evaluation = f.evaluateVariable("checkoutSettings", context: context)
```

Conditions, composition and overrides are applied for you. See [Variables](https://featurevisor.com/docs/variables/#global-variables) and [Conditions](https://featurevisor.com/docs/conditions/) for how to define them.

To see which overrides changed a value, read `variableOverridePaths` from `evaluateVariable`.

## Conditions

Generated schema 4 datafiles use `conditions` for segments, feature and global variable gates, force entries, traffic and variable overrides. Conditions compare attributes, reference segment keys, check feature enabled state and variations, or compare global and feature variable getters. Variable paths are compiled arrays of property names and array indices, not authored dotted paths. Variable keys remain literal.

Arrays imply AND. Logical `and`, `or` and `not` groups preserve order and short circuiting. NOT negates the AND of its direct children. Empty expressions are false. A feature leaf defaults to enabled `true`. A variable leaf can include its feature owner and distinguishes explicit null from a missing path. Ordinary getter fallbacks and modules apply to these dependency reads without inheriting the outer caller default.

Sticky state precedes all gates. Feature force entries run before the feature gate. Traffic runs afterwards. A missed feature gate reports `conditions_unmet` and `conditions` in the flag evaluation. Variation and feature variable getters keep their ordinary disabled value policies. A missed global variable gate returns its `disabledValue`, its default when `useDefaultWhenDisabled` is true, or `nil`.

The SDK reads existing schema 2 datafiles through eager normalization before merging. Schema 4 entities normalize lazily on first read. Normalization does not change caller data. Partial updates invalidate incoming entities only. Replacement clears all entity caches. The incoming schema version remains informational metadata.

Malformed stringified selector JSON fails that selector, including through negated segment references, without rejecting the datafile or disabling unrelated entities. `conditions_parse_error` is an error diagnostic with exactly `conditions`, `entityType` and `entityKey` in `details`. It occurs once per malformed selector per incoming entity load: during schema 2 setting after storage, or on the first schema 4 entity read after caching. Diagnostic callbacks can safely read the accepted revision or reenter getters.

## Composed variables

Use ordinary getters to read composed global variables:

```swift
let screen = f.getVariableObject("checkoutScreen", context)
let policy = f.getVariable("policyAlias", context)
let details = f.evaluateVariable("checkoutScreen", context: context)
```

A map composition assembles a fresh outer object whose literal properties read feature flags, variations, feature variables or global variables. A string composition is an alias of one literal global variable key and returns its source value directly. False, zero, empty strings, arrays and null remain values. JSON sources decode exactly once, even through alias chains returning strings such as `"null"`.

Compositions have no default value or `useDefaultWhenDisabled` policy. They may have root conditions and a `disabledValue`. A missed gate skips all sources and overrides, returning that disabled value or `nil`. Whole variable sticky state bypasses both the gate and sources. Successful compositions read every source before applying runtime overrides and mutations. Mutations copy changed paths without changing sources, sibling properties or sticky values.

Composition uses the effective context, child sticky state and module pipeline. Its detailed reason is `variable_composed`, or `variable_override_rule` when an override matches. Cycles and more than 256 internal dependency handoffs fail the complete evaluation. Each handoff also checks the remaining thread stack, so a chain too deep for the current thread fails with reason `error` rather than terminating the app. Dispatch and Swift concurrency threads have 512 KB, enough for about 33 handoffs in a release build and fewer in a debug build. Lint warns about chains deeper than 32. An ordinary completed false or null source getter remains a value rather than a failed gate. See [Compose values](https://featurevisor.com/docs/variables/#compose-values).

## Getting evaluations

Evaluate all features available in the instance:

```swift
let allEvaluations = f.getFeatureEvaluations([:])
print(allEvaluations)

let globalVariables = f.getVariableEvaluations([:])
```

This is handy especially when you want to pass all evaluations from a backend application to the frontend.

## Sticky

Set sticky values to take precedence over feature evaluation against the [datafile](https://featurevisor.com/docs/building-datafiles/):

Sticky values belong to an SDK or child instance. Feature sticky values and global variable sticky values are independent.

```swift
let f = createFeaturevisor(
    FeaturevisorOptions(
        stickyFeatures: [
            "checkout": EvaluatedFeature(
                enabled: true,
                variation: "treatment",
                variables: ["myVariableKey": .string("myVariableValue")]
            ),
            "anotherFeatureKey": EvaluatedFeature(enabled: false),
        ],
        stickyVariables: ["welcomeMessage": .string("Welcome back")]
    )
)
```

```swift
f.setStickyFeatures([
    "checkout": EvaluatedFeature(
        enabled: true,
        variation: "treatment",
        variables: ["myVariableKey": .string("myVariableValue")]
    ),
    "anotherFeatureKey": EvaluatedFeature(enabled: false),
], replace: true)

f.setStickyVariables(["welcomeMessage": .string("Welcome back")], replace: true)
```

## Setting datafile

You may also initialize the SDK without passing `datafile`, and set it later on:

```swift
f.setDatafile(datafileContent)
```

Set the datafile from a raw JSON string:

```swift
f.setDatafile(json: jsonString)
```

Both overloads return `true` when the datafile is accepted, including unchanged content, and `false` when the input is rejected or the instance is closed. Rejected input leaves the last accepted datafile in place and reports the existing diagnostic and error event, without a `datafile_set` event. Calls after closing do nothing. Accepted calls still emit `datafile_set`, even when nothing changed. The return value reports acceptance, not whether any features changed, and may be ignored.

```swift
let accepted = f.setDatafile(json: jsonString)
```

### Merging by default

By default, `setDatafile` merges the incoming datafile with the SDK instance's existing datafile:

- incoming `features`, `segments`, and global `variables` override matching keys
- existing `features`, `segments`, and global `variables` that are missing from the incoming datafile are kept
- `revision`, `schemaVersion`, and `featurevisorVersion` are taken from the incoming datafile

Call `setDatafile` with different datafiles to merge their features, segments, and global variables.

### Replacing

Pass `replace: true` to replace the stored datafile entirely:

```swift
f.setDatafile(datafileContent, replace: true)
f.setDatafile(json: jsonString, replace: true)
```

### Loading datafiles on demand

Merge datafiles for different [targets](https://featurevisor.com/docs/targets/) into the same instance. Here, the two datafile values have already been loaded and validated by your application from the same published release:

```swift
f.setDatafile(productsDatafile)
f.setDatafile(checkoutDatafile)
```

Use immutable release URLs, check HTTP responses and keep shared dependencies consistent. See [Loading datafiles on demand](https://featurevisor.com/docs/use-cases/on-demand-datafiles/) for the complete loading and refresh flow.

### Updating datafile

Each accepted datafile update emits a [`datafile_set`](#datafile-set) event. Subscribe to react to updates.

### Interval-based update

Replace the complete datafile on each refresh so definitions removed upstream are removed from the SDK too. Use merging only when loading partial datafiles intentionally.

Keep one refresh task per instance. This loop fetches asynchronously, then waits five minutes after each attempt, so slow requests cannot overlap. Failed requests, unsuccessful HTTP responses and datafiles that fail to decode leave the last accepted datafile in place.

```swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

let refreshTask = Task {
    while !Task.isCancelled {
        do {
            let (data, response) = try await URLSession.shared.data(from: datafileURL)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let datafile = try DatafileContent.fromData(data)
            try Task.checkCancellation()
            f.setDatafile(datafile, replace: true)
        } catch {
            if Task.isCancelled { return }
            print("Datafile refresh failed: \(error)")
        }

        do {
            try await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
        } catch {
            return
        }
    }
}
```

The async APIs above support the package's minimum targets: iOS 15, macOS 12, tvOS 15 and watchOS 8. Keep the task handle for the instance's lifetime. From an asynchronous shutdown path, cancel and await it before closing the instance or starting another refresh task:

```swift
refreshTask.cancel()
await refreshTask.value
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

Every diagnostic has `level`, `code`, `message`, and an object shaped `details` dictionary. Optional `module`, `moduleName`, and `originalError` fields describe provenance. Evaluation metadata belongs in `details`.

## Events

Subscribe to SDK events to respond to context, sticky state and datafile changes.

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

### `sticky_features_set` and `sticky_variables_set`

```swift
let featureUnsubscribe = f.on(.stickyFeaturesSet) { _ in
    // handle sticky feature updates
}

let variableUnsubscribe = f.on(.stickyVariablesSet) { _ in
    // handle sticky global variable updates
}

featureUnsubscribe()
variableUnsubscribe()
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
let flagDetails = f.evaluateFlag("checkout")
let variationDetails = f.evaluateVariation("checkout")
let variableDetails = f.evaluateVariable("checkout", "bgColor")
let globalVariableDetails = f.evaluateVariable("welcomeMessage")
```

Evaluations include `type`, `reason`, relevant entity keys and values, and optional rule, bucket, variation, force and variable override metadata. Root gate misses include normalized `conditions`. Malformed root selectors serialize as `{ "or": [] }`. `variableOverrideKey`, `variableOverridePath` and `variableOverridePaths` describe matched overrides. Errors include `error` and use the ordinary getter fallback.

## Modules

The before evaluation and after evaluation phases each use the module membership at the start of that phase. Where an evaluation uses bucketing, the bucket key and bucket value phases each use their own starting membership. Adding or removing a module during a phase does not change the iteration already in progress. The next phase uses the membership then installed. A module added before the after phase can receive after callbacks for evaluations already in progress, even if it did not receive their before callbacks. A module removed before the after phase receives no after callback.

Modules allow you to intercept evaluation inputs and outputs.

All `beforeEvaluation` callbacks run in registration order before evaluation. Caller defaults are then applied, followed by all `afterEvaluation` callbacks in registration order. Condition and composition dependencies use the same module pipeline, including nested getter calls, while the outer caller default stays isolated from dependency evaluations.

Module options expose `dependencyOf` for an internal dependency read. It names the immediate requesting evaluation by `type`, optional `featureKey`, and optional `variableKey`. `dependencyPurpose` is `condition` or `composition`. The latter consumes values rather than gating eligibility. Both fields are absent for application calls, including a public getter invoked from a module. Request memoization separates purpose, requester, effective context and state and is discarded after every root call.

Treat sticky dictionaries and their nested values as read only after passing them to an instance or module. Use sticky setters or assign replacement dictionaries in a module to change them.

Modules should return the same result for the same input during one evaluation. Pass values that change through context.

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
    beforeEvaluation: { options in
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
    afterEvaluation: { evaluation, _ in evaluation },
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

Spawn child instances with inherited context:

```swift
let child = f.spawn([
    "userId": .string("123"),
])

let enabled = child.isEnabled("checkout")
let flagEvaluation = child.evaluateFlag("checkout")
let variationEvaluation = child.evaluateVariation("checkout")
let variableEvaluation = child.evaluateVariable("checkout", "bgColor")
let globalVariable = child.getVariable("welcomeMessage")
```

A child snapshots the parent keys that exist when it is spawned. Child values win for those keys. Parent keys introduced later are still inherited. Calling `close()` removes both child-owned listeners and subscriptions delegated to the parent.

## Close

To clear listeners and close resources:

```swift
f.close()
```

## OpenFeature

The package exposes `FeaturevisorOpenFeature` as a separate library product using OpenFeature Swift 0.7.0. Targets using it should declare both package dependencies:

```swift
.package(url: "https://github.com/featurevisor/featurevisor-swift2.git", from: "4.0.0"),
.package(url: "https://github.com/open-feature/swift-sdk.git", .upToNextMinor(from: "0.7.0"))
```

Then add the products needed by that target:

```swift
.product(name: "Featurevisor", package: "featurevisor-swift2"),
.product(name: "FeaturevisorOpenFeature", package: "featurevisor-swift2"),
.product(name: "OpenFeature", package: "swift-sdk")
```

Core consumers need only the `Featurevisor` product. OpenFeature 0.7 uses specification reason strings such as `TARGETING_MATCH` and `ERROR`. Its logging APIs accept `OpenFeatureLogger`. Applications using swift-log can add the optional `OpenFeatureSwiftLog` product and wrap their logger with `SwiftLogLogger`.

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

Use `checkout` for a flag, `checkout:variation` for its variation, `checkout:title` for its `title` variable, and `variable:welcomeMessage` for a global variable. Boolean variables use the boolean resolver. Lists, structures, and JSON variables use the object resolver.

The provider maps Featurevisor values to OpenFeature resolvers:

| Key | Resolver |
| --- | --- |
| `feature` | Boolean flag |
| `feature:variation` | String variation |
| `feature:variable` | Resolver matching the variable schema |
| `variable:key` | Resolver matching the global variable type |

Integer variables can be resolved with either the integer or double resolver. Non-finite doubles are rejected with `TYPE_MISMATCH`. Invalid JSON variables also return `TYPE_MISMATCH` and the caller's default value.

OpenFeature's targeting key maps to `userId` by default. `targetingKeyField`, `keySeparator`, `variationKey`, and `globalVariablePrefix` can customize the mapping. The global variable prefix defaults to `variable` and cannot contain the separator. Call `provider.close()` when the application owns the provider lifecycle and is finished with it. The upstream Swift `EvaluationContext` exposes `getTargetingKey()` as a nonoptional string and its `asMap()` does not include the targeting key. It returns an empty string for both an omitted key and an explicitly empty key, so this provider cannot distinguish those cases. An empty key therefore leaves an existing value in the configured targeting field unchanged. Callers requiring empty key override semantics must set that field explicitly as an attribute, such as `"userId": ""`. Clear any inherited nonempty targeting key at its source first, since it would overwrite that attribute again. A narrower empty key may not clear it.

Initialize the provider from raw JSON:

```swift
let provider = FeaturevisorOpenFeatureProvider(
    options: FeaturevisorOptions(logLevel: .warn),
    datafileJSON: json
)
```

Malformed JSON returns the OpenFeature `PARSE_ERROR` code with `Could not parse datafile`. The provider keeps returning that error until a valid datafile is set through `provider.featurevisor.setDatafile(...)`. Successful replacement clears the parse error.

Reuse an existing Featurevisor instance:

```swift
let featurevisor = createFeaturevisor(FeaturevisorOptions(datafile: datafile))
let provider = FeaturevisorOpenFeatureProvider(featurevisor: featurevisor)
```

The caller owns an instance passed this way. Closing the provider does not close it. Call `featurevisor.close()` when every consumer is finished with it. When the provider creates the instance from `options`, the provider owns and closes it. If both are supplied, `featurevisor` takes precedence over `options`.

Featurevisor evaluation reasons map to OpenFeature reasons:

| Featurevisor reason | OpenFeature reason |
| --- | --- |
| `forced`, `sticky`, `rule`, `variable_composed`, variable overrides | `TARGETING_MATCH` |
| `allocated` | `SPLIT` |
| disabled flag, variation, or variable, `conditions_unmet` | `DISABLED` |
| no match, variable default | `DEFAULT` |
| missing feature, variable, or variations | `ERROR` with `FLAG_NOT_FOUND` |
| evaluation error | `ERROR` with `GENERAL` |

Resolution metadata includes `featureKey` when present, `featurevisorReason`, `schemaVersion`, and `revision`. It also includes `variableKey`, `ruleKey`, `bucketKey`, `bucketValue`, `forceIndex`, `variableOverrideIndex`, `variableOverrideKey`, and `variableOverridePath` when those values are available. Variation resolutions populate OpenFeature's `variant` field.

The provider forwards OpenFeature tracking calls to `onTrack`. Closing a provider it owns closes Featurevisor modules and subscriptions. Closing a provider created with a caller-owned Featurevisor instance only removes provider subscriptions.

The base `Featurevisor` product does not compile or link OpenFeature provider code into an application target. Swift Package Manager still resolves the package-level `swift-sdk` dependency because both products share one package manifest. Projects that require dependency-download isolation would need the provider in a separate repository.

Invalid initial JSON leaves the provider in error status, independently of the diagnostic log level. Swift registration completes without throwing. A valid datafile update restores readiness. Direct `featurevisor.setContext` calls emit configuration change events for both owned and supplied instances, without starting a second OpenFeature context reconciliation. Closing the provider detaches these subscriptions and closes only an owned instance.

See the [OpenFeature provider guide](https://featurevisor.com/docs/sdks/openfeature/) for resolution reasons, errors, metadata, tracking, lifecycle, and providers for other languages.

## CLI usage

Build the executable from this SDK repository with Swift 6.1 or later:

```bash
swift build --product featurevisor
```

The native test runner requires `@featurevisor/cli` 4.0.0 or later and Node.js 24 or later. Install the Node.js CLI in your Featurevisor project:

```bash
npm install --save-dev @featurevisor/cli@^4.0.0
```

The native CLI supports `test`, `benchmark` and `assess-distribution`. Node.js remains responsible for parsing definitions, listing tests through the execution protocol, expanding matrices and generating datafiles through `npx featurevisor`. Evaluations run through this Swift SDK. Use the Node.js CLI directly for authoring commands such as `init`, `lint` and `build`. The SDK runtime has no Node.js dependency.

Options use kebab case, such as `--project-directory-path`. The camelCase forms from earlier releases still work, and `--root-directory-path` is an alias for `--project-directory-path`. Pass values as `--name=value` or `--name value`. Repeat `--target` to select several targets in order. Run `<command> --help` to list every option.

Quote JSON and paths containing spaces as a single shell argument. Duplicate targets are evaluated once, at their first position. Extra positional arguments and unknown options are rejected.

### Test

```bash
swift run featurevisor test \
  --project-directory-path=/path/to/featurevisor-project \
  --only-failures
```

See [Testing](https://featurevisor.com/docs/testing/) for authoring specs and [Checks](https://featurevisor.com/docs/testing/#checks) for check syntax and operators.

The Node.js CLI owns definition parsing, builds, linting and execution expansion. Swift consumes its version 1 execution envelope and evaluates through the native SDK. Run `npx featurevisor lint` separately. `test` does not run lint automatically. Segment specs and checks use SDK gates with the selected datafile, context, fixed bucket and sticky state. Selected Target segment specializations remain authoritative, with compiled execution definitions restoring missing segments. Attribute only segment chains can run without an environment. Feature or variable dependencies require the selected datafile. Check references, including transitive dependencies and child checks, are validated before getters run. Synthetic segment gates are excluded from coverage.

Useful test options:

- `--key-pattern=<pattern>` and `--assertion-pattern=<pattern>` filter tests.
- `--entity-type=scenario` selects scenarios. `--set=<set>` selects one project set. Omitting `--set` runs all sets.
- `--case=<id>` reruns one expanded case. Copy the opaque ID or rerun command from a failure report.
- `--json --pretty` produces an indented JSON report.
- `--coverage` reports observed rule and override selections. `--uncovered` lists features and global variables without associated specs.
- `--only-failures`, `--quiet`, `--verbose` and `--show-datafile` control diagnostic output.

### Benchmark

The examples below use a project without environments. Add `--environment=<name>` if your project configures environments. In a sets project, omit `--set` to run every set or pass `--set=<name>`. Repeat `--target=<key>` to evaluate specific target datafiles. The Node.js CLI validates these options and builds the datafiles. Swift evaluates them. Replace `checkout` with a feature defined in your project.

```bash
swift run featurevisor benchmark \
  --project-directory-path=/path/to/featurevisor-project \
  --feature=checkout \
  --context='{"country":"nl"}' \
  --n=1000
```

Use `--variation` for a variation or `--variable=<key>` for a feature variable. Omit `--feature` to benchmark a global variable. Do not combine `--variation` with `--variable`. See [Benchmarking](https://featurevisor.com/docs/cli/#benchmarking).

### Assess distribution

```bash
swift run featurevisor assess-distribution \
  --project-directory-path=/path/to/featurevisor-project \
  --feature=checkout \
  --populate-uuid=userId \
  --n=1000
```

Repeat `--populate-uuid=<key>` or `--populate-uuid <key>` to generate UUID values for multiple context attributes. `--n` and `-n` both accept a positive integer and default to 1000 evaluations in this native CLI. See [Assess distribution](https://featurevisor.com/docs/cli/#assess-distribution).

## GitHub repositories

- SDK: [featurevisor/featurevisor-swift2](https://github.com/featurevisor/featurevisor-swift2)
- Example application: [featurevisor/featurevisor-example-swift](https://github.com/featurevisor/featurevisor-example-swift)
- SwiftUI iOS example application: [featurevisor/featurevisor-example-ios](https://github.com/featurevisor/featurevisor-example-ios)

<!-- FEATUREVISOR_DOCS_END -->

<a id="getting-aggregate-evaluations"></a>

The aggregate evaluation reference has moved to [Getting evaluations](#getting-evaluations).

<a id="sticky-features-and-variables"></a>

The sticky state reference has moved to [Sticky](#sticky).

## Development of this package

### Running tests

```bash
swift test
```

To check runtime command selection against an already built Node.js monorepo:

```bash
swift build
node scripts/test-runtime-commands.mjs ../featurevisor .build/debug/featurevisor
bash scripts/test-release.sh 4.0.0
```

These checks create temporary flat, environment and sets projects without changing the monorepo or downloading packages.

To verify against the local Featurevisor example-1 project:

```bash
make test-example-1
```

To verify the public products from clean consumer packages:

```bash
./scripts/verify-consumers.sh
```

Both library products share the package tag `v4.0.0`. SwiftPM does not declare the package's own version in `Package.swift` or `Package.resolved`. The lockfile records external dependency versions. Run `bash scripts/verify-release.sh v4.0.0` before tagging. The release validation workflow tests both public library targets and clean consumers for every release tag.

## License

MIT © [Fahad Heylaal](https://fahad19.com)
