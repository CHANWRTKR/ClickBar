import Foundation

/// ClickBar release tags use vMAJOR.MINOR.PATCH. Ignore unrelated or malformed tags.
public struct ReleaseVersion: Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ tag: String) {
        let value = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        self.major = major; self.minor = minor; self.patch = patch
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
    public var description: String { "\(major).\(minor).\(patch)" }
}
