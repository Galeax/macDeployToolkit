import XCTest
@testable import MDTKit

/// The most important suite in the project. Each case here corresponds to a known
/// way to destroy a device, and the same plan runs across the whole fleet — a
/// mistake does not produce a ticket, it produces a fleet-wide reinstall.
final class UninstallPlanTests: XCTestCase {

    private let planner = UninstallPlanner()

    // MARK: - The case that justifies everything else

    /// `pkgutil --files` lists the intermediate directories, including
    /// `Applications` itself. If pruning ran before validation, every path would
    /// collapse under `/Applications` and the plan would wipe the device's
    /// applications folder.
    func testReceiptListingApplicationsDirectoryDoesNotWipeIt() {
        let plan = planner.plan(
            spec: UninstallSpec(packageIdentifiers: ["com.tinyspeck.slackmacgap"]),
            receiptFiles: ["com.tinyspeck.slackmacgap": [
                "Applications",
                "Applications/Slack.app",
                "Applications/Slack.app/Contents",
                "Applications/Slack.app/Contents/Info.plist",
                "Applications/Slack.app/Contents/MacOS/Slack",
            ]])

        XCTAssertEqual(plan.deletions, ["/Applications/Slack.app"])
        XCTAssertFalse(plan.deletions.contains("/Applications"))
        XCTAssertEqual(plan.rejections.first?.path, "/Applications")
        XCTAssertEqual(plan.rejections.first?.reason, .criticalSystemPath)
        XCTAssertEqual(plan.prunedCount, 3)
        XCTAssertEqual(plan.receiptsToForget, ["com.tinyspeck.slackmacgap"])
    }

    // MARK: - System paths

    func testRejectsEveryCriticalSystemPath() {
        let dangerous = [
            "/", "/Applications", "/Library", "/System", "/Users", "/usr",
            "/usr/local", "/usr/local/bin", "/usr/bin", "/bin", "/etc", "/var",
            "/private", "/private/var", "/private/var/db", "/tmp", "/opt",
            "/opt/homebrew/bin", "/Library/LaunchDaemons", "/Library/LaunchAgents",
            "/Library/Application Support", "/Library/Preferences",
            "/Library/PrivilegedHelperTools", "/Library/Frameworks",
        ]
        for path in dangerous {
            XCTAssertEqual(planner.classify(path), .criticalSystemPath,
                           "\(path) must be refused")
        }
    }

    /// `/var` and `/private/var` denote the same thing: protecting only one would
    /// make the denylist bypassable through the other spelling.
    func testBothVarSpellingsAreProtected() {
        XCTAssertEqual(planner.classify("/var/db/receipts"), .criticalSystemPath)
        XCTAssertEqual(planner.classify("/private/var/db/receipts"), .criticalSystemPath)
    }

    func testRejectsPathTraversal() {
        XCTAssertEqual(planner.classify("/Applications/Slack.app/../.."), .pathTraversal)
        XCTAssertEqual(planner.classify("/Applications/../../etc"), .pathTraversal)
    }

    func testRejectsRelativePaths() {
        XCTAssertEqual(planner.classify("Applications/Slack.app"), .notAbsolute)
        XCTAssertEqual(planner.classify("../etc"), .notAbsolute)
    }

    /// Allowlist by default: anything that is not explicitly allowed is refused,
    /// even if it is not named in the denylist.
    func testRejectsAnythingOutsideAllowedRoots() {
        XCTAssertEqual(planner.classify("/System/Library/Foo"), .outsideAllowedRoots)
        XCTAssertEqual(planner.classify("/Network/Servers/foo"), .outsideAllowedRoots)
        XCTAssertEqual(planner.classify("/etc/paths.d/foo"), .outsideAllowedRoots)
    }

    func testAcceptsLegitimatePaths() {
        for path in [
            "/Applications/Slack.app",
            "/Library/Application Support/CoreUpdate/agent",
            "/Library/LaunchDaemons/com.coreupdate.deploy.plist",
            "/usr/local/bin/macdeploy",
            "/opt/coreupdate/tooling",
        ] {
            XCTAssertNil(planner.classify(path), "\(path) must be accepted")
        }
    }

    // MARK: - User directories

    /// Two safeguards stack under `/Users`: the relative denylist names the shared
    /// folders, and the minimum depth of 4 catches everything else — at 3 we would
    /// allow deleting a whole `~/Library`.
    func testUserPathDepthLadder() {
        XCTAssertEqual(planner.classify("/Users"), .criticalSystemPath)
        XCTAssertEqual(planner.classify("/Users/romain"), .sharedUserPath)
        XCTAssertEqual(planner.classify("/Users/romain/Library"), .sharedUserPath)
        XCTAssertEqual(planner.classify("/Users/romain/Library/Preferences"), .sharedUserPath)
        XCTAssertNil(planner.classify("/Users/romain/Library/Preferences/com.foo.plist"))
    }

    /// A user path that is too short but absent from the denylist must still be
    /// refused: that is the residual role of the depth check.
    func testShallowUserPathOutsideDenylistIsStillRefused() {
        XCTAssertEqual(planner.classify("/Users/romain/.zshrc"), .tooShallow)
        XCTAssertEqual(planner.classify("/Users/romain/monprojet"), .tooShallow)
    }

    func testRejectsSharedUserDirectories() {
        for relative in [
            "Library/Application Support", "Library/Caches", "Library/Containers",
            "Library/LaunchAgents", "Documents", "Desktop", "Downloads",
        ] {
            XCTAssertEqual(planner.classify("/Users/romain/\(relative)"), .sharedUserPath,
                           "\(relative) is shared, it must never be deleted")
        }
    }

