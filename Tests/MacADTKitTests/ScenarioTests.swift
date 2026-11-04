import XCTest
@testable import MacADTKit

/// End-to-end scenarios: several consecutive Intune passes over the same
/// deployment, with state that persists between runs.
///
/// Unit tests verify each rule in isolation; these verify that the sequence tells
/// the right story. This is the level at which design bugs show up — a counter that
/// does not advance, a deadline that recedes, a user we never disturb or disturb
/// endlessly.
final class ScenarioTests: XCTestCase {

    private let engine = DeferralEngine()

    private let slack = BlockingAppSpec(
        bundleIdentifier: "com.tinyspeck.slackmacgap", displayName: "Slack")

    /// Simulates one agent pass. Returns the decision and the resulting state,
    /// applying the state transition matching the user's choice.
    private func checkIn(
        manifest: Manifest,
        state: DeploymentState,
        context: DeploymentContext,
        at now: Date,
        userChoice: DialogOutcome? = nil
    ) -> (decision: DeploymentDecision, state: DeploymentState) {

        let decision = engine.evaluate(
            manifest: manifest, state: state, context: context, now: now)

        guard case .prompt = decision else { return (decision, state) }

        var updated = engine.markPrompted(state, now: now)
        if userChoice == .secondary {
            updated = engine.recordDeferral(state, now: now)
        }
        return (decision, updated)
    }

    private func manifest(
        maxDeferrals: Int = 3,
        deferralDays: Int? = nil,
        deadline: Date? = nil
    ) -> Manifest {
        Manifest(
            packageKey: "slack-2026q3",
            displayName: "Slack",
            version: "4.36.140",
            blockingApps: [slack],
            deferral: DeferralPolicy(
                maxDeferrals: maxDeferrals,
                deferralDays: deferralDays,
                deadline: deadline,
                countdownSeconds: 600))
    }

    private let day0 = Date(timeIntervalSince1970: 1_770_000_000)
    private func day(_ offset: Int) -> Date {
        day0.addingTimeInterval(Double(offset) * 86_400)
    }

    private var slackOpen: DeploymentContext {
        DeploymentContext(runningBlockingApps: [slack])
    }

    // MARK: - Scenario 1: the user defers until exhausted

