import XCTest
@testable import MDTKit

/// Verifies that the manifests shipped in `Examples/` are valid.
///
/// These are not decorative tests: these files are what a packager copies to get
/// started. An example that does not parse is an example that costs the first
/// person who uses it half a day.
final class ExamplesTests: XCTestCase {

    private var examplesDirectory: URL {
        URL(fileURLWithPath: #filePath)      // Tests/MDTKitTests/ExamplesTests.swift
            .deletingLastPathComponent()      // Tests/MDTKitTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // repository root
            .appendingPathComponent("Examples")
    }

    func testEveryExampleManifestParses() throws {
        let files = try FileManager.default
            .contentsOfDirectory(at: examplesDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }

        XCTAssertFalse(files.isEmpty, "no example found in \(examplesDirectory.path)")

        for file in files {
            XCTAssertNoThrow(
                try Manifest.load(contentsOf: file),
                "\(file.lastPathComponent) does not parse")
        }
    }

    func testSlackExampleIsCoherent() throws {
        let manifest = try Manifest.load(
            contentsOf: examplesDirectory.appendingPathComponent("slack.json"))

        XCTAssertEqual(manifest.packageKey, "slack-2026q3")
        XCTAssertEqual(manifest.mode, .interactive)
        XCTAssertEqual(manifest.deferral.maxDeferrals, 3)
        XCTAssertEqual(manifest.deferral.deferralDays, 7)
        XCTAssertNotNil(manifest.deferral.deadline)
        XCTAssertEqual(manifest.detection?.bundlePath, "/Applications/Slack.app")
        XCTAssertEqual(manifest.restartAction, RestartAction.none)
    }

    /// The example's uninstall plan must produce something sane: the bundle is
    /// removed, and the preserved path is indeed spared.
    func testSlackExampleProducesASafeUninstallPlan() throws {
        let manifest = try Manifest.load(
            contentsOf: examplesDirectory.appendingPathComponent("slack.json"))
        let spec = try XCTUnwrap(manifest.uninstall)

        let plan = UninstallPlanner().plan(
            spec: spec, homeDirectories: ["/Users/romain"])

        XCTAssertTrue(plan.deletions.contains("/Applications/Slack.app"))
        XCTAssertTrue(plan.deletions.contains("/Users/romain/Library/Caches/com.tinyspeck.slackmacgap"))
        // `~/Library/Application Support/Slack` contains a preserved path, so it is
        // kept in full — and the warning must say so.
        XCTAssertFalse(plan.deletions.contains("/Users/romain/Library/Application Support/Slack"))
        XCTAssertTrue(plan.warnings.contains { $0.contains("storage") })
        XCTAssertEqual(plan.receiptsToForget, ["com.tinyspeck.slackmacgap"])
    }

    /// The example taken from a Windows `coreupdate_config.json` must parse with no
    /// translation at all, apart from adding `packageKey`.
    func testCoreUpdateExampleParsesAsIs() throws {
        let manifest = try Manifest.load(
            contentsOf: examplesDirectory.appendingPathComponent("from-coreupdate.json"))

        XCTAssertEqual(manifest.packageKey, "7-Zip")
        XCTAssertEqual(manifest.displayName, "7-Zip")
        XCTAssertEqual(manifest.version, "25.01")
        XCTAssertEqual(manifest.publisher, "Igor Pavlov")
        XCTAssertEqual(manifest.ignoredExitCodes, [3010, 1641])
        XCTAssertEqual(manifest.deferral.countdownSeconds, 300)
        XCTAssertEqual(manifest.deferral.persistPromptSeconds, 60)

        // `7zFM` is a process name, not a bundle ID: the per-PID SIGKILL still
        // targets it via the executable name.
        XCTAssertEqual(manifest.blockingApps.first?.executableName, "7zFM")
        XCTAssertNil(manifest.blockingApps.first?.bundleIdentifier)
        XCTAssertEqual(manifest.blockingApps.filter { $0.bundleIdentifier == nil }.count, 1)
    }

    /// The example's hooks must resolve to files that are actually shipped: an
    /// example whose paths point nowhere costs the first person who uses it half a
    /// day.
    func testHookExampleReferencesExistingScripts() throws {
        let manifestURL = examplesDirectory.appendingPathComponent("with-hooks.json")
        let manifest = try Manifest.load(contentsOf: manifestURL)
        let hooks = try XCTUnwrap(manifest.hooks)
        let directory = manifestURL.deletingLastPathComponent().path

        for phase in [HookPhase.preInstall, .postInstall] {
            let reference = try XCTUnwrap(hooks.reference(for: phase))
            let resolved = try HookResolver.resolve(
                reference: reference, manifestDirectory: directory).get()

            XCTAssertTrue(FileManager.default.fileExists(atPath: resolved),
                          "\(phase.rawValue) points to a missing file: \(resolved)")
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: resolved),
                          "\(phase.rawValue) is not executable: \(resolved)")
        }
        XCTAssertEqual(manifest.ignoredExitCodes, [42])
    }

    /// The wrapper model: Intune deploys our pkg, which contains the vendor's DMG.
    /// This is what unblocks the 7 applications that are `macOSDmgApp` today, a type
    /// for which Intune accepts no script.
    func testDmgWrapperExampleDeclaresAPayload() throws {
        let manifest = try Manifest.load(
            contentsOf: examplesDirectory.appendingPathComponent("chrome-dmg-wrapper.json"))
        let payload = try XCTUnwrap(manifest.payload)

        XCTAssertEqual(payload.file, "payload/GoogleChrome.dmg")
        XCTAssertEqual(payload.installLocation, "/Applications")

        // The path must stay confined to the manifest directory, like the hooks.
        let root = "/Library/Application Support/CoreUpdate/Deploy/manifests/chrome-2026q3"
        XCTAssertEqual(
            PathSafety.confine(payload.file, within: root),
            root + "/payload/GoogleChrome.dmg")

        // Chrome is declared by bundle ID, the most reliable targeting for the SIGKILL.
        XCTAssertTrue(manifest.blockingApps.allSatisfy { $0.bundleIdentifier != nil })
        XCTAssertEqual(manifest.blockingApps.first?.bundleIdentifier, "com.google.Chrome")
    }

    func testMinimalExampleReliesEntirelyOnDefaults() throws {
        let manifest = try Manifest.load(
            contentsOf: examplesDirectory.appendingPathComponent("minimal.json"))
        XCTAssertEqual(manifest.packageKey, "internal-tool")
        XCTAssertEqual(manifest.mode, .interactive)
        XCTAssertEqual(manifest.deferral.maxDeferrals, 3)
    }

    /// The "urgent security" example must behave as its name suggests: a single
    /// deferral, and a locked screen does not protect.
    func testSecurityExampleIsAggressiveByDesign() throws {
        let manifest = try Manifest.load(
            contentsOf: examplesDirectory.appendingPathComponent("urgent-security.json"))

        XCTAssertEqual(manifest.deferral.maxDeferrals, 1)
        XCTAssertFalse(manifest.requirements.respectScreenLock)
        XCTAssertTrue(manifest.requirements.respectPresentationMode)
        XCTAssertEqual(manifest.messages.resolve(for: "fr").title,
                       "Correctif de securite obligatoire")
        // The built-in English fallback must survive the French override.
        XCTAssertEqual(manifest.messages.resolve(for: "en").title, "Software update")

        // After the single deferral, the final warning is immediate.
        var state = DeploymentState(packageKey: manifest.packageKey)
        state.deferralsUsed = 1
        let decision = DeferralEngine().evaluate(
            manifest: manifest, state: state,
            context: DeploymentContext(runningBlockingApps: manifest.blockingApps),
            now: Date(timeIntervalSince1970: 1_770_000_000))
        guard case .prompt(let request) = decision else {
            return XCTFail("expected a dialog, got \(decision)")
        }
        XCTAssertTrue(request.isFinalWarning)
        XCTAssertEqual(request.countdownSeconds, 300)
    }
}
