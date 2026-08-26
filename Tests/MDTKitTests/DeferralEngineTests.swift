import XCTest
@testable import MDTKit

/// Covers the full decision matrix. This is the suite that matters: each case here
/// corresponds to a situation where getting it wrong means either disturbing a user
/// in a meeting, or never installing a security patch.
final class DeferralEngineTests: XCTestCase {

    private let engine = DeferralEngine()
    private let now = Date(timeIntervalSince1970: 1_770_000_000) // fixed reference point

    private let slack = BlockingAppSpec(
        bundleIdentifier: "com.tinyspeck.slackmacgap", displayName: "Slack")
    private let teams = BlockingAppSpec(
        bundleIdentifier: "com.microsoft.teams2", displayName: "Microsoft Teams")

    private func manifest(
        mode: DeploymentMode = .interactive,
        deferral: DeferralPolicy = DeferralPolicy(),
        requirements: Requirements = Requirements()
    ) -> Manifest {
        Manifest(
            packageKey: "slack",
            displayName: "Slack",
            version: "4.3.1",
            mode: mode,
            blockingApps: [slack, teams],
            deferral: deferral,
            requirements: requirements)
    }

    private func state(deferralsUsed: Int = 0, firstPrompt: Date? = nil) -> DeploymentState {
        var state = DeploymentState(packageKey: "slack")
        state.deferralsUsed = deferralsUsed
        state.firstPromptDate = firstPrompt
        return state
    }

    // MARK: - Nominal case

    func testProceedsWhenNothingIsRunning() {
        let decision = engine.evaluate(
            manifest: manifest(), state: state(),
            context: DeploymentContext(runningBlockingApps: []), now: now)
        XCTAssertEqual(decision, .proceed)
    }

    /// `closesOnTimeout` follows the policy, and nothing else: it is what decides
    /// whether the dialog's expiry installs or merely waits.
    func testClosesOnTimeoutMirrorsForceClosePolicy() {
        for allowed in [true, false] {
            let decision = engine.evaluate(
                manifest: manifest(deferral: DeferralPolicy(forceCloseWhenExhausted: allowed)),
                state: state(),
                context: DeploymentContext(runningBlockingApps: [slack]), now: now)

            guard case .prompt(let request) = decision else {
                return XCTFail("expected .prompt, got \(decision)")
            }
            XCTAssertTrue(request.canDefer, "a deferral stays available")
            XCTAssertEqual(request.closesOnTimeout, allowed)
        }
    }

    func testPromptsWithDeferralAvailable() {
        let decision = engine.evaluate(
            manifest: manifest(), state: state(),
            context: DeploymentContext(runningBlockingApps: [slack]), now: now)

        guard case .prompt(let request) = decision else {
            return XCTFail("expected .prompt, got \(decision)")
        }
        XCTAssertTrue(request.canDefer)
        XCTAssertEqual(request.deferralsRemaining, 3)
        XCTAssertFalse(request.isFinalWarning)
        XCTAssertEqual(request.apps, [slack])
    }

    // MARK: - Deferral window exhaustion

    func testFinalWarningWhenDeferralsExhausted() {
        let decision = engine.evaluate(
            manifest: manifest(), state: state(deferralsUsed: 3),
            context: DeploymentContext(runningBlockingApps: [slack]), now: now)

        guard case .prompt(let request) = decision else {
            return XCTFail("expected .prompt, got \(decision)")
        }
        XCTAssertFalse(request.canDefer)
        XCTAssertTrue(request.isFinalWarning)
        XCTAssertEqual(request.deferralsRemaining, 0)
    }

    func testFinalWarningWhenDeadlinePassed() {
        let policy = DeferralPolicy(deadline: now.addingTimeInterval(-60))
        let decision = engine.evaluate(
            manifest: manifest(deferral: policy), state: state(),
            context: DeploymentContext(runningBlockingApps: [slack]), now: now)

        guard case .prompt(let request) = decision else {
            return XCTFail("expected .prompt, got \(decision)")
        }
        XCTAssertFalse(request.canDefer, "the deadline must take precedence over the deferrals remaining")
        XCTAssertTrue(request.isFinalWarning)
    }

    func testDeferralWindowElapsedFromFirstPrompt() {
        let policy = DeferralPolicy(maxDeferrals: 99, deferralDays: 7)
        let firstPrompt = now.addingTimeInterval(-8 * 86_400)
        let decision = engine.evaluate(
            manifest: manifest(deferral: policy), state: state(firstPrompt: firstPrompt),
            context: DeploymentContext(runningBlockingApps: [slack]), now: now)

        guard case .prompt(let request) = decision else {
            return XCTFail("expected .prompt, got \(decision)")
        }
        XCTAssertFalse(request.canDefer)
    }

