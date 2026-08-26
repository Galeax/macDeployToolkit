import XCTest
@testable import MDTKit

/// Per-application log, equivalent of PSADT's `LogName`.
///
/// The value comes from the manifest and becomes a file name opened for writing by a
/// root process: without sanitization, it is an arbitrary-write primitive.
final class LogPathsTests: XCTestCase {

    // MARK: - Sanitization

    func testKeepsReasonableNames() {
        XCTAssertEqual(LogPaths.sanitize("Slack_4.36.140.log"), "Slack_4.36.140.log")
        XCTAssertEqual(LogPaths.sanitize("7-Zip_25.01"), "7-Zip_25.01.log")
    }

    /// The case that justifies everything else: a malicious `logName` must not be able
    /// to point at a file outside the logs directory.
    func testPathTraversalIsReducedToALeafName() {
        XCTAssertEqual(LogPaths.sanitize("../../etc/cron.d/backdoor"), "backdoor.log")
        XCTAssertEqual(LogPaths.sanitize("/etc/passwd"), "passwd.log")
        XCTAssertEqual(LogPaths.sanitize("../../../../var/db/x"), "x.log")
    }

    func testDisallowedCharactersAreReplaced() {
        XCTAssertEqual(LogPaths.sanitize("app;rm -rf /"), "app_rm_-rf.log")
        XCTAssertEqual(LogPaths.sanitize("app$(whoami)"), "app__whoami_.log")
        XCTAssertEqual(LogPaths.sanitize("app`id`"), "app_id_.log")
    }

    /// Without stripping leading dots, `...` would stay `...` and `.hidden` would
    /// produce an invisible log one would hunt for a long time.
    func testLeadingDotsAreStripped() {
        XCTAssertEqual(LogPaths.sanitize(".hidden"), "hidden.log")
        XCTAssertNil(LogPaths.sanitize("..."))
        XCTAssertNil(LogPaths.sanitize("."))
    }

    /// A name made only of separators identifies nothing.
    func testNamesWithoutAnyAlphanumericYieldNil() {
        XCTAssertNil(LogPaths.sanitize(""))
        XCTAssertNil(LogPaths.sanitize("/"))
        XCTAssertNil(LogPaths.sanitize("   "))
        XCTAssertNil(LogPaths.sanitize("___"))
        XCTAssertNil(LogPaths.sanitize("-.-"))
    }

    // MARK: - Resolution from the manifest

    /// A `logName` that already carries its version is used as-is.
    func testDeclaredLogNameAlreadyCarryingVersionIsUsedAsIs() {
        let manifest = Manifest(
            packageKey: "slack", displayName: "Slack", version: "4.36.140",
            logName: "Slack_4.36.140.log")
        XCTAssertEqual(LogPaths.fileName(for: manifest), "Slack_4.36.140.log")
        XCTAssertEqual(LogPaths.path(for: manifest), "/var/log/coreupdate/Slack_4.36.140.log")
    }

    /// The version is appended even to a declared `logName`, which departs from PSADT's
    /// literal `LogName`. Without it, every version of an application writes into the
    /// same file and we lose track of what each deployment did — yet this is the log we
    /// re-read when an update went wrong.
    func testDeclaredLogNameGainsTheVersion() {
        let manifest = Manifest(
            packageKey: "slack", displayName: "Slack", version: "4.36.140",
            logName: "slack-business.log")
        XCTAssertEqual(LogPaths.fileName(for: manifest), "slack-business_4.36.140.log")
    }

    /// Same convention as the `f"{application}_{version}.log"` of the Windows
    /// `coreupdate_config.json`.
    func testDerivedFromKeyAndVersionWhenAbsent() {
        let manifest = Manifest(packageKey: "slack-2026q3", displayName: "Slack", version: "4.36.140")
        XCTAssertEqual(LogPaths.fileName(for: manifest), "slack-2026q3_4.36.140.log")
    }

    /// A declared but unusable `logName` must not lose the log: we fall back to the
    /// derivation.
    func testUnsafeDeclaredNameFallsBackToDerivation() {
        let manifest = Manifest(
            packageKey: "slack", displayName: "Slack", version: "1.0", logName: "...")
        XCTAssertEqual(LogPaths.fileName(for: manifest), "slack_1.0.log")
    }

    func testLogNameDecodedFromManifest() throws {
        let manifest = try Manifest.decode(Data("""
        {"packageKey": "x", "AppName": "7-Zip", "AppVersion": "25.01", "LogName": "7-Zip_25.01.log"}
        """.utf8))
        XCTAssertEqual(LogPaths.path(for: manifest), "/var/log/coreupdate/7-Zip_25.01.log")
    }

    // MARK: - Extensible composite log

    /// The per-application log cannot be opened at startup: its name comes from the
    /// manifest, read afterward.
    func testCompositeLoggerAcceptsALateSink() {
        let first = MemoryLogger()
        let composite = CompositeLogger([first])
        composite.notice("before")

        let late = MemoryLogger()
        composite.attach(late)
        composite.notice("after")

        XCTAssertEqual(first.records.map(\.message), ["before", "after"])
        XCTAssertEqual(late.records.map(\.message), ["after"],
                       "a sink added midway does not replay the history")
    }

    func testCompositeLoggerIsAttachable() {
        let composite: DeployLogging = CompositeLogger([])
        XCTAssertNotNil(composite as? AttachableLogging)
    }
}
