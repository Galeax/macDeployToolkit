import XCTest
@testable import MacADTKit

final class BundleVersionTests: XCTestCase {

    func testMissingComponentsAreZero() {
        XCTAssertEqual(BundleVersion("1.2"), BundleVersion("1.2.0"))
        XCTAssertEqual(BundleVersion("4"), BundleVersion("4.0.0.0"))
    }

    /// The classic trap: a string comparison would give 1.2.3 > 1.2.10.
    func testNumericAndNotLexicographic() {
        XCTAssertLessThan(BundleVersion("1.2.3"), BundleVersion("1.2.10"))
        XCTAssertLessThan(BundleVersion("9.0"), BundleVersion("10.0"))
    }

    /// Deliberate choice: a pre-release equals its final version, to avoid looping
    /// reinstalls on beta builds.
    func testPreReleaseSuffixIsIgnored() {
        XCTAssertEqual(BundleVersion("1.2.3-beta2"), BundleVersion("1.2.3"))
        XCTAssertEqual(BundleVersion("2.0rc1"), BundleVersion("2.0"))
    }

    func testHandlesRealWorldStrings() {
        XCTAssertEqual(BundleVersion("119.0.6045.199").components, [119, 0, 6045, 199])
        XCTAssertEqual(BundleVersion("2026.1").components, [2026, 1])
        XCTAssertEqual(BundleVersion("7.1 (build 42)").components, [7, 1])
        XCTAssertEqual(BundleVersion("v1.2.3").components, [1, 2, 3])
    }

    func testEmptyAndGarbageDegradeToZero() {
        XCTAssertEqual(BundleVersion(""), BundleVersion("0"))
        XCTAssertEqual(BundleVersion("unknown"), BundleVersion("0"))
    }

    func testDateStyleVersionsCompareCorrectly() {
        XCTAssertGreaterThan(BundleVersion("2026.1"), BundleVersion("2025.12"))
    }

    func testRawIsPreservedForLogging() {
        XCTAssertEqual(BundleVersion("1.2.3-beta2").description, "1.2.3-beta2")
    }

    func testSortingIsStable() {
        let sorted = ["1.10.0", "1.2.0", "1.9.9", "2.0.0"]
            .map(BundleVersion.init)
            .sorted()
            .map(\.raw)
        XCTAssertEqual(sorted, ["1.2.0", "1.9.9", "1.10.0", "2.0.0"])
    }
}
