import Foundation

public struct DependencyOf: Codable, Hashable, Sendable {
    public let type: EvaluationType
    public let featureKey: FeatureKey?
    public let variableKey: VariableKey?

    public init(type: EvaluationType, featureKey: FeatureKey? = nil, variableKey: VariableKey? = nil) {
        self.type = type
        self.featureKey = featureKey
        self.variableKey = variableKey
    }

    init(_ options: EvaluateOptions) {
        self.init(
            type: options.type,
            featureKey: options.globalVariable ? nil : options.featureKey,
            variableKey: options.variableKey
        )
    }
}

enum DependencyOperand: Sendable {
    case flag(Bool)
    case variation(VariationValue?)
    case variable(VariableValue)
}

struct RequirementCycleError: LocalizedError {
    var errorDescription: String? { "Circular evaluation requirement" }
}

struct RequirementEvaluationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// Retain providers until the root request ends. A bare ObjectIdentifier could
// otherwise be reused after a module replaces a provider.
struct DependencyMemoKey: Hashable {
    let identity: DependencyOf
    let requester: DependencyOf?
    let purpose: String
    let evaluationData: InstanceEvaluationDataProvider
    let modulesManager: ModulesManager

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.purpose == rhs.purpose && lhs.identity == rhs.identity && lhs.requester == rhs.requester
            && lhs.evaluationData === rhs.evaluationData && lhs.modulesManager === rhs.modulesManager
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(purpose)
        hasher.combine(identity)
        hasher.combine(requester)
        hasher.combine(ObjectIdentifier(evaluationData))
        hasher.combine(ObjectIdentifier(modulesManager))
    }
}

private struct MemoInput {
    // Swift value trees make this an owned copy on write snapshot.
    let context: Context
    let stickyFeaturesToken: UUID
    let stickyVariablesToken: UUID
    let sourceGeneration: String?
    let modulesRevision: UInt64

    init(_ dependencies: EvaluateDependencies) {
        context = dependencies.context
        stickyFeaturesToken = dependencies.stickyFeaturesToken
        stickyVariablesToken = dependencies.stickyVariablesToken
        sourceGeneration = dependencies.stickySource?.current()?.generation
        modulesRevision = dependencies.modulesManager.getRevision()
    }

    func matches(_ other: Self) -> Bool {
        stickyFeaturesToken == other.stickyFeaturesToken
            && stickyVariablesToken == other.stickyVariablesToken
            && sourceGeneration == other.sourceGeneration
            && modulesRevision == other.modulesRevision
            && sameContext(context, other.context)
    }
}

private struct ComparisonBudget {
    static let maximumDepth = 64
    static let maximumNodes = 4096

    var remainingNodes = maximumNodes

    mutating func visit(depth: Int) -> Bool {
        guard depth <= Self.maximumDepth, remainingNodes > 0 else { return false }
        remainingNodes -= 1
        return true
    }
}

// Synthesised AnyValue equality treats +0 and -0 alike. Preserve that
// distinction. Unsupported, deep and oversized trees do not enter the memo.
private func sameValue(
    _ lhs: AnyValue, _ rhs: AnyValue, depth: Int, budget: inout ComparisonBudget
) -> Bool {
    guard budget.visit(depth: depth) else { return false }
    switch (lhs, rhs) {
    case (.string(let a), .string(let b)): return a == b
    case (.int(let a), .int(let b)): return a == b
    case (.double(let a), .double(let b)): return a.isFinite && b.isFinite && a.bitPattern == b.bitPattern
    case (.bool(let a), .bool(let b)): return a == b
    case (.null, .null): return true
    case (.array(let a), .array(let b)):
        guard a.count == b.count else { return false }
        for (left, right) in zip(a, b) {
            guard sameValue(left, right, depth: depth + 1, budget: &budget) else { return false }
        }
        return true
    case (.object(let a), .object(let b)):
        guard a.count == b.count else { return false }
        for (key, value) in a {
            guard let other = b[key],
                  sameValue(value, other, depth: depth + 1, budget: &budget) else { return false }
        }
        return true
    default: return false
    }
}

private func sameContext(_ lhs: Context, _ rhs: Context) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var budget = ComparisonBudget()
    guard budget.visit(depth: 0) else { return false }
    for (key, value) in lhs {
        guard let other = rhs[key],
              sameValue(value, other, depth: 1, budget: &budget) else { return false }
    }
    return true
}

final class EvaluationSession: @unchecked Sendable {
    // A request is evaluated synchronously. Dependency storage, including its
    // lock, is needed only once that request actually hands off to a dependency.
    private var root: DependencyOf?
    private var rootCurrent: DependencyOf?
    private var storage: DependencySessionStorage?
    private var completedWork = (snapshots: 0, keys: 0, entries: 0)

    var hasDependencyStorage: Bool { storage != nil }
    var workCounts: (snapshots: Int, keys: Int, entries: Int) {
        storage?.workCounts ?? completedWork
    }

    func beginRoot(_ identity: DependencyOf) -> Bool {
        guard root == nil else { return false }
        root = identity
        rootCurrent = identity
        completedWork = (0, 0, 0)
        return true
    }

    func endRoot() {
        if let storage { completedWork = storage.workCounts }
        storage?.endRoot()
        storage = nil
        root = nil
        rootCurrent = nil
    }

    private func dependencyStorage() -> DependencySessionStorage {
        if let storage { return storage }
        let next = DependencySessionStorage()
        if let root {
            _ = next.beginRoot(root)
            if let rootCurrent { next.updateCurrent(rootCurrent) }
        }
        storage = next
        return next
    }

