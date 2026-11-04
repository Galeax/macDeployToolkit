import XCTest
@testable import MacADTKit

/// Compatibility with the `macadt_config.json` vocabulary of the Veille project.
///
/// Galeax packagers already write these files for the 264 Windows applications in
/// the catalog. Imposing a second vocabulary for macOS would add a mental
/// translation on every round trip, for zero benefit.
final class CompatibilityTests: XCTestCase {

    /// The case that matters: a Windows `macadt_config.json`, as-is, with the
    /// sole addition of `packageKey`.
    func testMacADTConfigIsAcceptedAlmostVerbatim() throws {
        let json = Data("""
        {
          "packageKey": "7-Zip",
          "AppName": "7-Zip",
          "AppVersion": "25.01",
          "AppVendor": "Igor Pavlov",
          "LogName": "7-Zip_25.01.log",
          "ProcessesToClose": ["7zFM"],
          "IgnoreExitCodes": [3010, 1641],
          "DeploymentType": "Install",
          "DeployMode": "Interactive"
        }
        """.utf8)

        let manifest = try Manifest.decode(json)
        XCTAssertEqual(manifest.displayName, "7-Zip")
        XCTAssertEqual(manifest.version, "25.01")
        XCTAssertEqual(manifest.publisher, "Igor Pavlov")
        XCTAssertEqual(manifest.logName, "7-Zip_25.01.log")
        XCTAssertEqual(manifest.ignoredExitCodes, [3010, 1641])
        XCTAssertEqual(manifest.action, .install)
        XCTAssertEqual(manifest.mode, .interactive)
        XCTAssertEqual(manifest.blockingApps.count, 1)
    }

