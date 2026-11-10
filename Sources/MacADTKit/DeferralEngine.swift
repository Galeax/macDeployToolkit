import Foundation

/// What the agent observes of the device at decision time.
///
/// Deliberately a plain bag of data, with no Apple API whatsoever: this is what
/// makes the decision engine unit-testable in isolation, whereas its collection
/// (SCDynamicStore, libproc, IOKit) is not.
public struct DeploymentContext: Equatable, Sendable {

    /// Subset of `manifest.blockingApps` actually running, as observed by the
    /// process scan.
    public var runningBlockingApps: [BlockingAppSpec]

    /// A user is logged in at the console (not loginwindow, uid >= 501).
    public var hasConsoleUser: Bool

    public var isScreenLocked: Bool

    /// A `PreventUserIdleDisplaySleep` PM assertion is active: a video call or a
    /// full-screen presentation is in progress.
    public var isPresenting: Bool

    public var freeBytes: Int64?
    public var osVersion: String?

    public init(
        runningBlockingApps: [BlockingAppSpec] = [],
        hasConsoleUser: Bool = true,
        isScreenLocked: Bool = false,
        isPresenting: Bool = false,
        freeBytes: Int64? = nil,
        osVersion: String? = nil
    ) {
        self.runningBlockingApps = runningBlockingApps
        self.hasConsoleUser = hasConsoleUser
        self.isScreenLocked = isScreenLocked
        self.isPresenting = isPresenting
        self.freeBytes = freeBytes
        self.osVersion = osVersion
    }
}

public enum RetryReason: String, Equatable, Sendable {
    case noConsoleUser
    case screenLocked
    case userPresenting
    case silentModeBlocked

    public var exitCode: ExitCode {
        switch self {
        case .noConsoleUser:    return .blockedNoConsoleUser
        case .screenLocked:     return .blockedScreenLocked
        case .userPresenting:   return .blockedUserPresenting
        case .silentModeBlocked:return .blockedSilentMode
        }
    }
}

/// Why the deferral window is considered exhausted.
public enum ExhaustionTrigger: String, Equatable, Sendable {
    case deferralDisabled
    case deadlineReached
    case deferralWindowElapsed
    case deferralsExhausted
}

public struct PromptRequest: Equatable, Sendable {
    public var apps: [BlockingAppSpec]
    public var canDefer: Bool
    public var deferralsRemaining: Int
    public var deadline: Date?

    /// Applicable countdown, already resolved by action: 300 s on install, 60 s on
    /// uninstall and repair.
    public var countdownSeconds: Int

    /// Interval at which an ignored dialog is shown again. `nil` = no persistence.
    public var persistIntervalSeconds: Int?

    /// Maximum lifetime of a deferrable dialog, before `.abandoned`.
    public var maxDialogSeconds: Int

    /// `true` when the user has no deferral left and policy allows a forced close:
    /// the dialog becomes a final warning with a countdown, no longer a request.
    public var isFinalWarning: Bool

    /// Does the dialog's expiry trigger the installation?
    ///
    /// True as soon as policy allows a forced close, including when deferrals remain
    /// available: the dialog then carries its countdown, and the absence of a
    /// response counts as acceptance. Without this, a dialog left open would suspend
    /// the deployment indefinitely, a deferral being consumed only after
    /// `maxDialogSeconds`.
    ///
    /// False when `forceCloseWhenExhausted` is disabled: the operator has explicitly
    /// forbidden any non-consented close, and an expiry must not reintroduce it
    /// through the back door.
    public var closesOnTimeout: Bool

