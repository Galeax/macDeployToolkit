import XCTest
@testable import MDTKit

final class ManifestTests: XCTestCase {

    /// The test that matters for the format's ergonomics: a manifest reduced to its
    /// key must be valid, with every default applying. Swift does not do this on its
    /// own with Codable, hence the explicit `init(from:)`.
    func testMinimalManifestGetsAllDefaults() throws {
        let json = Data(#"{"packageKey": "slack"}"#.utf8)
        let manifest = try Manifest.decode(json)

        XCTAssertEqual(manifest.packageKey, "slack")
        XCTAssertEqual(manifest.displayName, "slack", "displayName must fall back to packageKey")
        XCTAssertEqual(manifest.action, .install)
        XCTAssertEqual(manifest.mode, .interactive)
        XCTAssertTrue(manifest.blockingApps.isEmpty)
        XCTAssertEqual(manifest.deferral.maxDeferrals, 3)
        XCTAssertTrue(manifest.deferral.allowDeferral)
        // 300 s on install, 60 s on uninstall: values measured on the 269
        // production applications of the Veille catalog, not estimated.
        XCTAssertEqual(manifest.deferral.countdownSeconds, 300)
        XCTAssertEqual(manifest.deferral.uninstallCountdownSeconds, 60)
        XCTAssertEqual(manifest.deferral.persistPromptSeconds, 60)
        XCTAssertEqual(manifest.deferral.maxDialogSeconds, 1_200)
        XCTAssertTrue(manifest.requirements.respectPresentationMode)
        XCTAssertTrue(manifest.ignoredExitCodes.isEmpty)
        XCTAssertNil(manifest.hooks)
    }

    func testFullManifestRoundTrip() throws {
        let json = Data("""
        {
          "packageKey": "slack-2026q3",
          "displayName": "Slack",
          "version": "4.36.140",
          "mode": "interactive",
          "blockingApps": [
            { "bundleIdentifier": "com.tinyspeck.slackmacgap", "displayName": "Slack" }
          ],
          "deferral": {
            "maxDeferrals": 5,
            "deferralDays": 7,
            "deadline": "2026-09-01T18:00:00Z",
            "countdownSeconds": 600
          },
          "requirements": { "minimumFreeBytes": 2000000000, "minimumOSVersion": "14.0" },
          "detection": {
            "bundlePath": "/Applications/Slack.app",
            "expectedVersion": "4.36.140"
          }
        }
        """.utf8)

        let manifest = try Manifest.decode(json)
        XCTAssertEqual(manifest.deferral.maxDeferrals, 5)
        XCTAssertEqual(manifest.deferral.deferralDays, 7)
        XCTAssertEqual(manifest.deferral.countdownSeconds, 600)
        XCTAssertEqual(manifest.requirements.minimumOSVersion, "14.0")
        XCTAssertEqual(manifest.detection?.bundlePath, "/Applications/Slack.app")
        XCTAssertEqual(manifest.blockingApps.first?.bundleIdentifier, "com.tinyspeck.slackmacgap")

        let expected = Date(timeIntervalSince1970: 1_788_285_600) // 2026-09-01T18:00:00Z
        XCTAssertEqual(manifest.deferral.deadline, expected)
    }

    func testDisplayNameDerivedFromBundleIdentifier() throws {
        let json = Data("""
        {
          "packageKey": "x",
          "blockingApps": [{ "bundleIdentifier": "com.microsoft.Excel" }]
        }
        """.utf8)
        let manifest = try Manifest.decode(json)
        XCTAssertEqual(manifest.blockingApps.first?.displayName, "Excel")
    }

    func testRejectsFutureSchemaVersion() {
        let json = Data(#"{"packageKey": "x", "schemaVersion": 99}"#.utf8)
        XCTAssertThrowsError(try Manifest.decode(json)) { error in
            guard case ManifestError.unsupportedSchema = error else {
                return XCTFail("expected .unsupportedSchema, got \(error)")
            }
        }
    }

    func testRejectsEmptyPackageKey() {
        let json = Data(#"{"packageKey": ""}"#.utf8)
        XCTAssertThrowsError(try Manifest.decode(json))
    }

    /// An `uninstall` action without an `uninstall` block would produce a run that
    /// uninstalls nothing while reporting success. We refuse it at read time.
    func testRejectsUninstallActionWithoutSpec() {
        let json = Data(#"{"packageKey": "x", "action": "uninstall"}"#.utf8)
        XCTAssertThrowsError(try Manifest.decode(json)) { error in
            guard case ManifestError.missingUninstallSpec = error else {
                return XCTFail("expected .missingUninstallSpec, got \(error)")
            }
        }
    }

    func testUninstallSpecDecodes() throws {
        let json = Data("""
        {
          "packageKey": "x",
          "action": "uninstall",
          "uninstall": {
            "packageIdentifiers": ["com.tinyspeck.slackmacgap"],
            "paths": ["/Applications/Slack.app"],
            "launchdLabels": ["com.tinyspeck.helper"],
            "preservedPaths": ["~/Library/Application Support/Slack"]
          }
        }
        """.utf8)
        let manifest = try Manifest.decode(json)
        XCTAssertEqual(manifest.uninstall?.packageIdentifiers, ["com.tinyspeck.slackmacgap"])
        XCTAssertEqual(manifest.uninstall?.launchdLabels, ["com.tinyspeck.helper"])
        XCTAssertEqual(manifest.uninstall?.preservedPaths.count, 1)
    }

    // MARK: - Localization

    /// Providing a single language must not make the English fallback disappear.
    func testProvidedStringsMergeOverBuiltIns() throws {
        let json = Data("""
        {
          "packageKey": "x",
          "messages": {
            "strings": {
              "fr": {
                "title": "Deploiement Galeax",
                "closeAppsBody": "b", "deferButton": "c", "closeButton": "d",
                "finalWarningBody": "e", "progressTitle": "f", "restartBody": "g"
              }
            }
          }
        }
        """.utf8)
        let manifest = try Manifest.decode(json)
        XCTAssertEqual(manifest.messages.resolve(for: "fr").title, "Deploiement Galeax")
        XCTAssertEqual(manifest.messages.resolve(for: "en").title, "Software update")
    }

    func testResolveHandlesRegionalCodesAndUnknownLanguages() {
        let messages = Messages()
        XCTAssertEqual(messages.resolve(for: "fr-FR").title, "Mise a jour logicielle")
        XCTAssertEqual(messages.resolve(for: "de-DE").title, "Software update",
                       "an unknown language must fall back to English")
    }
}
