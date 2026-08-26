import XCTest
@testable import MDTKit

final class DialogSpecTests: XCTestCase {

    private let utc = TimeZone(secondsFromGMT: 0)!
    private let deadline = Date(timeIntervalSince1970: 1_788_285_600) // 2026-09-01T18:00:00Z

    private let slack = BlockingAppSpec(
        bundleIdentifier: "com.tinyspeck.slackmacgap", displayName: "Slack")
    private let teams = BlockingAppSpec(
        bundleIdentifier: "com.microsoft.teams2", displayName: "Microsoft Teams")

    private func manifest() -> Manifest {
        Manifest(packageKey: "slack", displayName: "Slack", version: "4.36.140")
    }

    private func request(
        canDefer: Bool,
        isFinal: Bool,
        remaining: Int = 2,
        closesOnTimeout: Bool = false
    ) -> PromptRequest {
        PromptRequest(
            apps: [slack, teams], canDefer: canDefer, deferralsRemaining: remaining,
            deadline: deadline, countdownSeconds: 600,
            persistIntervalSeconds: 60, maxDialogSeconds: 1_200,
            isFinalWarning: isFinal, closesOnTimeout: closesOnTimeout)
    }

    // MARK: - Templating

    func testUnknownTokensAreLeftVisible() {
        let rendered = Template.render("{name} and {unknown}", values: ["name": "Slack"])
        XCTAssertEqual(rendered, "Slack and {unknown}",
                       "an unsubstituted token must stand out, not disappear")
    }

    func testAppListIsMarkdownBullets() {
        XCTAssertEqual(Template.appList([slack, teams]), "- Slack\n- Microsoft Teams")
    }

    func testDeadlineFormatIsIndependentOfSystemLocale() {
        XCTAssertEqual(Template.formatDeadline(deadline, languageCode: "fr", timeZone: utc),
                       "01/09/2026 a 18:00")
        XCTAssertEqual(Template.formatDeadline(deadline, languageCode: "en", timeZone: utc),
                       "2026-09-01 at 18:00")
    }

    func testMissingDeadlineRendersEmptyRatherThanToken() {
        let noDeadline = PromptRequest(
            apps: [slack], canDefer: true, deferralsRemaining: 1,
            deadline: nil, countdownSeconds: 300, isFinalWarning: false)
        let values = Template.values(
            manifest: manifest(), request: noDeadline, languageCode: "fr", timeZone: utc)
        XCTAssertEqual(values["deadline"], "")
    }

    func testValuesCoverEveryDocumentedToken() {
        let values = Template.values(
            manifest: manifest(), request: request(canDefer: true, isFinal: false),
            languageCode: "fr", timeZone: utc)
        XCTAssertEqual(values["name"], "Slack")
        XCTAssertEqual(values["version"], "4.36.140")
        XCTAssertEqual(values["deferrals"], "2")
        XCTAssertEqual(values["apps"], "- Slack\n- Microsoft Teams")
        XCTAssertEqual(values["deadline"], "01/09/2026 a 18:00")
    }

    // MARK: - Dialog construction

    /// `forceCloseWhenExhausted: false` policy: nothing closes without a click, so
    /// no timer — its expiry could not trigger anything.
    func testDeferrableDialogWithoutForceCloseHasNoTimer() {
        let spec = DialogSpec.closeApps(
            manifest: manifest(), request: request(canDefer: true, isFinal: false),
            languageCode: "fr", timeZone: utc)

        XCTAssertNotNil(spec.button2)
        XCTAssertTrue(spec.button2!.contains("2"), "the button must announce the deferrals remaining")
        XCTAssertNil(spec.timerSeconds)
        XCTAssertEqual(spec.persistIntervalSeconds, 60, "persistence stays the only recourse")
        XCTAssertEqual(spec.maxTotalSeconds, 1_200)
        XCTAssertFalse(spec.isBlocking)
        XCTAssertTrue(spec.message.contains("- Slack"))
    }