    public init(
        apps: [BlockingAppSpec],
        canDefer: Bool,
        deferralsRemaining: Int,
        deadline: Date?,
        countdownSeconds: Int,
        persistIntervalSeconds: Int? = nil,
        maxDialogSeconds: Int = 1_200,
        isFinalWarning: Bool,
        closesOnTimeout: Bool = false
    ) {
        self.apps = apps
        self.canDefer = canDefer
        self.deferralsRemaining = deferralsRemaining
        self.deadline = deadline
        self.countdownSeconds = countdownSeconds
        self.persistIntervalSeconds = persistIntervalSeconds
        self.maxDialogSeconds = maxDialogSeconds
        self.isFinalWarning = isFinalWarning
        self.closesOnTimeout = closesOnTimeout
    }
}

public enum DeploymentDecision: Equatable, Sendable {
    /// Nothing blocks: install now.
    case proceed
    /// Show a dialog and act according to the response.
    case prompt(PromptRequest)
    /// Close by force without a dialog. Only happens when there is no one to warn,
    /// or in explicit silent mode.
    case forceClose(apps: [BlockingAppSpec], trigger: ExhaustionTrigger)
    /// Do nothing, exit with a transient code, let Intune retry.
    case retryLater(RetryReason)
    /// Requirement not met: the state of the device must change first.
    case requirementFailed(String)
}

/// Decision engine. Stateless, side-effect free, entirely deterministic: `now` is
/// injected rather than read, which makes the deferral windows testable without
/// waiting.
public struct DeferralEngine: Sendable {

    public init() {}

    public func evaluate(
        manifest: Manifest,
        state: DeploymentState,
        context: DeploymentContext,
        now: Date
    ) -> DeploymentDecision {

        // 1. Hard requirements first. No point disturbing the user for a deployment
        //    that will fail anyway.
        if let required = manifest.requirements.minimumFreeBytes,
           let available = context.freeBytes,
           available < required {
            return .requirementFailed(
                "insufficient disk space: \(available) bytes available, \(required) required")
        }
        if let minimum = manifest.requirements.minimumOSVersion,
           let current = context.osVersion,
           BundleVersion(current) < BundleVersion(minimum) {
            return .requirementFailed("macOS \(current) present, \(minimum) required at minimum")
        }

        // 2. Nothing running.
        let blocking = context.runningBlockingApps
        if blocking.isEmpty {
            // Install straight away, unless the deployment wants its interactive gate
            // shown anyway and someone is there to see it. When it does, fall through
            // and treat it as a normal interactive prompt — same deferral, countdown
            // and exhaustion rules — only with no application to close (the dialog then
            // uses the install-notice body). Non-interactive modes carry no gate, and a
            // headless device has no one to prompt: both just proceed.
            guard manifest.showDialogWhenNotRunning,
                  manifest.mode == .interactive,
                  context.hasConsoleUser else {
                return .proceed
            }
        }

        let policy = manifest.deferral
        let trigger = exhaustionTrigger(policy: policy, state: state, now: now)
        let isExhausted = trigger != nil

        switch manifest.mode {
        case .silent, .nonInteractive:
            // No gate dialog: there is no one to consult, and a deferral would make
            // no sense since no one can request it. Both modes therefore close by
            // force as soon as policy allows — `nonInteractive` showing progress and
            // the completion message, `silent` showing nothing. Visibility separates
            // them, not power: `DeploymentMode.presentsNotifications` decides.
            if let trigger, policy.forceCloseWhenExhausted {
                return .forceClose(apps: blocking, trigger: trigger)
            }
            return .retryLater(.silentModeBlocked)

        case .interactive:
            guard context.hasConsoleUser else {
                // No one to respond. If the window is exhausted, this is the least
                // destructive moment to close: no active session to interrupt.
                if let trigger, policy.forceCloseWhenExhausted {
                    return .forceClose(apps: blocking, trigger: trigger)
                }
                return .retryLater(.noConsoleUser)
            }

            // Do not disturb — but only while there is slack left. Once the deadline
            // has passed, courtesy yields.
            if !isExhausted {
                if manifest.requirements.respectScreenLock && context.isScreenLocked {
                    return .retryLater(.screenLocked)
                }
                if manifest.requirements.respectPresentationMode && context.isPresenting {
                    return .retryLater(.userPresenting)
                }
            }

            let remaining = max(0, policy.maxDeferrals - state.deferralsUsed)
            let canDefer = policy.allowDeferral && !isExhausted && remaining > 0

            // Even exhausted, we show a dialog rather than closing without warning:
            // this is PSADT's behavior, and the UX gap between "15-min countdown" and
            // "your Excel is gone" is the only one that matters for adoption.
            return .prompt(PromptRequest(
                apps: blocking,
                canDefer: canDefer,
                deferralsRemaining: remaining,
                deadline: policy.deadline,
                // The countdown depends on the action: 60 s on uninstall, where the
                // operation was explicitly requested and surprises no one, versus
                // 300 s on install.
                countdownSeconds: policy.countdown(for: manifest.action),
                persistIntervalSeconds: policy.persistPromptSeconds,
                maxDialogSeconds: policy.maxDialogSeconds,
                isFinalWarning: !canDefer && policy.forceCloseWhenExhausted,
                closesOnTimeout: policy.forceCloseWhenExhausted
            ))
        }
    }