    /// `ProcessesToClose` contains process names, not bundle IDs. Refusing this form
    /// would make converting the catalog impossible.
    func testProcessNameStringBecomesExecutableName() throws {
        let json = Data(#"{"packageKey": "x", "ProcessesToClose": ["7zFM"]}"#.utf8)
        let app = try XCTUnwrap(try Manifest.decode(json).blockingApps.first)

        XCTAssertNil(app.bundleIdentifier)
        XCTAssertEqual(app.executableName, "7zFM")
        XCTAssertEqual(app.displayName, "7zFM")
        XCTAssertEqual(app.identifier, "7zFM")
    }

    /// A string containing a dot is a bundle ID: on macOS they always contain one,
    /// executable names almost never.
    func testDottedStringBecomesBundleIdentifier() throws {
        let json = Data(#"{"packageKey": "x", "closeApps": ["com.tinyspeck.slackmacgap"]}"#.utf8)
        let app = try XCTUnwrap(try Manifest.decode(json).blockingApps.first)

        XCTAssertEqual(app.bundleIdentifier, "com.tinyspeck.slackmacgap")
        XCTAssertNil(app.executableName)
        XCTAssertEqual(app.displayName, "slackmacgap")
    }

    /// Without a bundle ID, the application is only identifiable by its process
    /// name; the per-PID SIGKILL then targets it via that name.
    func testAppsWithoutBundleIdentifierUseProcessName() throws {
        let json = Data("""
        {
          "packageKey": "x",
          "ProcessesToClose": ["7zFM", "com.google.Chrome"]
        }
        """.utf8)
        let manifest = try Manifest.decode(json)

        XCTAssertEqual(
            manifest.blockingApps.filter { $0.bundleIdentifier == nil }.map(\.identifier), ["7zFM"])
        XCTAssertNil(manifest.blockingApps[0].bundleIdentifier)
        XCTAssertNotNil(manifest.blockingApps[1].bundleIdentifier)
    }

    func testMixedShortAndLongFormsCoexist() throws {
        let json = Data("""
        {
          "packageKey": "x",
          "blockingApps": [
            "7zFM",
            { "bundleIdentifier": "com.tinyspeck.slackmacgap", "displayName": "Slack" },
            { "process": "vcredist_x64", "name": "Visual C++ Redistributable" }
          ]
        }
        """.utf8)
        let apps = try Manifest.decode(json).blockingApps

        XCTAssertEqual(apps.count, 3)
        XCTAssertEqual(apps[0].executableName, "7zFM")
        XCTAssertEqual(apps[1].displayName, "Slack")
        XCTAssertEqual(apps[2].executableName, "vcredist_x64")
        XCTAssertEqual(apps[2].displayName, "Visual C++ Redistributable")
    }

    func testRejectsBlockingAppWithNoIdentifierAtAll() {
        let json = Data(#"{"packageKey": "x", "blockingApps": [{"displayName": "Slack"}]}"#.utf8)
        XCTAssertThrowsError(try Manifest.decode(json))
    }

    // MARK: - Tolerance on key shape

    func testKeysAreAcceptedInPascalCaseAndSnakeCase() throws {
        let pascal = try Manifest.decode(Data("""
        {"PackageKey": "x", "DisplayName": "Slack", "Version": "1.0", "Mode": "silent"}
        """.utf8))
        let snake = try Manifest.decode(Data("""
        {"package_key": "x", "display_name": "Slack", "version": "1.0", "mode": "silent"}
        """.utf8))

        XCTAssertEqual(pascal.displayName, "Slack")
        XCTAssertEqual(pascal.mode, .silent)
        XCTAssertEqual(snake.displayName, "Slack")
        XCTAssertEqual(snake.mode, .silent)
    }

    /// `RegistryName` is the stable per-application identifier on the Veille side
    /// (93 apps declare it): it makes an acceptable `packageKey`.
    func testRegistryNameServesAsPackageKey() throws {
        let manifest = try Manifest.decode(Data(#"{"RegistryName": "7-Zip"}"#.utf8))
        XCTAssertEqual(manifest.packageKey, "7-Zip")
    }

    /// `packageKey` stays required, and is never derived from `AppName`: an automatic
    /// derivation would mean a mere display rename would hand their deferrals back to
    /// every user in the fleet.
    func testPackageKeyIsNeverDerivedFromAppName() {
        let json = Data(#"{"AppName": "Slack", "AppVersion": "4.0"}"#.utf8)
        XCTAssertThrowsError(try Manifest.decode(json))
    }

    // MARK: - PSADT enumeration values

    func testPsadtDeploymentTypesAndModes() throws {
        for (raw, expected) in [("Install", DeploymentAction.install),
                                ("Uninstall", .uninstall),
                                ("Repair", .repair)] {
            XCTAssertEqual(DeploymentAction(lenient: raw), expected)
        }
        XCTAssertEqual(DeploymentMode(lenient: "NonInteractive"), .nonInteractive)
        XCTAssertEqual(DeploymentMode(lenient: "Silent"), .silent)
        XCTAssertNil(DeploymentAction(lenient: "Migrate"))
    }

    /// PSADT knows an `Auto` mode: dialogs if a user is logged in. The engine already
    /// switches on its own in that case, so `Auto` == interactive.
    func testAutoModeMapsToInteractive() throws {
        let manifest = try Manifest.decode(Data(#"{"packageKey": "x", "DeployMode": "Auto"}"#.utf8))
        XCTAssertEqual(manifest.mode, .interactive)
    }

    func testRejectsUnknownEnumValueRatherThanDefaulting() {
        XCTAssertThrowsError(
            try Manifest.decode(Data(#"{"packageKey": "x", "mode": "Turbo"}"#.utf8)))
    }

    // MARK: - Deferral policy aliases

    func testDeferralAcceptsPsadtParameterNames() throws {
        let json = Data("""
        {
          "packageKey": "x",
          "deferral": {
            "AllowDefer": true,
            "DeferTimes": 5,
            "DeferDays": 7,
            "ForceCountdown": 120,
            "CloseProcessesCountdown": 30,
            "PersistPrompt": 90
          }
        }
        """.utf8)
        let policy = try Manifest.decode(json).deferral

        XCTAssertEqual(policy.maxDeferrals, 5)
        XCTAssertEqual(policy.deferralDays, 7)
        XCTAssertEqual(policy.countdownSeconds, 120)
        XCTAssertEqual(policy.uninstallCountdownSeconds, 30)
        XCTAssertEqual(policy.persistPromptSeconds, 90)
    }

    /// `0` explicitly disables persistence; an absent key takes the default of 60 s.
    /// The two cases must be distinguished.
    func testPersistPromptZeroDisablesIt() throws {
        let disabled = try Manifest.decode(Data("""
        {"packageKey": "x", "deferral": {"persistPromptSeconds": 0}}
        """.utf8))
        XCTAssertNil(disabled.deferral.persistPromptSeconds)

        let defaulted = try Manifest.decode(Data(#"{"packageKey": "x", "deferral": {}}"#.utf8))
        XCTAssertEqual(defaulted.deferral.persistPromptSeconds, 60)
    }

    // MARK: - Action-dependent countdown

    func testCountdownDependsOnAction() {
        let policy = DeferralPolicy(countdownSeconds: 300, uninstallCountdownSeconds: 60)
        XCTAssertEqual(policy.countdown(for: .install), 300)
        XCTAssertEqual(policy.countdown(for: .uninstall), 60)
        XCTAssertEqual(policy.countdown(for: .repair), 60,
                       "a repair also closes applications: same delay as an uninstall")
    }

    /// The engine must resolve the countdown from the manifest's action, not blindly
    /// take `countdownSeconds`.
    func testEngineUsesUninstallCountdownForUninstallAction() {
        let slack = BlockingAppSpec(bundleIdentifier: "com.tinyspeck.slackmacgap", displayName: "Slack")
        var manifest = Manifest(
            packageKey: "slack", displayName: "Slack", version: "1.0",
            action: .uninstall,
            blockingApps: [slack],
            deferral: DeferralPolicy(maxDeferrals: 0),
            uninstall: UninstallSpec(paths: ["/Applications/Slack.app"]))

        let decision = DeferralEngine().evaluate(
            manifest: manifest, state: DeploymentState(packageKey: "slack"),
            context: DeploymentContext(runningBlockingApps: [slack]),
            now: Date(timeIntervalSince1970: 1_770_000_000))

        guard case .prompt(let request) = decision else { return XCTFail("expected a dialog") }
        XCTAssertEqual(request.countdownSeconds, 60)

        manifest.action = .install
        let installDecision = DeferralEngine().evaluate(
            manifest: manifest, state: DeploymentState(packageKey: "slack"),
            context: DeploymentContext(runningBlockingApps: [slack]),
            now: Date(timeIntervalSince1970: 1_770_000_000))
        guard case .prompt(let installRequest) = installDecision else {
            return XCTFail("expected a dialog")
        }
        XCTAssertEqual(installRequest.countdownSeconds, 300)
    }

    // MARK: - Applying command-line overrides

    private func manifest(action: DeploymentAction = .install, mode: DeploymentMode = .interactive) -> Manifest {
        Manifest(
            packageKey: "slack", displayName: "Slack", version: "1.0",
            action: action, mode: mode,
            uninstall: UninstallSpec(paths: ["/Applications/Slack.app"]))
    }

    func testModeOverrideWinsOverManifest() throws {
        let options = try CommandLineOptions.parse(["pre", "-m", "/x", "--mode", "Silent"])
        XCTAssertEqual(try manifest(mode: .interactive).applying(options).mode, .silent)
    }

    /// The bug this mechanism fixes: running `macadt-deploy uninstall` on a manifest
    /// declaring `action: install` would use the install countdown (300 s) instead of
    /// the uninstall one (60 s), and the divergence would be silent.
    func testSubcommandOverridesManifestAction() throws {
        let options = try CommandLineOptions.parse(["uninstall", "-m", "/x"])
        let effective = try manifest(action: .install).applying(options)

        XCTAssertEqual(effective.action, .uninstall)
        XCTAssertEqual(effective.deferral.countdown(for: effective.action), 60)
    }

    func testRepairSubcommandImpliesRepairAction() throws {
        let options = try CommandLineOptions.parse(["repair", "-m", "/x"])
        XCTAssertEqual(try manifest(action: .install).applying(options).action, .repair)
    }

    /// `pre` and `post` frame an installation as well as a repair: it is up to the
    /// manifest to decide.
    func testPreAndPostLeaveManifestActionAlone() throws {
        for command in ["pre", "post"] {
            let options = try CommandLineOptions.parse([command, "-m", "/x"])
            XCTAssertEqual(try manifest(action: .repair).applying(options).action, .repair)
        }
    }

    /// Precedence order: manifest < subcommand < explicit flag.
    func testExplicitFlagBeatsImpliedAction() throws {
        let options = try CommandLineOptions.parse(["uninstall", "-m", "/x", "--action", "Repair"])
        XCTAssertEqual(try manifest(action: .install).applying(options).action, .repair)
    }

    /// The override goes back through validation: an `uninstall` action without an
    /// `uninstall` block must be refused, even when it comes from the command line.
    func testOverrideIsRevalidated() throws {
        let options = try CommandLineOptions.parse(["uninstall", "-m", "/x"])
        let withoutSpec = Manifest(packageKey: "slack", displayName: "Slack", version: "1.0")
        XCTAssertThrowsError(try withoutSpec.applying(options)) { error in
            guard case ManifestError.missingUninstallSpec = error else {
                return XCTFail("expected .missingUninstallSpec, got \(error)")
            }
        }
    }

    // MARK: - Key normalization

    func testNormalizationStripsCaseAndSeparators() {
        XCTAssertEqual(LenientContainer.normalize("AppVersion"), "appversion")
        XCTAssertEqual(LenientContainer.normalize("app_version"), "appversion")
        XCTAssertEqual(LenientContainer.normalize("app-version"), "appversion")
        XCTAssertEqual(LenientContainer.normalize("APP VERSION"), "appversion")
    }
}