    func testAcceptsApplicationSpecificUserDirectories() {
        XCTAssertNil(planner.classify("/Users/romain/Library/Application Support/Slack"))
        XCTAssertNil(planner.classify("/Users/romain/Library/Caches/com.tinyspeck.slackmacgap"))
    }

    // MARK: - ~ expansion

    func testTildeExpandsAcrossEveryHome() {
        let plan = planner.plan(
            spec: UninstallSpec(paths: ["~/Library/Application Support/Slack"]),
            homeDirectories: ["/Users/romain", "/Users/alice"])

        XCTAssertEqual(plan.deletions, [
            "/Users/alice/Library/Application Support/Slack",
            "/Users/romain/Library/Application Support/Slack",
        ])
    }

    /// A `~` with no user home provided is never guessed.
    func testTildeWithoutHomesIsSkippedWithWarning() {
        let plan = planner.plan(
            spec: UninstallSpec(paths: ["~/Library/Caches/com.foo"]),
            homeDirectories: [])

        XCTAssertTrue(plan.deletions.isEmpty)
        XCTAssertEqual(plan.warnings.count, 2, "one expansion warning + empty plan")
        XCTAssertTrue(plan.warnings.contains { $0.contains("no user home") })
    }

    // MARK: - Preserved paths: the difference between `repair` and `uninstall`

    func testExactPreservedPathIsRefused() {
        let plan = planner.plan(spec: UninstallSpec(
            paths: ["/Library/Application Support/CoreUpdate/config.json"],
            preservedPaths: ["/Library/Application Support/CoreUpdate/config.json"]))

        XCTAssertTrue(plan.deletions.isEmpty)
        XCTAssertEqual(plan.rejections.first?.reason, .preserved)
    }

    func testDescendantOfPreservedPathIsRefused() {
        let plan = planner.plan(spec: UninstallSpec(
            paths: ["/Library/Application Support/CoreUpdate/config.json"],
            preservedPaths: ["/Library/Application Support/CoreUpdate"]))

        XCTAssertTrue(plan.deletions.isEmpty)
        XCTAssertEqual(plan.rejections.first?.reason, .preserved)
    }

    /// Deleting a folder that contains a preserved path would carry the preserved
    /// path away with it: we keep everything, and we say so.
    func testAncestorOfPreservedPathIsRefusedAndWarned() {
        let plan = planner.plan(spec: UninstallSpec(
            paths: ["/Library/Application Support/CoreUpdate"],
            preservedPaths: ["/Library/Application Support/CoreUpdate/licence.plist"]))

        XCTAssertTrue(plan.deletions.isEmpty)
        XCTAssertEqual(plan.rejections.first?.reason, .ancestorOfPreserved)
        XCTAssertTrue(plan.warnings.contains { $0.contains("licence.plist") })
    }

    func testSiblingsOfPreservedPathsAreStillDeleted() {
        let plan = planner.plan(spec: UninstallSpec(
            paths: ["/Applications/Slack.app", "/Library/Application Support/Slack"],
            preservedPaths: ["/Users/romain/Library/Application Support/Slack"]))

        XCTAssertEqual(plan.deletions, [
            "/Applications/Slack.app",
            "/Library/Application Support/Slack",
        ])
    }

    // MARK: - Pruning

    func testDeduplicatesAndSorts() {
        let plan = planner.plan(spec: UninstallSpec(paths: [
            "/Applications/Zoom.app",
            "/Applications/Slack.app",
            "/Applications/Slack.app",
        ]))
        XCTAssertEqual(plan.deletions, ["/Applications/Slack.app", "/Applications/Zoom.app"])
    }

    /// The false positive a `hasPrefix` would produce: an adjacent backup must not
    /// be absorbed by the bundle it backs up.
    func testSimilarlyNamedSiblingIsNotAbsorbed() {
        let plan = planner.plan(spec: UninstallSpec(paths: [
            "/Applications/Slack.app",
            "/Applications/Slack.app.backup",
        ]))
        XCTAssertEqual(plan.deletions, [
            "/Applications/Slack.app",
            "/Applications/Slack.app.backup",
        ])
    }

    // MARK: - launchd and empty plan

    func testEmptyLaunchdLabelIsRejected() {
        let plan = planner.plan(spec: UninstallSpec(
            paths: ["/Applications/Slack.app"],
            launchdLabels: ["com.tinyspeck.helper", "   ", ""]))

        XCTAssertEqual(plan.launchdLabels, ["com.tinyspeck.helper"])
        XCTAssertEqual(plan.rejections.filter { $0.reason == .emptyLaunchdLabel }.count, 2)
    }

    func testEmptySpecWarnsRatherThanSilentlySucceeding() {
        let plan = planner.plan(spec: UninstallSpec())
        XCTAssertTrue(plan.isEmpty)
        XCTAssertTrue(plan.warnings.contains { $0.contains("empty plan") })
    }

    /// A spec whose every path is refused must not look like a success: the plan is
    /// empty and the warning flags it.
    func testSpecWhoseEveryPathIsRejectedYieldsEmptyPlan() {
        let plan = planner.plan(spec: UninstallSpec(paths: ["/", "/Library", "/etc/hosts"]))
        XCTAssertTrue(plan.deletions.isEmpty)
        XCTAssertEqual(plan.rejections.count, 3)
        XCTAssertTrue(plan.warnings.contains { $0.contains("empty plan") })
    }

    func testPlanIsCodableForAuditTrail() throws {
        let plan = planner.plan(spec: UninstallSpec(
            packageIdentifiers: ["com.tinyspeck.slackmacgap"],
            paths: ["/Applications/Slack.app"],
            launchdLabels: ["com.tinyspeck.helper"]))

        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(UninstallPlan.self, from: data)
        XCTAssertEqual(decoded, plan)
    }
}