    func testDeferralWindowStillOpenInsideTheDelay() {
        let policy = DeferralPolicy(maxDeferrals: 99, deferralDays: 7)
        let firstPrompt = now.addingTimeInterval(-6 * 86_400)
        let decision = engine.evaluate(
            manifest: manifest(deferral: policy), state: state(firstPrompt: firstPrompt),
            context: DeploymentContext(runningBlockingApps: [slack]), now: now)

        guard case .prompt(let request) = decision else {
            return XCTFail("expected .prompt, got \(decision)")
        }
        XCTAssertTrue(request.canDefer)
    }

    func testDeferralDisabledGivesFinalWarningImmediately() {
        let policy = DeferralPolicy(allowDeferral: false)
        let decision = engine.evaluate(
            manifest: manifest(deferral: policy), state: state(),
            context: DeploymentContext(runningBlockingApps: [slack]), now: now)

        guard case .prompt(let request) = decision else {
            return XCTFail("expected .prompt, got \(decision)")
        }
        XCTAssertFalse(request.canDefer)
        XCTAssertTrue(request.isFinalWarning)
    }

    /// Policy exhausted but force-close forbidden: we always warn, but it is not a
    /// final warning — nothing will be killed.
    func testExhaustedWithoutForceCloseIsNotAFinalWarning() {
        let policy = DeferralPolicy(maxDeferrals: 0, forceCloseWhenExhausted: false)
        let decision = engine.evaluate(
            manifest: manifest(deferral: policy), state: state(),
            context: DeploymentContext(runningBlockingApps: [slack]), now: now)

        guard case .prompt(let request) = decision else {
            return XCTFail("expected .prompt, got \(decision)")
        }
        XCTAssertFalse(request.canDefer)
        XCTAssertFalse(request.isFinalWarning)
    }

    // MARK: - No session

    func testRetriesLaterWhenNoConsoleUserAndWindowStillOpen() {
        let decision = engine.evaluate(
            manifest: manifest(), state: state(),
            context: DeploymentContext(runningBlockingApps: [slack], hasConsoleUser: false),
            now: now)
        XCTAssertEqual(decision, .retryLater(.noConsoleUser))
    }

    /// Nobody logged in and window exhausted: this is the least destructive moment
    /// to close, no active session to interrupt.
    func testForceClosesWhenNoConsoleUserAndExhausted() {
        let decision = engine.evaluate(
            manifest: manifest(), state: state(deferralsUsed: 3),
            context: DeploymentContext(runningBlockingApps: [slack, teams], hasConsoleUser: false),
            now: now)
        XCTAssertEqual(decision, .forceClose(apps: [slack, teams], trigger: .deferralsExhausted))
    }

    // MARK: - Do not disturb

    func testRespectsPresentationMode() {
        let decision = engine.evaluate(
            manifest: manifest(), state: state(),
            context: DeploymentContext(runningBlockingApps: [slack], isPresenting: true),
            now: now)
        XCTAssertEqual(decision, .retryLater(.userPresenting))
    }

    func testRespectsScreenLock() {
        let decision = engine.evaluate(
            manifest: manifest(), state: state(),
            context: DeploymentContext(runningBlockingApps: [slack], isScreenLocked: true),
            now: now)
        XCTAssertEqual(decision, .retryLater(.screenLocked))
    }

    /// Courtesy gives way once the deadline has passed: otherwise a user running
    /// back-to-back meetings never receives the patch.
    func testPresentationModeYieldsOnceExhausted() {
        let decision = engine.evaluate(
            manifest: manifest(), state: state(deferralsUsed: 3),
            context: DeploymentContext(runningBlockingApps: [slack], isPresenting: true),
            now: now)
        guard case .prompt(let request) = decision else {
            return XCTFail("expected .prompt, got \(decision)")
        }
        XCTAssertTrue(request.isFinalWarning)
    }

    func testPresentationModeIgnoredWhenPolicyDisablesIt() {
        let requirements = Requirements(respectPresentationMode: false)
        let decision = engine.evaluate(
            manifest: manifest(requirements: requirements), state: state(),
            context: DeploymentContext(runningBlockingApps: [slack], isPresenting: true),
            now: now)
        guard case .prompt = decision else {
            return XCTFail("expected .prompt, got \(decision)")
        }
    }

    // MARK: - UI-less modes

    func testSilentModeForceClosesWhenExhausted() {
        let decision = engine.evaluate(
            manifest: manifest(mode: .silent), state: state(deferralsUsed: 3),
            context: DeploymentContext(runningBlockingApps: [slack]), now: now)
        XCTAssertEqual(decision, .forceClose(apps: [slack], trigger: .deferralsExhausted))
    }

