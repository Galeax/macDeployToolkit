import XCTest
@testable import MacADTKit

final class PathSafetyTests: XCTestCase {

    func testNormalizeCollapsesRedundantSeparatorsAndDots() {
        XCTAssertEqual(PathSafety.normalize("/Applications//Slack.app/"), "/Applications/Slack.app")
        XCTAssertEqual(PathSafety.normalize("/Applications/./Slack.app"), "/Applications/Slack.app")
        XCTAssertEqual(PathSafety.normalize("/"), "/")
    }

    /// `..` are refused, never resolved. Silently reducing
    /// `/Applications/Foo.app/../..` to `/` is exactly the bug not to have.
    func testNormalizeRefusesTraversalInsteadOfResolvingIt() {
        XCTAssertNil(PathSafety.normalize("/Applications/Foo.app/../.."))
        XCTAssertNil(PathSafety.normalize("/../etc"))
    }

    func testNormalizeRejectsRelativePaths() {
        XCTAssertNil(PathSafety.normalize("Applications/Slack.app"))
        XCTAssertNil(PathSafety.normalize(""))
    }

    /// The `hasPrefix` false positive: without a component-wise comparison,
    /// `/Applications/Slack.app` would be seen as an ancestor of
    /// `/Applications/Slack.app.backup`.
    func testAncestorComparesComponentsNotStringPrefixes() {
        XCTAssertTrue(PathSafety.isAncestor("/Applications", of: "/Applications/Slack.app"))
        XCTAssertFalse(PathSafety.isAncestor("/Applications/Slack.app",
                                             of: "/Applications/Slack.app.backup"))
        XCTAssertFalse(PathSafety.isAncestor("/Applications/Slack",
                                             of: "/Applications/Slack.app"))
    }

    func testAncestorEqualityIsOptIn() {
        let path = "/Applications/Slack.app"
        XCTAssertFalse(PathSafety.isAncestor(path, of: path))
        XCTAssertTrue(PathSafety.isAncestor(path, of: path, orEqual: true))
    }

    func testMinimalRootsAbsorbsDescendants() {
        let roots = PathSafety.minimalRoots([
            "/Applications/Slack.app/Contents/Info.plist",
            "/Applications/Slack.app",
            "/Applications/Slack.app/Contents",
        ])
        XCTAssertEqual(roots, ["/Applications/Slack.app"])
    }

    /// The pruning trap: a sibling can slot in lexicographically between an ancestor
    /// and its descendant, because `-` (0x2D) precedes `/` (0x2F). Comparing only
    /// against the last retained root would then let `/A/b/c` through.
    func testMinimalRootsHandlesInterleavedSiblings() {
        let roots = PathSafety.minimalRoots(["/A/b", "/A/b-x", "/A/b/c"])
        XCTAssertEqual(roots, ["/A/b", "/A/b-x"])
    }

    func testMinimalRootsDeduplicatesAndSorts() {
        let roots = PathSafety.minimalRoots(["/B/x", "/A/y", "/A/y"])
        XCTAssertEqual(roots, ["/A/y", "/B/x"])
    }

    func testMinimalRootsOfEmptyInputIsEmpty() {
        XCTAssertTrue(PathSafety.minimalRoots([]).isEmpty)
    }
}
