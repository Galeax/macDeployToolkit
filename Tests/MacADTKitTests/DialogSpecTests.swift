import XCTest
@testable import MacADTKit

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
                       "01/09/2026 à 18:00")
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
        XCTAssertEqual(values["deadline"], "01/09/2026 à 18:00")
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
        XCTAssertTrue(spec.message.contains("immédiatement"),
                      "the final warning must use finalWarningBody")
    }

    /// The "show when not running" notice: no application to close, so the body is
    /// the install notice (no closing language, no `{apps}` list) and a single
    /// button whose countdown proceeds with the install.
    func testInstallNoticeWhenNoAppToClose() {
        let notice = PromptRequest(
            apps: [], canDefer: false, deferralsRemaining: 0,
            deadline: nil, countdownSeconds: 600, persistIntervalSeconds: nil,
            maxDialogSeconds: 1_200, isFinalWarning: false, closesOnTimeout: true)
        let spec = DialogSpec.closeApps(
            manifest: manifest(), request: notice, languageCode: "fr", timeZone: utc)

        XCTAssertNil(spec.button2, "a notice offers no deferral")
        XCTAssertEqual(spec.timerSeconds, 600, "its countdown proceeds with the install")
        XCTAssertTrue(spec.message.contains("va être installé"),
                      "the notice must use installNoticeBody")
        XCTAssertFalse(spec.message.contains("fermeture"),
                       "no closing language when there is nothing to close")
        XCTAssertFalse(spec.message.contains("- Slack"),
                       "no app list in an install notice")
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

    /// `--ontop` was removed: on macOS 26, through the agent's launchctl bridge, it
    /// makes swiftDialog run with no visible window and ignore its timer. The dialog
    /// must therefore NOT carry it, or no deployment dialog ever shows.
    func testArgumentsDoNotPinOnTop() {
        let arguments = DialogSpec(title: "T", message: "M", button1: "OK").arguments()
        XCTAssertFalse(arguments.contains("--ontop"),
                       "--ontop breaks swiftDialog display via launchctl asuser on macOS 26")
        XCTAssertTrue(arguments.contains("--moveable"))
        XCTAssertFalse(arguments.contains("--blurscreen"))
    }

    /// A non-blocking dialog is a compact card in the bottom-right corner, with an
    /// explicit size. Never `--small`: it also scales `--width`/`--height` by 0.75,
    /// which truncated the buttons.
    func testNonBlockingDialogIsCompactBottomRight() {
        let arguments = DialogSpec(title: "T", message: "M", button1: "OK").arguments()
        XCTAssertTrue(arguments.contains("--position"))
        XCTAssertTrue(arguments.contains("bottomright"))
        XCTAssertTrue(arguments.contains("--width"))
        XCTAssertTrue(arguments.contains("--height"))
        XCTAssertFalse(arguments.contains("--small"))
        XCTAssertTrue(arguments.contains("--messagefont"))
        XCTAssertTrue(arguments.contains("--titlefont"))
        // No icon configured → swiftDialog's oversized default is suppressed.
        XCTAssertTrue(arguments.contains("none"), "the default icon is suppressed")
    }

    /// A manifest `icon` flows through to swiftDialog's `--icon`, capped in size, and
    /// takes the place of the suppressed default.
    func testManifestIconFlowsToSwiftDialog() {
        let withIcon = Manifest(
            packageKey: "slack", displayName: "Slack", version: "1",
            icon: "/Applications/Slack.app")
        let arguments = DialogSpec.closeApps(
            manifest: withIcon, request: request(canDefer: false, isFinal: false),
            languageCode: "fr", timeZone: utc).arguments()
        XCTAssertTrue(arguments.contains("--icon"))
        XCTAssertTrue(arguments.contains("/Applications/Slack.app"))
        XCTAssertTrue(arguments.contains("--iconsize"))
        XCTAssertFalse(arguments.contains("none"), "a configured icon replaces the suppression")
    }

    func testBlockingDialogIsCenteredNotMoveableAndBlursScreen() {
        let arguments = DialogSpec(
            title: "T", message: "M", button1: "OK",
            timerSeconds: 60, isBlocking: true).arguments()
        XCTAssertTrue(arguments.contains("--blurscreen"))
        XCTAssertTrue(arguments.contains("center"), "the final warning stays centered")
        XCTAssertFalse(arguments.contains("bottomright"))
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

    // MARK: - Caller-driven countdown

    /// With a command file, the countdown is a `--progress` bar (drawn above the
    /// buttons) that the helper advances — not swiftDialog's `--timer`, whose bar is
    /// hard-wired beside the buttons.
    func testDrivenCountdownIsAProgressBarAboveTheButtons() {
        let spec = DialogSpec(title: "T", message: "M", button1: "OK", timerSeconds: 60,
                              countdownText: "Démarrage automatique dans {remaining}")
        let arguments = spec.arguments(commandFile: "/tmp/x.cmd")

        XCTAssertFalse(arguments.contains("--timer"))
        XCTAssertEqual(arguments.firstIndex(of: "--progress").map { arguments[$0 + 1] }, "60")
        XCTAssertTrue(arguments.contains("Démarrage automatique dans 1:00"))
        XCTAssertEqual(arguments.firstIndex(of: "--commandfile").map { arguments[$0 + 1] }, "/tmp/x.cmd")
    }

    /// A persistence interval is not a deadline: driven mode shows no bar at all, and
    /// never relies on `--timer --hidetimerbar`, which does not expire in swiftDialog.
    func testDrivenPersistenceShowsNoBar() {
        let spec = DialogSpec(title: "T", message: "M", button1: "OK",
                              persistIntervalSeconds: 20, maxTotalSeconds: 120)
        let arguments = spec.arguments(timerOverride: 20, commandFile: "/tmp/x.cmd")

        XCTAssertFalse(arguments.contains("--timer"))
        XCTAssertFalse(arguments.contains("--hidetimerbar"))
        XCTAssertFalse(arguments.contains("--progress"))
        XCTAssertTrue(arguments.contains("--commandfile"))
    }

    func testCountdownLabelFormatsTimeLeft() {
        let spec = DialogSpec(title: "T", message: "M", button1: "OK",
                              countdownText: "Dans {remaining}")
        XCTAssertEqual(spec.countdownLabel(remaining: 45), "Dans 45 s")
        XCTAssertEqual(spec.countdownLabel(remaining: 245), "Dans 4:05")
        XCTAssertEqual(spec.countdownLabel(remaining: -3), "Dans 0 s")
        XCTAssertEqual(DialogSpec(title: "T", message: "M", button1: "OK").countdownLabel(remaining: 9), "9 s")
    }

    /// The window is sized to its content: a longer message gets a taller card.
    func testCompactHeightGrowsWithTheMessage() {
        let short = DialogSpec(title: "T", message: "one line", button1: "OK", timerSeconds: 60)
        let long = DialogSpec(title: "T", message: "a\n\n- b\n\nc", button1: "OK", timerSeconds: 60)
        XCTAssertLessThan(short.compactHeight, long.compactHeight)
        XCTAssertLessThanOrEqual(long.compactHeight, 480)
    }

    // MARK: - Launch arguments

    private func launchConfiguration(_ arguments: [String]) throws -> [String: Any] {
        XCTAssertEqual(arguments.count, 2)
        XCTAssertEqual(arguments.first, "--jsonstring")
        let object = try JSONSerialization.jsonObject(with: Data(arguments[1].utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    /// swiftDialog hangs without a window on some argument ORDERS, so everything goes
    /// through a single `--jsonstring`.
    func testLaunchArgumentsAreASingleJSONString() throws {
        let spec = DialogSpec(title: "Mise à jour", message: "**A** va être installé.",
                              button1: "OK", button2: "Reporter", iconPath: "SF=arrow.down.circle",
                              timerSeconds: 60)
        let configuration = try launchConfiguration(spec.launchArguments(commandFile: "/tmp/x.cmd"))

        XCTAssertEqual(configuration["title"] as? String, "Mise à jour")
        XCTAssertEqual(configuration["message"] as? String, "**A** va être installé.")
        XCTAssertEqual(configuration["button2text"] as? String, "Reporter")
        XCTAssertEqual(configuration["progress"] as? String, "60")
        XCTAssertEqual(configuration["commandfile"] as? String, "/tmp/x.cmd")
        XCTAssertEqual(configuration["position"] as? String, "bottomright")
        XCTAssertEqual(configuration["moveable"] as? Bool, true)
    }

    func testIndeterminateProgressIsABooleanInJSON() throws {
        let spec = DialogSpec.progress(manifest: manifest(), languageCode: "fr")
        let configuration = try launchConfiguration(spec.launchArguments())

        XCTAssertEqual(configuration["progress"] as? Bool, true)
        XCTAssertEqual(configuration["button1disabled"] as? Bool, true)
        XCTAssertEqual(configuration["button1text"] as? String, "")
        XCTAssertEqual(configuration["width"] as? String, "520")
        XCTAssertEqual(configuration["windowbuttons"] as? String, "min",
                       "the progress window can be minimised")
    }

    /// With a command file the progress window carries a real 0–100 gauge the agent
    /// advances, instead of the indeterminate animation.
    func testProgressDialogWithCommandFileIsDeterminate() throws {
        let spec = DialogSpec.progress(
            manifest: manifest(), languageCode: "fr", commandFile: "/tmp/p.cmd")
        let configuration = try launchConfiguration(spec.launchArguments())

        XCTAssertEqual(configuration["progress"] as? String, "100")
        XCTAssertEqual(configuration["progresstext"] as? String, "0 %")
        XCTAssertEqual(configuration["commandfile"] as? String, "/tmp/p.cmd")
        XCTAssertNil(configuration["timer"])
    }

    func testBlockingDialogKeepsItsFlagsInJSON() throws {
        let spec = DialogSpec(title: "T", message: "M", button1: "OK",
                              timerSeconds: 60, isBlocking: true)
        let configuration = try launchConfiguration(spec.launchArguments(commandFile: "/tmp/x.cmd"))

        XCTAssertEqual(configuration["blurscreen"] as? Bool, true)
        XCTAssertEqual(configuration["quitkey"] as? String, "x")
        XCTAssertEqual(configuration["position"] as? String, "center")
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
        XCTAssertTrue(arguments.contains("bottomright"), "the progress tile sits bottom-right")
        XCTAssertFalse(arguments.contains("--small"))
        XCTAssertTrue(arguments.contains("--width"), "a pinned width keeps the tile from stretching")
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
          "messages": { "strings": { "fr": { "title": "Déploiement Galeax" } } }
        }
        """.utf8))
        let strings = manifest.messages.resolve(for: "fr")

        XCTAssertEqual(strings.title, "Déploiement Galeax")
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
