import Foundation

enum VersionComparison: Sendable, Equatable {
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

private let semanticVersionPattern = try! NSRegularExpression(
    pattern: #"^[v^~<>=]*?(\d+)(?:\.([x*]|\d+)(?:\.([x*]|\d+)(?:\.([x*]|\d+))?(?:-([\da-z\-]+(?:\.[\da-z\-]+)*))?(?:\+[\da-z\-]+(?:\.[\da-z\-]+)*)?)?)?$"#,
    options: [.caseInsensitive]
)

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
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = semanticVersionPattern.firstMatch(
            in: value,
            range: fullRange
        ), match.range == fullRange else {
            return nil
        }

        func capture(_ index: Int) -> String? {
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Swift.Range(range, in: value) else {
                return nil
            }
            return String(value[swiftRange])
        }

        self.core = (1...4).compactMap(capture)
        self.prerelease = capture(5)?.split(separator: ".").map(String.init)
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
