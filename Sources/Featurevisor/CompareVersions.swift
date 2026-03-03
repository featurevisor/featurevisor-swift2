import Foundation

public enum VersionComparison: Sendable {
    case lessThan
    case equal
    case greaterThan
}

public func compareVersions(_ lhs: String, _ rhs: String) -> VersionComparison {
    let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
    let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
    let count = max(left.count, right.count)

    for idx in 0..<count {
        let l = idx < left.count ? left[idx] : 0
        let r = idx < right.count ? right[idx] : 0
        if l < r { return .lessThan }
        if l > r { return .greaterThan }
    }

    return .equal
}
