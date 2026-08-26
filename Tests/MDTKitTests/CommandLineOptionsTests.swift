import XCTest
@testable import MDTKit

final class CommandLineOptionsTests: XCTestCase {

    func testParsesCommandAndManifest() throws {
        let options = try CommandLineOptions.parse(["pre", "--manifest", "/tmp/slack.json"])
        XCTAssertEqual(options.command, .pre)
        XCTAssertEqual(options.manifestPath, "/tmp/slack.json")
        XCTAssertFalse(options.dryRun)
    }

    func testParsesEveryFlag() throws {
        let options = try CommandLineOptions.parse([
            "post", "-m", "/tmp/x.json", "--dry-run", "--verbose", "--json",
            "--force", "-l", "fr", "--log", "/tmp/log", "--state", "/tmp/state.plist",
            "--dialog", "/opt/dialog",
        ])
        XCTAssertEqual(options.command, .post)
        XCTAssertTrue(options.dryRun)
        XCTAssertTrue(options.verbose)
        XCTAssertTrue(options.json)
        XCTAssertTrue(options.force)
        XCTAssertEqual(options.language, "fr")
        XCTAssertEqual(options.logPath, "/tmp/log")
        XCTAssertEqual(options.statePath, "/tmp/state.plist")
        XCTAssertEqual(options.dialogPath, "/opt/dialog")
    }

    func testShortFlagsMatchLongOnes() throws {
        let short = try CommandLineOptions.parse(["pre", "-m", "/x", "-n", "-v", "-f"])
        let long = try CommandLineOptions.parse(["pre", "--manifest", "/x", "--dry-run", "--verbose", "--force"])
        XCTAssertEqual(short, long)
    }

    func testDefaultsPointAtProductionPaths() throws {
        let options = try CommandLineOptions.parse(["status"])
        XCTAssertEqual(options.logPath, FileLogger.defaultPath)
        XCTAssertEqual(options.statePath, PlistStateStore.defaultDirectory.path)
        XCTAssertEqual(options.dialogPath, CommandLineOptions.defaultDialogPath)
    }

    func testHelpAndVersionAreAcceptedAsFlags() throws {
        XCTAssertEqual(try CommandLineOptions.parse(["--help"]).command, .help)
        XCTAssertEqual(try CommandLineOptions.parse(["-h"]).command, .help)
        XCTAssertEqual(try CommandLineOptions.parse(["--version"]).command, .version)
        XCTAssertEqual(try CommandLineOptions.parse(["-V"]).command, .version)
    }

    func testRejectsMissingCommand() {
        XCTAssertThrowsError(try CommandLineOptions.parse([])) { error in
            XCTAssertEqual(error as? ArgumentError, .missingCommand)
        }
    }

    func testRejectsUnknownCommandAndFlag() {
        XCTAssertThrowsError(try CommandLineOptions.parse(["deploy"])) { error in
            XCTAssertEqual(error as? ArgumentError, .unknownCommand("deploy"))
        }
        XCTAssertThrowsError(try CommandLineOptions.parse(["pre", "-m", "/x", "--turbo"])) { error in
            XCTAssertEqual(error as? ArgumentError, .unknownFlag("--turbo"))
        }
    }

    func testRejectsFlagWithoutValue() {
        XCTAssertThrowsError(try CommandLineOptions.parse(["pre", "--manifest"])) { error in
            XCTAssertEqual(error as? ArgumentError, .missingValue(flag: "--manifest"))
        }
    }

    /// A forgotten value must not turn the next option into a file name: without
    /// this safeguard we would write the state into a file literally called
    /// "--verbose".
    func testRejectsFlagSwallowingAnotherFlag() {
        XCTAssertThrowsError(try CommandLineOptions.parse(["pre", "--manifest", "--verbose"])) { error in
            XCTAssertEqual(error as? ArgumentError, .missingValue(flag: "--manifest"))
        }
    }

    func testCommandsRequiringManifest() {
        for command in ["pre", "post", "uninstall", "repair"] {
            XCTAssertThrowsError(try CommandLineOptions.parse([command])) { error in
                XCTAssertEqual(error as? ArgumentError, .manifestRequired(command: command))
            }
        }
    }

    func testResetAcceptsEitherManifestOrPackageKey() throws {
        XCTAssertEqual(try CommandLineOptions.parse(["reset", "-k", "slack"]).packageKey, "slack")
        XCTAssertEqual(try CommandLineOptions.parse(["reset", "-m", "/x"]).manifestPath, "/x")
        XCTAssertThrowsError(try CommandLineOptions.parse(["reset"])) { error in
            XCTAssertEqual(error as? ArgumentError, .targetRequired(command: "reset"))
        }
    }

    func testStatusNeedsNothing() throws {
        XCTAssertEqual(try CommandLineOptions.parse(["status"]).command, .status)
    }

    // MARK: - Mode and action overrides

    /// CoreUpdate lets the operator choose the `DeployMode` per deployment in its UI,
    /// exactly as it does for Windows via `-DeployMode`. Without this flag, that
    /// choice would have no way to reach the agent.
    func testModeOverrideAcceptsPsadtCasing() throws {
        XCTAssertEqual(
            try CommandLineOptions.parse(["pre", "-m", "/x", "--mode", "Interactive"]).modeOverride,
            .interactive)
        XCTAssertEqual(
            try CommandLineOptions.parse(["pre", "-m", "/x", "--mode", "NonInteractive"]).modeOverride,
            .nonInteractive)
        XCTAssertEqual(
            try CommandLineOptions.parse(["pre", "-m", "/x", "--deploy-mode", "Silent"]).modeOverride,
            .silent)
        XCTAssertEqual(
            try CommandLineOptions.parse(["pre", "-m", "/x", "--mode", "Auto"]).modeOverride,
            .interactive)
    }

    func testActionOverrideAcceptsPsadtNames() throws {
        XCTAssertEqual(
            try CommandLineOptions.parse(["pre", "-m", "/x", "--action", "Uninstall"]).actionOverride,
            .uninstall)
        XCTAssertEqual(
            try CommandLineOptions.parse(["pre", "-m", "/x", "--deployment-type", "Repair"]).actionOverride,
            .repair)
    }

    func testRejectsUnknownModeRatherThanDefaulting() {
        XCTAssertThrowsError(
            try CommandLineOptions.parse(["pre", "-m", "/x", "--mode", "Turbo"])
        ) { error in
            XCTAssertEqual(error as? ArgumentError, .invalidValue(flag: "--mode", value: "Turbo"))
        }
    }

    func testNoOverrideByDefault() throws {
        let options = try CommandLineOptions.parse(["pre", "-m", "/x"])
        XCTAssertNil(options.modeOverride)
        XCTAssertNil(options.actionOverride)
    }

    /// The action follows from the subcommand, not only from the manifest.
    func testCommandsImplyAnAction() {
        XCTAssertEqual(CommandLineOptions.Command.uninstall.impliedAction, .uninstall)
        XCTAssertEqual(CommandLineOptions.Command.repair.impliedAction, .repair)
        XCTAssertNil(CommandLineOptions.Command.pre.impliedAction,
                     "`pre` must leave the manifest to decide: it frames an install or a repair")
        XCTAssertNil(CommandLineOptions.Command.post.impliedAction)
        XCTAssertNil(CommandLineOptions.Command.status.impliedAction)
    }
}