    /// The default case in production: a deferral stays possible, but no response
    /// within the countdown triggers the install. Without that timer, a dialog left
    /// open would suspend the deployment with no end.
    func testDeferrableDialogGetsResponseCountdownWhenForceCloseAllowed() {
        let spec = DialogSpec.closeApps(
            manifest: manifest(),
            request: request(canDefer: true, isFinal: false, closesOnTimeout: true),
            languageCode: "fr", timeZone: utc)

        XCTAssertNotNil(spec.button2, "the deferral is still offered")
        XCTAssertEqual(spec.timerSeconds, 600)
        XCTAssertEqual(spec.maxTotalSeconds, 600, "the budget is the countdown itself")
        XCTAssertFalse(spec.isBlocking, "this is not a final warning yet")
    }

    /// The timer replaces persistence: a dialog that shows its own countdown does
    /// not need to be relaunched, and `--ontop` keeps it in front.
    func testResponseCountdownReplacesPersistence() {
        let spec = DialogSpec.closeApps(
            manifest: manifest(),
            request: request(canDefer: true, isFinal: false, closesOnTimeout: true),
            languageCode: "fr", timeZone: utc)

        XCTAssertNil(spec.persistIntervalSeconds)
        XCTAssertFalse(spec.arguments().contains("--hidetimerbar"),
                       "this timer is a real deadline: its bar must be visible")
    }

    func testFinalWarningIsBlockingTimedAndSingleButton() {
        let spec = DialogSpec.closeApps(
            manifest: manifest(), request: request(canDefer: false, isFinal: true, remaining: 0),
            languageCode: "fr", timeZone: utc)

        XCTAssertNil(spec.button2)
        XCTAssertEqual(spec.timerSeconds, 600)
        XCTAssertTrue(spec.isBlocking)
        XCTAssertTrue(spec.message.contains("immediatement"),
                      "the final warning must use finalWarningBody")
    }

    func testExhaustedWithoutForceCloseHasNeitherDeferNorTimer() {
        let spec = DialogSpec.closeApps(
            manifest: manifest(), request: request(canDefer: false, isFinal: false, remaining: 0),
            languageCode: "fr", timeZone: utc)
        XCTAssertNil(spec.button2)
        XCTAssertNil(spec.timerSeconds)
        XCTAssertFalse(spec.isBlocking)
    }

    func testEnglishFallbackForUnknownLanguage() {
        let spec = DialogSpec.closeApps(
            manifest: manifest(), request: request(canDefer: true, isFinal: false),
            languageCode: "de", timeZone: utc)
        XCTAssertEqual(spec.title, "Software update")
    }

    // MARK: - swiftDialog arguments

    func testArgumentsAlwaysPinTheDialogOnTop() {
        let arguments = DialogSpec(title: "T", message: "M", button1: "OK").arguments()
        XCTAssertTrue(arguments.contains("--ontop"),
                      "a dialog buried under a meeting is as good as no warning")
        XCTAssertTrue(arguments.contains("--moveable"))
        XCTAssertFalse(arguments.contains("--blurscreen"))
    }

    func testBlockingDialogIsNotMoveableAndBlursScreen() {
        let arguments = DialogSpec(
            title: "T", message: "M", button1: "OK",
            timerSeconds: 60, isBlocking: true).arguments()
        XCTAssertTrue(arguments.contains("--blurscreen"))
        XCTAssertFalse(arguments.contains("--moveable"))
        XCTAssertTrue(arguments.contains("--timer"))
        XCTAssertTrue(arguments.contains("60"))
    }

    func testOptionalArgumentsAreOmittedWhenUnset() {
        let arguments = DialogSpec(title: "T", message: "M", button1: "OK").arguments()
        XCTAssertFalse(arguments.contains("--button2text"))
        XCTAssertFalse(arguments.contains("--icon"))
        XCTAssertFalse(arguments.contains("--timer"))
    }

    /// A persistence timer must not read as a deadline: its bar is hidden, otherwise
    /// the user sees a countdown reach zero and then the window reopen without
    /// anything happening.
    func testPersistenceTimerHidesItsBar() {
        let spec = DialogSpec(title: "T", message: "M", button1: "OK",
                              persistIntervalSeconds: 20, maxTotalSeconds: 120)
        let arguments = spec.arguments(timerOverride: 20)

        XCTAssertTrue(arguments.contains("--timer"))
        XCTAssertTrue(arguments.contains("--hidetimerbar"))
    }

