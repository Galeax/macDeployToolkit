import Foundation

/// Lenient version comparator, calibrated on what is actually found in
/// `CFBundleShortVersionString` — and not on what semver would want:
/// `1.2.3`, `4.0`, `2026.1`, `119.0.6045.199`, `1.2.3-beta2`, `7.1 (build 42)`.
///
/// Rules, all intentional:
///  - split on `.`, keeping only the leading digits of each component
///    (`3-beta2` -> 3, `1 (build 42)` -> 1);
///  - missing components count as 0, so `1.2` == `1.2.0`;
///  - a non-numeric suffix is ignored for the comparison but kept in `raw`.
///    Intended consequence: `1.2.3-beta` == `1.2.3`, so that a pre-release does
///    not trigger a reinstall loop.
///
/// This is deliberately not a semver implementation: on macOS, comparing
/// CFBundleShortVersionString values with strict semver rules produces more false
/// reinstall positives than correct detections.
public struct BundleVersion: Comparable, CustomStringConvertible, Sendable {

    /// The string as read from the Info.plist, kept for the logs.
    public let raw: String

    /// Numeric components extracted, in order.
    public let components: [Int]

    public init(_ raw: String) {
        self.raw = raw
        self.components = raw
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { part in
                let digits = part.drop { !$0.isNumber }.prefix { $0.isNumber }
                return Int(digits) ?? 0
            }
    }

    /// Compares component by component, padding with zeros.
    private static func compare(_ lhs: BundleVersion, _ rhs: BundleVersion) -> Int {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }

    public static func < (lhs: BundleVersion, rhs: BundleVersion) -> Bool {
        compare(lhs, rhs) < 0
    }

    public static func == (lhs: BundleVersion, rhs: BundleVersion) -> Bool {
        compare(lhs, rhs) == 0
    }

    public var description: String { raw }
}
