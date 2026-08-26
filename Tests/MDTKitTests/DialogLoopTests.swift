import XCTest
@testable import MDTKit

/// Persistent presentation loop (PSADT `-PersistPrompt`).
///
/// swiftDialog has no persistent mode: re-showing an ignored dialog requires
/// relaunching it. Without this loop, a dialog that slipped behind a meeting window
/// is never seen, and the forced close that follows looks like it arrives without
/// warning — that is the scenario that destroys trust in the tool.
final class DialogLoopTests: XCTestCase {

    private func deferrable(persist: Int? = 60, total: Int? = 1_200) -> DialogSpec {
        DialogSpec(
            title: "T", message: "M", button1: "Fermer", button2: "Reporter",
            timerSeconds: nil, persistIntervalSeconds: persist, maxTotalSeconds: total)
    }

    private func finalWarning(countdown: Int = 300) -> DialogSpec {
        DialogSpec(
            title: "T", message: "M", button1: "Fermer",
            timerSeconds: countdown, persistIntervalSeconds: nil,
            maxTotalSeconds: countdown, isBlocking: true)
    }

    // MARK: - Deferrable dialog

    func testDeferrableDialogRepresentsAtEachInterval() {
        let spec = deferrable(persist: 60, total: 300)
        XCTAssertEqual(DialogLoop.next(spec: spec, elapsedSeconds: 0), .present(timerSeconds: 60))
        XCTAssertEqual(DialogLoop.next(spec: spec, elapsedSeconds: 60), .present(timerSeconds: 60))
        XCTAssertEqual(DialogLoop.next(spec: spec, elapsedSeconds: 180), .present(timerSeconds: 60))
    }

    /// The last iteration is shortened so as not to exceed the budget: otherwise the
    /// dialog would outlive the Intune agent's timeout, which would kill it without
    /// any usable outcome.
    func testLastIterationIsClippedToRemainingBudget() {
        let spec = deferrable(persist: 60, total: 300)
        XCTAssertEqual(DialogLoop.next(spec: spec, elapsedSeconds: 280), .present(timerSeconds: 20))
    }

    func testBudgetExhaustionStopsRepresenting() {
        let spec = deferrable(persist: 60, total: 300)
        XCTAssertEqual(DialogLoop.next(spec: spec, elapsedSeconds: 300), .exhausted)
        XCTAssertEqual(DialogLoop.next(spec: spec, elapsedSeconds: 999), .exhausted)
    }

    /// Persistence disabled: a single presentation, then nothing more.
    func testWithoutPersistenceThereIsASinglePresentation() {
        let spec = deferrable(persist: nil, total: 1_200)
        XCTAssertEqual(DialogLoop.next(spec: spec, elapsedSeconds: 0), .present(timerSeconds: 1_200))
        XCTAssertEqual(DialogLoop.next(spec: spec, elapsedSeconds: 1), .exhausted)
    }

    func testUnboundedBudgetUsesPersistIntervalIndefinitely() {
        let spec = deferrable(persist: 60, total: nil)
        XCTAssertEqual(DialogLoop.next(spec: spec, elapsedSeconds: 0), .present(timerSeconds: 60))
        XCTAssertEqual(DialogLoop.next(spec: spec, elapsedSeconds: 100_000), .present(timerSeconds: 60))
    }

    // MARK: - Final warning

    /// A final warning shows the time actually remaining, never the persistence
    /// interval: a timer that reset itself would make the user believe they still
    /// have time.
    func testFinalWarningShowsRealRemainingTime() {
        let spec = finalWarning(countdown: 300)
        XCTAssertEqual(DialogLoop.next(spec: spec, elapsedSeconds: 0), .present(timerSeconds: 300))
        XCTAssertEqual(DialogLoop.next(spec: spec, elapsedSeconds: 120), .present(timerSeconds: 180))
        XCTAssertEqual(DialogLoop.next(spec: spec, elapsedSeconds: 300), .exhausted)
    }

    // MARK: - Interpreting timer expiry

    /// On a final warning, the expiry IS the response: implicit consent to the close.
    func testTimerExpiryOnFinalWarningIsConsent() {
        XCTAssertEqual(
            DialogLoop.outcomeForTimerExpiry(spec: finalWarning(), elapsedSeconds: 300),
            .timerExpired)
    }

    /// On a deferrable dialog, the expiry is only a re-presentation.
    func testTimerExpiryOnDeferrableDialogMeansRepresent() {
        XCTAssertNil(
            DialogLoop.outcomeForTimerExpiry(spec: deferrable(total: 300), elapsedSeconds: 60),
            "there is budget left: the dialog must come back to the foreground")
    }

    /// Budget exhausted with no response: `.abandoned`, distinct from `.timerExpired`.
    /// Nobody consented to anything, so the agent will consume a deferral rather than
    /// close the applications.
    func testExhaustedDeferrableDialogIsAbandonedNotConsent() {
        XCTAssertEqual(
            DialogLoop.outcomeForTimerExpiry(spec: deferrable(total: 300), elapsedSeconds: 300),
            .abandoned)
    }

    // MARK: - Construction from the engine

    private let slack = BlockingAppSpec(
        bundleIdentifier: "com.tinyspeck.slackmacgap", displayName: "Slack")

    private func spec(isFinal: Bool, canDefer: Bool) -> DialogSpec {
        let manifest = Manifest(packageKey: "slack", displayName: "Slack", version: "1.0")
        let request = PromptRequest(
            apps: [slack], canDefer: canDefer, deferralsRemaining: canDefer ? 2 : 0,
            deadline: nil, countdownSeconds: 300,
            persistIntervalSeconds: 60, maxDialogSeconds: 1_200,
            isFinalWarning: isFinal)
        return DialogSpec.closeApps(
            manifest: manifest, request: request,
            languageCode: "fr", timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    func testDeferrableSpecCarriesPersistenceNotCountdown() {
        let dialog = spec(isFinal: false, canDefer: true)
        XCTAssertNil(dialog.timerSeconds)
        XCTAssertEqual(dialog.persistIntervalSeconds, 60)
        XCTAssertEqual(dialog.maxTotalSeconds, 1_200)
        XCTAssertFalse(dialog.isBlocking)
    }

    /// Persistence does not apply to the final warning: it is already blocking and
    /// the screen is blurred, it cannot be ignored.
    func testFinalWarningSpecCarriesCountdownNotPersistence() {
        let dialog = spec(isFinal: true, canDefer: false)
        XCTAssertEqual(dialog.timerSeconds, 300)
        XCTAssertNil(dialog.persistIntervalSeconds)
        XCTAssertEqual(dialog.maxTotalSeconds, 300)
        XCTAssertTrue(dialog.isBlocking)
    }

    // MARK: - swiftDialog arguments

    /// Each relaunch must carry the timer of ITS iteration, not that of the spec.
    func testTimerOverrideWinsOverSpecTimer() {
        let arguments = finalWarning(countdown: 300).arguments(timerOverride: 180)
        let index = try? XCTUnwrap(arguments.firstIndex(of: "--timer"))
        XCTAssertEqual(arguments[(index ?? 0) + 1], "180")
    }

    func testDeferrableDialogGetsTimerOnlyFromOverride() {
        let dialog = deferrable(persist: 60, total: 1_200)
        XCTAssertFalse(dialog.arguments().contains("--timer"))
        XCTAssertTrue(dialog.arguments(timerOverride: 60).contains("--timer"))
    }
}
