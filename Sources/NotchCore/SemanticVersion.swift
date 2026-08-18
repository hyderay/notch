import Foundation

public struct SemanticVersion: Comparable, Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    private let prerelease: [String]

    public init?(_ value: String) {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.first == "v" || normalized.first == "V" {
            normalized.removeFirst()
        }
        normalized = String(normalized.split(separator: "+", maxSplits: 1)[0])

        let parts = normalized.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(numbers.count),
              numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return nil }

        var components = numbers.compactMap { Int($0) }
        guard components.count == numbers.count else { return nil }
        while components.count < 3 { components.append(0) }

        major = components[0]
        minor = components[1]
        patch = components[2]
        if parts.count == 2 {
            guard !parts[1].isEmpty else { return nil }
            prerelease = parts[1].split(separator: ".").map(String.init)
        } else {
            prerelease = []
        }
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let leftCore = [lhs.major, lhs.minor, lhs.patch]
        let rightCore = [rhs.major, rhs.minor, rhs.patch]
        if leftCore != rightCore {
            return leftCore.lexicographicallyPrecedes(rightCore)
        }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }

        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (Int(left), Int(right)) {
            case let (.some(a), .some(b)): return a < b
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
