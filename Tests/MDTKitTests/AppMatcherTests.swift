import XCTest
@testable import MDTKit

final class AppMatcherTests: XCTestCase {

    private let slack = BlockingAppSpec(
        bundleIdentifier: "com.tinyspeck.slackmacgap", displayName: "Slack")
    private let teams = BlockingAppSpec(
        bundleIdentifier: "com.microsoft.teams2", displayName: "Microsoft Teams")

    private func process(_ pid: Int32, _ path: String, _ identifier: String?) -> RunningProcess {
        RunningProcess(pid: pid, executablePath: path, bundleIdentifier: identifier)
    }

    func testMatchesOnBundleIdentifier() {
        let matched = AppMatcher.matching(specs: [slack, teams], processes: [
            process(101, "/Applications/Slack.app/Contents/MacOS/Slack", "com.tinyspeck.slackmacgap"),
        ])
        XCTAssertEqual(matched, [slack])
    }

    /// Bundle IDs are case-insensitive in practice on macOS, and a repackaged app can
    /// arrive with a different case than the manifest.
    func testBundleIdentifierMatchIsCaseInsensitive() {
        let matched = AppMatcher.matching(specs: [slack], processes: [
            process(101, "/Applications/Slack.app/Contents/MacOS/Slack", "COM.TinySpeck.SlackMacGap"),
        ])
        XCTAssertEqual(matched, [slack])
    }

    func testPreservesManifestOrderNotProcessOrder() {
        let matched = AppMatcher.matching(specs: [slack, teams], processes: [
            process(200, "/Applications/Microsoft Teams.app/Contents/MacOS/MSTeams", "com.microsoft.teams2"),
            process(101, "/Applications/Slack.app/Contents/MacOS/Slack", "com.tinyspeck.slackmacgap"),
        ])
        XCTAssertEqual(matched, [slack, teams],
                       "the dialog order must be stable between two displays")
    }

    func testReturnsEachSpecAtMostOnce() {
        let matched = AppMatcher.matching(specs: [slack], processes: [
            process(101, "/Applications/Slack.app/Contents/MacOS/Slack", "com.tinyspeck.slackmacgap"),
            process(102, "/Applications/Slack.app/Contents/MacOS/Slack", "com.tinyspeck.slackmacgap"),
        ])
        XCTAssertEqual(matched.count, 1)
    }

    func testExecutableNameFallbackForRepackagedApps() {
        let repackaged = BlockingAppSpec(
            bundleIdentifier: "com.coreupdate.slack-internal",
            displayName: "Slack", executableName: "Slack")
        let matched = AppMatcher.matching(specs: [repackaged], processes: [
            process(101, "/Applications/Slack.app/Contents/MacOS/Slack", "com.other.thing"),
        ])
        XCTAssertEqual(matched, [repackaged])
    }

    func testNoFallbackMeansNoMatch() {
        let matched = AppMatcher.matching(specs: [slack], processes: [
            process(101, "/Applications/Slack.app/Contents/MacOS/Slack", "com.other.thing"),
        ])
        XCTAssertTrue(matched.isEmpty)
    }

    func testProcessesWithoutBundleIdentifierAreIgnored() {
        let matched = AppMatcher.matching(specs: [slack], processes: [
            process(1, "/usr/sbin/syslogd", nil),
        ])
        XCTAssertTrue(matched.isEmpty)
    }

    /// A modern application has several processes: killing only one leaves it in an
    /// inconsistent state.
    func testCollectsEveryPidForOneApp() {
        let pids = AppMatcher.pids(for: slack, processes: [
            process(101, "/Applications/Slack.app/Contents/MacOS/Slack", "com.tinyspeck.slackmacgap"),
            process(102, "/Applications/Slack.app/Contents/MacOS/Slack", "com.tinyspeck.slackmacgap"),
            process(200, "/Applications/Zoom.app/Contents/MacOS/zoom.us", "us.zoom.xos"),
        ])
        XCTAssertEqual(pids.sorted(), [101, 102])
    }

    // MARK: - Enclosing bundle resolution

    func testFindsEnclosingAppBundle() {
        XCTAssertEqual(
            BundlePath.enclosingAppBundle(
                forExecutablePath: "/Applications/Slack.app/Contents/MacOS/Slack"),
            "/Applications/Slack.app")
    }

    /// The innermost bundle, not the outermost: otherwise every render process would
    /// count as the main application, and closing Slack would look like it failed when
    /// only helpers remain.
    func testPrefersInnermostBundleForHelperProcesses() {
        XCTAssertEqual(
            BundlePath.enclosingAppBundle(forExecutablePath:
                "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper"),
            "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app")
    }

    /// A widget extension is not its host application. Observed on macOS 26: about
    /// fifteen Apple applications seemed permanently open through this one path.
    func testNoBundleForPlugInProcesses() {
        XCTAssertNil(BundlePath.enclosingAppBundle(forExecutablePath:
            "/System/Applications/Notes.app/Contents/PlugIns/com.apple.Notes.WidgetExtension.appex/Contents/MacOS/com.apple.Notes.WidgetExtension"))
        XCTAssertNil(BundlePath.enclosingAppBundle(forExecutablePath:
            "/Library/Apple/System/Library/CoreServices/XProtect.app/Contents/XPCServices/XProtectPluginService.xpc/Contents/MacOS/XProtectPluginService"))
    }

    /// The counterpart of the previous test: a `.app` nested inside a `.app` is still
    /// an application, and must not be carried off by the plug-in exclusion.
    func testNestedAppBundleIsStillAnApplication() {
        XCTAssertEqual(
            BundlePath.enclosingAppBundle(forExecutablePath:
                "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper"),
            "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app")
    }

    func testNoBundleForPlainBinaries() {
        XCTAssertNil(BundlePath.enclosingAppBundle(forExecutablePath: "/usr/sbin/syslogd"))
        XCTAssertNil(BundlePath.enclosingAppBundle(forExecutablePath: "/usr/local/bin/macdeploy"))
    }

    func testLastComponent() {
        XCTAssertEqual(BundlePath.lastComponent("/Applications/Slack.app/Contents/MacOS/Slack"), "Slack")
        XCTAssertEqual(BundlePath.lastComponent("/usr/sbin/syslogd"), "syslogd")
    }
}