    /// The counterpart: a final warning shows its timer, which is the time actually
    /// remaining before close.
    func testFinalWarningShowsItsTimerBar() {
        let spec = DialogSpec(title: "T", message: "M", button1: "OK",
                              timerSeconds: 60, isBlocking: true)
        let arguments = spec.arguments()

        XCTAssertTrue(arguments.contains("--timer"))
        XCTAssertFalse(arguments.contains("--hidetimerbar"))
    }

    // MARK: - Progress dialog

    /// Equivalent of `Show-ADTInstallationProgress`. With no actionable button and
    /// no timer: it lives as long as the operation runs, and it is the agent that
    /// closes it.
    func testProgressDialogHasNoActionableControl() {
        let spec = DialogSpec.progress(manifest: manifest(), languageCode: "fr")
        let arguments = spec.arguments()

        XCTAssertTrue(spec.isIndeterminateProgress)
        XCTAssertTrue(arguments.contains("--progress"))
        XCTAssertTrue(arguments.contains("--button1disabled"))
        XCTAssertFalse(arguments.contains("--timer"),
                       "a timer would close the dialog before the install finishes")
        XCTAssertFalse(arguments.contains("--button2text"))
        XCTAssertFalse(arguments.contains("--blurscreen"))
    }

    func testProgressDialogUsesProgressTitle() {
        let spec = DialogSpec.progress(manifest: manifest(), languageCode: "fr")
        XCTAssertEqual(spec.message, "Installation de Slack en cours")
    }

    /// A timer passed as an override must not come back to life on a progress
    /// dialog: the persistence loop does not apply to it.
    func testProgressIgnoresTimerOverride() {
        let spec = DialogSpec.progress(manifest: manifest(), languageCode: "fr")
        XCTAssertFalse(spec.arguments(timerOverride: 60).contains("--timer"))
    }

    // MARK: - Completion message

    /// Equivalent of `Show-ADTInstallationPrompt` with `-NoWait`. Launched
    /// detached, nobody will close it: it therefore carries its own timer.
    func testCompletionDialogSelfDismisses() {
        let spec = DialogSpec.completion(manifest: manifest(), languageCode: "fr")

        XCTAssertEqual(spec.timerSeconds, 20)
        XCTAssertNil(spec.button2)
        XCTAssertFalse(spec.isBlocking)
        XCTAssertTrue(spec.message.contains("Slack"))
        XCTAssertTrue(spec.message.contains("4.36.140"))
    }

    // MARK: - Partial text override

    /// Without lenient decoding, any manifest overriding a language would have to
    /// provide all eight texts, and adding a ninth would retroactively break every
    /// manifest in the fleet.
    func testPartialLanguageOverrideKeepsFallbacks() throws {
        let manifest = try Manifest.decode(Data("""
        {
          "packageKey": "x",
          "displayName": "Outil",
          "messages": { "strings": { "fr": { "title": "Deploiement Galeax" } } }
        }
        """.utf8))
        let strings = manifest.messages.resolve(for: "fr")

        XCTAssertEqual(strings.title, "Deploiement Galeax")
        XCTAssertFalse(strings.closeAppsBody.isEmpty, "non-overridden texts must survive")
        XCTAssertFalse(strings.completionBody.isEmpty)
        XCTAssertFalse(strings.progressTitle.isEmpty)
    }

    func testBuiltInLanguagesDeclareEveryText() {
        for (code, strings) in Messages.builtIn {
            XCTAssertFalse(strings.completionBody.isEmpty, "completionBody missing for \(code)")
            XCTAssertFalse(strings.progressTitle.isEmpty, "progressTitle missing for \(code)")
            XCTAssertFalse(strings.restartBody.isEmpty, "restartBody missing for \(code)")
        }
    }

    // MARK: - Exit codes

    func testOutcomeMapping() {
        XCTAssertEqual(DialogOutcome.from(exitCode: 0), .primary)
        XCTAssertEqual(DialogOutcome.from(exitCode: 2), .secondary)
        XCTAssertEqual(DialogOutcome.from(exitCode: 4), .timerExpired)
        XCTAssertEqual(DialogOutcome.from(exitCode: 5), .userQuit)
        XCTAssertEqual(DialogOutcome.from(exitCode: 10), .userQuit)
        XCTAssertEqual(DialogOutcome.from(exitCode: 137), .unknown)
    }
}