    func testUserDefersUntilExhausted() {
        let manifest = manifest(maxDeferrals: 3)
        var state = DeploymentState(packageKey: manifest.packageKey)

        for round in 0..<3 {
            let (decision, updated) = checkIn(
                manifest: manifest, state: state, context: slackOpen,
                at: day(round), userChoice: .secondary)
            state = updated

            guard case .prompt(let request) = decision else {
                return XCTFail("run \(round): expected a dialog, got \(decision)")
            }
            XCTAssertTrue(request.canDefer, "run \(round) must still allow deferral")
            XCTAssertEqual(request.deferralsRemaining, 3 - round)
            XCTAssertFalse(request.isFinalWarning)
        }

        XCTAssertEqual(state.deferralsUsed, 3)

        // Fourth pass: no deferral left, final warning with countdown.
        let (final, _) = checkIn(
            manifest: manifest, state: state, context: slackOpen, at: day(3))
        guard case .prompt(let request) = final else {
            return XCTFail("expected a final dialog, got \(final)")
        }
        XCTAssertFalse(request.canDefer)
        XCTAssertTrue(request.isFinalWarning)
        XCTAssertEqual(request.countdownSeconds, 600)

        // The built dialog must reflect that: a single button, blocking.
        let dialog = DialogSpec.closeApps(
            manifest: manifest, request: request,
            languageCode: "fr", timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertNil(dialog.button2)
        XCTAssertTrue(dialog.isBlocking)
        XCTAssertEqual(dialog.timerSeconds, 600)
    }

    // MARK: - Scenario 2: the user closes Slack on their own

    /// Closing spontaneously must cost nothing: the deferral counter does not move,
    /// and the next pass installs without showing anything.
    func testUserClosesAppHimselfCostsNoDeferral() {
        let manifest = manifest()
        var state = DeploymentState(packageKey: manifest.packageKey)

        let (first, updated) = checkIn(
            manifest: manifest, state: state, context: slackOpen,
            at: day(0), userChoice: .primary)
        state = updated
        guard case .prompt = first else { return XCTFail("expected a dialog") }
        XCTAssertEqual(state.deferralsUsed, 0, "agreeing to close does not consume a deferral")
        XCTAssertEqual(state.firstPromptDate, day(0), "the window starts regardless")

        let (second, _) = checkIn(
            manifest: manifest, state: state,
            context: DeploymentContext(runningBlockingApps: []), at: day(0))
        XCTAssertEqual(second, .proceed)
    }

    // MARK: - Scenario 3: the 7-day sliding window

    /// The deadline must not recede on each deferral, otherwise a sufficiently
    /// persistent user never receives the update.
    func testSlidingWindowIsAnchoredToFirstPrompt() {
        let manifest = manifest(maxDeferrals: 99, deferralDays: 7)
        var state = DeploymentState(packageKey: manifest.packageKey)

        // One deferral a day for six days: the window stays open.
        for offset in 0..<6 {
            let (decision, updated) = checkIn(
                manifest: manifest, state: state, context: slackOpen,
                at: day(offset), userChoice: .secondary)
            state = updated
            guard case .prompt(let request) = decision else {
                return XCTFail("day \(offset): expected a dialog")
            }
            XCTAssertTrue(request.canDefer, "day \(offset): the window must stay open")
        }
        XCTAssertEqual(state.firstPromptDate, day(0),
                       "the window anchor must never move")

        // Day 8: the window is closed, despite the 93 deferrals remaining.
        let (final, _) = checkIn(
            manifest: manifest, state: state, context: slackOpen, at: day(8))
        guard case .prompt(let request) = final else {
            return XCTFail("expected a final dialog")
        }
        XCTAssertFalse(request.canDefer,
                       "the time window must take precedence over the deferral counter")
        XCTAssertTrue(request.isFinalWarning)
    }

    // MARK: - Scenario 4: back-to-back meetings then deadline

    /// A user in a meeting is never disturbed — until the deadline, where courtesy
    /// gives way. Otherwise a device in a permanent meeting would never be updated.
    func testMeetingsPostponeUntilDeadlineThenYield() {
        let deadline = day(5)
        let manifest = manifest(maxDeferrals: 3, deadline: deadline)
        let state = DeploymentState(packageKey: manifest.packageKey)
        let inMeeting = DeploymentContext(runningBlockingApps: [slack], isPresenting: true)

        for offset in 0..<5 {
            let (decision, _) = checkIn(
                manifest: manifest, state: state, context: inMeeting, at: day(offset))
            XCTAssertEqual(decision, .retryLater(.userPresenting),
                           "day \(offset): do not disturb before the deadline")
        }

        let (afterDeadline, _) = checkIn(
            manifest: manifest, state: state, context: inMeeting, at: day(6))
        guard case .prompt(let request) = afterDeadline else {
            return XCTFail("after the deadline we must disturb, got \(afterDeadline)")
        }
        XCTAssertTrue(request.isFinalWarning)
    }

    // MARK: - Scenario 5: device left on overnight, nobody logged in

    func testUnattendedMachineWaitsThenClosesWithoutAsking() {
        let manifest = manifest(maxDeferrals: 2)
        var state = DeploymentState(packageKey: manifest.packageKey)
        let unattended = DeploymentContext(
            runningBlockingApps: [slack], hasConsoleUser: false)

        // Window still open: we wait, we close nothing.
        let (first, _) = checkIn(
            manifest: manifest, state: state, context: unattended, at: day(0))
        XCTAssertEqual(first, .retryLater(.noConsoleUser))

        // The user uses up their deferrals during the day.
        state.deferralsUsed = 2

        // The following night, window exhausted and nobody logged in: this is the
        // least destructive moment to close.
        let (second, _) = checkIn(
            manifest: manifest, state: state, context: unattended, at: day(1))
        XCTAssertEqual(second, .forceClose(apps: [slack], trigger: .deferralsExhausted))
    }

    // MARK: - Scenario 6: locked screen

    /// Locked screen = user away, but with documents open. We do not close while
    /// there is still slack left.
    func testLockedScreenIsRespectedWhileWindowIsOpen() {
        let manifest = manifest()
        let state = DeploymentState(packageKey: manifest.packageKey)
        let locked = DeploymentContext(runningBlockingApps: [slack], isScreenLocked: true)

        let (decision, _) = checkIn(
            manifest: manifest, state: state, context: locked, at: day(0))
        XCTAssertEqual(decision, .retryLater(.screenLocked))
    }

    // MARK: - Scenario 7: missing requirement, never any disturbance

    func testMissingDiskSpaceNeverBothersTheUser() {
        var manifest = manifest()
        manifest.requirements = Requirements(minimumFreeBytes: 10_000_000_000)
        let state = DeploymentState(packageKey: manifest.packageKey)
        let context = DeploymentContext(
            runningBlockingApps: [slack], freeBytes: 500_000_000)

        let (decision, updated) = checkIn(
            manifest: manifest, state: state, context: context, at: day(0))
        guard case .requirementFailed = decision else {
            return XCTFail("expected .requirementFailed, got \(decision)")
        }
        XCTAssertNil(updated.firstPromptDate,
                     "no dialog was presented, the window must not start")
    }

    // MARK: - Scenario 8: full uninstall versus repair

    /// The only difference between the two commands: `repair` honors the
    /// `preservedPaths`, `uninstall` ignores them.
    func testRepairPreservesConfigurationWhereUninstallDoesNot() {
        let planner = UninstallPlanner()
        let spec = UninstallSpec(
            paths: [
                "/Applications/Slack.app",
                "/Users/romain/Library/Application Support/Slack",
            ],
            preservedPaths: ["/Users/romain/Library/Application Support/Slack"])

        let repair = planner.plan(spec: spec)
        XCTAssertEqual(repair.deletions, ["/Applications/Slack.app"])
        XCTAssertTrue(repair.rejections.contains { $0.reason == .preserved })

        var fullSpec = spec
        fullSpec.preservedPaths = []
        let uninstall = planner.plan(spec: fullSpec)
        XCTAssertEqual(uninstall.deletions, [
            "/Applications/Slack.app",
            "/Users/romain/Library/Application Support/Slack",
        ])
    }

    // MARK: - Scenario 9: the window between `pre` and `install`

    /// The wrapper model: Intune drops the payload BETWEEN the pre-install and the
    /// post-install. The user may reopen their browser during those few seconds. We
    /// must then neither kill it without warning, nor ask again a question they have
    /// just answered.
    func testFreshConsentSurvivesThePayloadDropWindow() {
        var state = DeploymentState(packageKey: "chrome")
        XCTAssertFalse(engine.hasFreshConsent(state, now: day0),
                       "without consent, nothing allows a silent close")

        // `pre`: the user agrees to close.
        state = engine.recordConsent(state, now: day0)
        XCTAssertEqual(state.consentGrantedAt, day0)
        XCTAssertEqual(state.deferralsUsed, 0, "agreeing is not deferring")

        // `install`, 40 seconds later: the consent holds.
        XCTAssertTrue(engine.hasFreshConsent(state, now: day0.addingTimeInterval(40)))

        // The next day, however, we must ask again.
        XCTAssertFalse(engine.hasFreshConsent(state, now: day(1)))
    }

    func testConsentWindowBoundary() {
        var state = DeploymentState(packageKey: "chrome")
        state = engine.recordConsent(state, now: day0)

        XCTAssertTrue(engine.hasFreshConsent(state, now: day0.addingTimeInterval(900)))
        XCTAssertFalse(engine.hasFreshConsent(state, now: day0.addingTimeInterval(901)))
    }

    /// A consent dated in the future signals a clock that moved backward — NTP
    /// time sync, wake from sleep. We refuse rather than grant a window that would
    /// never close again.
    func testConsentInTheFutureIsRefused() {
        var state = DeploymentState(packageKey: "chrome")
        state = engine.recordConsent(state, now: day(1))
        XCTAssertFalse(engine.hasFreshConsent(state, now: day0))
    }

    func testConsentSurvivesRoundTripThroughTheStore() throws {
        let store = InMemoryStateStore()
        var state = store.load(packageKey: "chrome")
        state = engine.recordConsent(state, now: day0)
        try store.save(state)

        XCTAssertTrue(engine.hasFreshConsent(
            store.load(packageKey: "chrome"), now: day0.addingTimeInterval(60)))
    }

    // MARK: - Dry-run report

    func testDryRunReportCapturesTheWholeDecision() {
        let manifest = manifest(maxDeferrals: 3, deadline: day(5))
        var state = DeploymentState(packageKey: manifest.packageKey)
        state.deferralsUsed = 1

        let decision = engine.evaluate(
            manifest: manifest, state: state, context: slackOpen, at: day(0))
        guard case .prompt(let request) = decision else { return XCTFail("expected a dialog") }

        let report = DryRunReport(
            command: "pre", manifest: manifest, context: slackOpen,
            state: state, decision: decision,
            dialog: DialogSpec.closeApps(
                manifest: manifest, request: request,
                languageCode: "fr", timeZone: TimeZone(secondsFromGMT: 0)!))

        XCTAssertEqual(report.decision, "prompt")
        XCTAssertEqual(report.deferralsUsed, 1)
        XCTAssertEqual(report.deferralsRemaining, 2)
        XCTAssertEqual(report.runningApps, ["com.tinyspeck.slackmacgap"])
        XCTAssertEqual(report.deadline, day(5))

        // The report must stay readable by a human and by a machine.
        XCTAssertTrue(report.describe().contains("Slack"))
        XCTAssertTrue(report.describe().contains("2 remaining"))
        XCTAssertTrue(report.encodedJSON().contains("\"decision\" : \"prompt\""))
    }

    func testDecisionLabelsAreStable() {
        XCTAssertEqual(DeploymentDecision.proceed.label, "proceed")
        XCTAssertEqual(DeploymentDecision.retryLater(.screenLocked).label, "retry_later")
        XCTAssertEqual(DeploymentDecision.retryLater(.screenLocked).detail, "screenLocked")
        XCTAssertEqual(DeploymentDecision.proceed.immediateExitCode, .success)
        XCTAssertEqual(
            DeploymentDecision.retryLater(.userPresenting).immediateExitCode,
            .blockedUserPresenting)
        XCTAssertNil(DeploymentDecision.forceClose(apps: [], trigger: .deadlineReached)
            .immediateExitCode)
    }
}

private extension DeferralEngine {
    /// Sugar for scenario readability.
    func evaluate(
        manifest: Manifest,
        state: DeploymentState,
        context: DeploymentContext,
        at now: Date
    ) -> DeploymentDecision {
        evaluate(manifest: manifest, state: state, context: context, now: now)
    }
}
