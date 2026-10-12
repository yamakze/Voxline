import Foundation

struct ReleaseVersion: Comparable, Sendable {
    let numbers: [Int]
    let prerelease: [String]

    init(_ text: String) throws {
        let version = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let versionAndBuild = version.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        let parts = versionAndBuild[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let components = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        let parsedNumbers = components.compactMap { Int($0) }
        guard components.count == 3,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              parsedNumbers.count == components.count else { throw ReleaseUpdateError.invalidVersion }
        numbers = parsedNumbers
        prerelease = parts.count == 2 ? parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
        let identifiers = prerelease + (versionAndBuild.count == 2 ? versionAndBuild[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : [])
        guard identifiers.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }) else {
            throw ReleaseUpdateError.invalidVersion
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (Int(left), Int(right)) {
            case let (left?, right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