    func current() -> DependencyOf? { storage?.current() ?? rootCurrent }
    func updateCurrent(_ identity: DependencyOf) {
        if let storage { storage.updateCurrent(identity) }
        else if root != nil { rootCurrent = identity }
    }
    func withCurrent<T>(_ identity: DependencyOf, _ body: () throws -> T) rethrows -> T {
        let previous = current()
        updateCurrent(identity)
        defer { if let previous { updateCurrent(previous) } }
        return try body()
    }
    func recordRequirementFailure(_ error: RequirementEvaluationError) {
        dependencyStorage().recordRequirementFailure(error)
    }
    func throwIfFatal() throws { try storage?.throwIfFatal() }
    func segment<T>(_ key: String, evaluate: () throws -> T) throws -> T {
        try dependencyStorage().segment(key, evaluate: evaluate)
    }
    func read(
        _ identity: DependencyOf,
        dependencies: EvaluateDependencies,
        purpose: String = "condition",
        evaluate: (DependencyOf) -> DependencyOperand
    ) throws -> DependencyOperand {
        try dependencyStorage().read(identity, dependencies: dependencies, purpose: purpose, evaluate: evaluate)
    }
}

private final class DependencySessionStorage {
    private struct Frame {
        let identity: DependencyOf
        var current: DependencyOf
    }

    private struct Entry {
        let input: MemoInput
        let value: DependencyOperand
    }

    private let lock = FeaturevisorLock()
    private var frames: [Frame] = []
    private var memo: [DependencyMemoKey: [Entry]] = [:]
    private var inputSnapshot: MemoInput?
    private var activeSegments = Set<String>()
    private var cycleDetected = false
    private var requirementFailure: RequirementEvaluationError?
    // Internal work counts support deterministic regression guards.
    private var snapshotBuilds = 0
    private var keyBuilds = 0
    private var entryStores = 0
    var workCounts: (snapshots: Int, keys: Int, entries: Int) {
        lock.withLock { (snapshotBuilds, keyBuilds, entryStores) }
    }

    func beginRoot(_ identity: DependencyOf) -> Bool {
        lock.withLock {
            guard frames.isEmpty else { return false }
            frames.append(Frame(identity: identity, current: identity))
            snapshotBuilds = 0
            keyBuilds = 0
            entryStores = 0
            return true
        }
    }

    func endRoot() {
        lock.withLock {
            activeSegments.removeAll()
            frames.removeAll()
            memo.removeAll()
            inputSnapshot = nil
            cycleDetected = false
            requirementFailure = nil
        }
    }

    func current() -> DependencyOf? { lock.withLock { frames.last?.current } }

    func updateCurrent(_ identity: DependencyOf) {
        lock.withLock {
            guard !frames.isEmpty else { return }
            frames[frames.count - 1].current = identity
        }
    }

    func withCurrent<T>(_ identity: DependencyOf, _ body: () throws -> T) rethrows -> T {
        let previous = current()
        updateCurrent(identity)
        defer { if let previous { updateCurrent(previous) } }
        return try body()
    }

    func recordRequirementFailure(_ error: RequirementEvaluationError) {
        lock.withLock { requirementFailure = error }
    }

    func throwIfFatal() throws {
        let fatal = lock.withLock { (cycleDetected, requirementFailure) }
        if fatal.0 { throw RequirementCycleError() }
        if let error = fatal.1 { throw error }
    }

    func segment<T>(_ key: String, evaluate: () throws -> T) throws -> T {
        try lock.withLock {
            if activeSegments.contains(key) {
                cycleDetected = true
                throw RequirementCycleError()
            }
            guard activeSegments.count + frames.count - 1 < 256, !StackGuard.exhausted else {
                throw RequirementEvaluationError(message: "Evaluation dependency depth exceeded")
            }
            activeSegments.insert(key)
        }
        defer { _ = lock.withLock { activeSegments.remove(key) } }
        return try evaluate()
    }

    func read(
        _ identity: DependencyOf,
        dependencies: EvaluateDependencies,
        purpose: String = "condition",
        evaluate: (DependencyOf) -> DependencyOperand
    ) throws -> DependencyOperand {
        let parent = current()
        let key = DependencyMemoKey(
            identity: identity, requester: parent, purpose: purpose,
            evaluationData: dependencies.evaluationData,
            modulesManager: dependencies.modulesManager
        )
        let input = MemoInput(dependencies)
        var selectedInput = input
        let cached: DependencyOperand? = try lock.withLock {
            keyBuilds += 1
            if frames.count + activeSegments.count > 256 || StackGuard.exhausted {
                cycleDetected = true
                throw RequirementEvaluationError(message: "Evaluation dependency depth exceeded")
            }
            if frames.contains(where: { $0.identity == identity || $0.current == identity }) {
                cycleDetected = true
                throw RequirementCycleError()
            }
            if let entry = memo[key]?.first(where: { $0.input.matches(input) }) { return entry.value }
            if let snapshot = inputSnapshot, snapshot.matches(input) {
                selectedInput = snapshot
            } else {
                inputSnapshot = input
                snapshotBuilds += 1
            }
            frames.append(Frame(identity: identity, current: identity))
            return nil
        }
        if let cached { return cached }
        defer { lock.withLock { _ = frames.popLast() } }
        let result = evaluate(parent ?? identity)
        try throwIfFatal()
        if selectedInput.matches(MemoInput(dependencies)) {
            lock.withLock {
                memo[key, default: []].append(Entry(input: selectedInput, value: result))
                entryStores += 1
            }
        }
        return result
    }
}