    func testSilentModeRetriesWhileWindowIsOpen() {
        let decision = engine.evaluate(
            manifest: manifest(mode: .silent), state: state(),
            context: DeploymentContext(runningBlockingApps: [slack]), now: now)
        XCTAssertEqual(decision, .retryLater(.silentModeBlocked))
    }

    /// `nonInteractive` closes by authority like `silent`: it is the equivalent of
    /// PSADT's `-DeployMode NonInteractive`, which forces the install without leaving
    /// a choice while still showing the UI to the end. What separates the two modes
    /// is visibility, not power.
    func testNonInteractiveForceClosesLikeSilent() {
        for mode in [DeploymentMode.nonInteractive, .silent] {
            let decision = engine.evaluate(
                manifest: manifest(mode: mode), state: state(deferralsUsed: 99),
                context: DeploymentContext(runningBlockingApps: [slack]), now: now)
            XCTAssertEqual(decision, .forceClose(apps: [slack], trigger: .deferralsExhausted),
                           "mode \(mode.rawValue)")
        }
    }

    /// And visibility precisely: only `silent` shows nothing.
    func testOnlySilentSuppressesNotifications() {
        XCTAssertTrue(DeploymentMode.interactive.presentsNotifications)
        XCTAssertTrue(DeploymentMode.nonInteractive.presentsNotifications)
        XCTAssertFalse(DeploymentMode.silent.presentsNotifications)
    }

    /// A non-interactive mode does not close just anytime for all that: as long as
    /// the deferral window is open, it retries. This is what lets a silent
    /// deployment respect a `deadline` without anticipating it.
    func testNonInteractiveRetriesWhileWindowIsOpen() {
        let decision = engine.evaluate(
            manifest: manifest(mode: .nonInteractive), state: state(),
            context: DeploymentContext(runningBlockingApps: [slack]), now: now)
        XCTAssertEqual(decision, .retryLater(.silentModeBlocked))
    }

    // MARK: - Requirements

    func testRequirementFailureBeatsEverythingElse() {
        let requirements = Requirements(minimumFreeBytes: 5_000_000_000)
        let decision = engine.evaluate(
            manifest: manifest(requirements: requirements), state: state(),
            context: DeploymentContext(runningBlockingApps: [slack], freeBytes: 1_000_000_000),
            now: now)
        guard case .requirementFailed = decision else {
            return XCTFail("a missing requirement must never disturb the user, got \(decision)")
        }
    }

    func testRejectsTooOldOS() {
        let requirements = Requirements(minimumOSVersion: "14.0")
        let decision = engine.evaluate(
            manifest: manifest(requirements: requirements), state: state(),
            context: DeploymentContext(osVersion: "13.6.4"), now: now)
        guard case .requirementFailed = decision else {
            return XCTFail("expected .requirementFailed, got \(decision)")
        }
    }

    func testAcceptsSufficientOS() {
        let requirements = Requirements(minimumOSVersion: "14.0")
        let decision = engine.evaluate(
            manifest: manifest(requirements: requirements), state: state(),
            context: DeploymentContext(osVersion: "15.2"), now: now)
        XCTAssertEqual(decision, .proceed)
    }

    // MARK: - State transitions

    func testRecordDeferralConsumesOneAndStampsFirstPrompt() {
        let updated = engine.recordDeferral(state(), now: now)
        XCTAssertEqual(updated.deferralsUsed, 1)
        XCTAssertEqual(updated.firstPromptDate, now)
        XCTAssertEqual(updated.lastOutcome, ExitCode.deferredByUser.slug)
    }

    /// The `deferralDays` window must start at the first prompt and never move
    /// again, otherwise a user who defers indefinitely also pushes back their own
    /// deadline.
    func testFirstPromptDateIsStableAcrossPrompts() {
        let original = now.addingTimeInterval(-3 * 86_400)
        var current = state(firstPrompt: original)
        current = engine.markPrompted(current, now: now)
        XCTAssertEqual(current.firstPromptDate, original)
        XCTAssertEqual(current.lastPromptDate, now)
    }

    func testThreeDeferralsThenFinalWarning() {
        var current = state()
        for round in 1...3 {
            let decision = engine.evaluate(
                manifest: manifest(), state: current,
                context: DeploymentContext(runningBlockingApps: [slack]), now: now)
            guard case .prompt(let request) = decision else {
                return XCTFail("round \(round): expected .prompt, got \(decision)")
            }
            XCTAssertTrue(request.canDefer, "round \(round) must still allow deferral")
            current = engine.recordDeferral(current, now: now)
        }
        let final = engine.evaluate(
            manifest: manifest(), state: current,
            context: DeploymentContext(runningBlockingApps: [slack]), now: now)
        guard case .prompt(let request) = final else {
            return XCTFail("expected final .prompt, got \(final)")
        }
        XCTAssertFalse(request.canDefer)
        XCTAssertTrue(request.isFinalWarning)
    }
}
