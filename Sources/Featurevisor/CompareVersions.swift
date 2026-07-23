import Foundation

enum VersionComparison: Sendable {
    case lessThan
    case equal
    case greaterThan
}

private struct InvalidSemanticVersion: LocalizedError {
    let value: String

    var errorDescription: String? {
        "Invalid argument not valid semver ('\(value)' received)"
    }
}

func compareVersions(_ lhs: String, _ rhs: String) throws -> VersionComparison {
    guard let left = ParsedVersion(lhs) else { throw InvalidSemanticVersion(value: lhs) }
    guard let right = ParsedVersion(rhs) else { throw InvalidSemanticVersion(value: rhs) }
    let count = max(left.core.count, right.core.count)

    for idx in 0..<count {
        let l = idx < left.core.count ? left.core[idx] : "0"
        let r = idx < right.core.count ? right.core[idx] : "0"
        let comparison = compareIdentifier(l, r)
        if comparison < 0 { return .lessThan }
        if comparison > 0 { return .greaterThan }
    }

    switch (left.prerelease, right.prerelease) {
    case (nil, nil):
        return .equal
    case (.some, nil):
        return .lessThan
    case (nil, .some):
        return .greaterThan
    case let (.some(leftPrerelease), .some(rightPrerelease)):
        let prereleaseCount = max(leftPrerelease.count, rightPrerelease.count)
        for idx in 0..<prereleaseCount {
            let l = idx < leftPrerelease.count ? leftPrerelease[idx] : "0"
            let r = idx < rightPrerelease.count ? rightPrerelease[idx] : "0"
            let comparison = compareIdentifier(l, r)
            if comparison < 0 { return .lessThan }
            if comparison > 0 { return .greaterThan }
        }
    }

    return .equal
}

private struct ParsedVersion {
    let core: [String]
    let prerelease: [String]?

    init?(_ value: String) {
        let stripped = value.replacingOccurrences(
            of: #"^[v^~<>=]*"#,
            with: "",
            options: .regularExpression
        )
        let withoutBuild = stripped.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = parts[0].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !core.isEmpty, core.allSatisfy({ Int($0) != nil || $0 == "x" || $0 == "X" || $0 == "*" }) else {
            return nil
        }

        self.core = core
        self.prerelease = parts.count == 2 ? parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : nil
    }
}

private func compareIdentifier(_ lhs: String, _ rhs: String) -> Int {
    if ["x", "X", "*"].contains(lhs) || ["x", "X", "*"].contains(rhs) {
        return 0
    }

    if let left = Int(lhs), let right = Int(rhs) {
        if left < right { return -1 }
        if left > right { return 1 }
        return 0
    }

    let left = lhs
    let right = rhs
    if left < right {
        return -1
    }
    if left > right {
        return 1
    }
    return 0
}