    /// Is the deferral window exhausted, and why?
    /// The evaluation order fixes the reason reported when several conditions are
    /// true: from the most constraining to the most lenient.
    private func exhaustionTrigger(
        policy: DeferralPolicy,
        state: DeploymentState,
        now: Date
    ) -> ExhaustionTrigger? {
        if !policy.allowDeferral { return .deferralDisabled }
        if let deadline = policy.deadline, now >= deadline { return .deadlineReached }
        if let days = policy.deferralDays, let first = state.firstPromptDate {
            // Seconds and not calendar days: deterministic, insensitive to time zone
            // and DST. Sufficient for a deployment window.
            if now >= first.addingTimeInterval(Double(days) * 86_400) {
                return .deferralWindowElapsed
            }
        }
        if state.deferralsUsed >= policy.maxDeferrals { return .deferralsExhausted }
        return nil
    }

    /// Records that a dialog was presented. Called whatever the user's choice: the
    /// `deferralDays` window starts at the first solicitation, not at the first
    /// refusal.
    public func markPrompted(_ state: DeploymentState, now: Date) -> DeploymentState {
        var updated = state
        if updated.firstPromptDate == nil { updated.firstPromptDate = now }
        updated.lastPromptDate = now
        return updated
    }

    /// Window during which a close consent stays valid.
    ///
    /// 15 minutes: well enough to cover Intune dropping the payload between `pre` and
    /// `install`, and short enough that an `install` triggered by hand several hours
    /// later asks for consent again.
    public static let consentWindow: TimeInterval = 900

    /// Records that the user agreed to close their applications.
    public func recordConsent(_ state: DeploymentState, now: Date) -> DeploymentState {
        var updated = markPrompted(state, now: now)
        updated.consentGrantedAt = now
        return updated
    }

    /// Is the consent still fresh?
    ///
    /// When it is, an application reopened in the meantime can be closed again
    /// without re-prompting: the user just agreed, asking them again would be
    /// harassment, and killing it without a word a betrayal.
    public func hasFreshConsent(
        _ state: DeploymentState,
        now: Date,
        window: TimeInterval = DeferralEngine.consentWindow
    ) -> Bool {
        guard let granted = state.consentGrantedAt else { return false }
        // A consent date in the future signals a clock that went backwards: we
        // refuse rather than grant an endless window.
        guard granted <= now else { return false }
        return now.timeIntervalSince(granted) <= window
    }

    /// Consumes a deferral.
    public func recordDeferral(_ state: DeploymentState, now: Date) -> DeploymentState {
        var updated = markPrompted(state, now: now)
        updated.deferralsUsed += 1
        updated.lastOutcome = ExitCode.deferredByUser.slug
        updated.lastRunDate = now
        return updated
    }
}
