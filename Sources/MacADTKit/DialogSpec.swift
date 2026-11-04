import Foundation

/// Description of a dialog, independent of the tool that displays it.
///
/// The indirection is not free: swiftDialog is the right choice today (notarized by
/// its author, handles Notification Center, markdown, dark mode and
/// accessibility), but it is an external dependency. This structure is the point
/// where we could switch to an in-house `.app` without touching the deployment
/// logic.
public struct DialogSpec: Codable, Equatable, Sendable {

    public var title: String
    public var message: String
    public var button1: String
    public var button2: String?
    public var iconPath: String?

    /// **Visible** countdown. Its presence signals a final warning: expiry counts as
    /// consent to the close.
    public var timerSeconds: Int?

    /// Interval at which an ignored dialog is shown again (PSADT `-PersistPrompt`).
    ///
    /// Without it, a dialog pushed behind a video-call window is never seen, and the
    /// forced close that follows seems to arrive without warning. swiftDialog has no
    /// persistent mode: it is the helper that relaunches it in a loop, driven by
    /// `DialogLoop`.
    public var persistIntervalSeconds: Int?

    /// Total presentation budget. Past this time without a response, the outcome is
    /// `.abandoned`. `nil` = unlimited (to avoid: the Intune agent would kill the
    /// script).
    public var maxTotalSeconds: Int?

    /// Prevents closing via the close box or Cmd-Q. Used for the final warning: the
    /// user must choose, not dodge.
    public var isBlocking: Bool

    /// Blurs the background. Reserved for the final warning — it is the only moment
    /// where monopolizing the screen is justified.
    public var blursScreen: Bool

    /// Progress dialog, without a button, shown during a long operation and closed by
    /// the agent when it finishes.
    ///
    /// Equivalent of `Show-ADTInstallationProgress`. Only possible in the wrapper
    /// model: when Intune installs the pkg itself, the installation happens between
    /// `pre` and `post` and none of our processes runs during it.
    public var isIndeterminateProgress: Bool

    public init(
        title: String,
        message: String,
        button1: String,
        button2: String? = nil,
        iconPath: String? = nil,
        timerSeconds: Int? = nil,
        persistIntervalSeconds: Int? = nil,
        maxTotalSeconds: Int? = nil,
        isBlocking: Bool = false,
        blursScreen: Bool = false,
        isIndeterminateProgress: Bool = false
    ) {
        self.title = title
        self.message = message
        self.button1 = button1
        self.button2 = button2
        self.iconPath = iconPath
        self.timerSeconds = timerSeconds
        self.persistIntervalSeconds = persistIntervalSeconds
        self.maxTotalSeconds = maxTotalSeconds
        self.isBlocking = isBlocking
        self.blursScreen = blursScreen
        self.isIndeterminateProgress = isIndeterminateProgress
    }

    /// Arguments for the swiftDialog binary.
    ///
    /// `--ontop` is systematic: a deployment dialog buried under a video-call window
    /// is useless, and the user concludes that the forced close arrived without
    /// warning.
    ///
    /// - Parameter timerOverride: timer for this iteration, computed by `DialogLoop`.
    ///   Differs from `timerSeconds` on a persistent dialog, where each presentation
    ///   lasts only one interval.
    public func arguments(timerOverride: Int? = nil) -> [String] {
        var arguments = [
            "--title", title,
            "--message", message,
            "--button1text", button1,
            "--ontop",
            "--position", "center",
        ]

        // A progress dialog has neither an actionable button nor a timer: it lives as
        // long as the operation lasts, and it is the agent that closes it.
        // **To be validated by the spike**, like the exit codes: these options are
        // not part of a contract published by swiftDialog.
        if isIndeterminateProgress {
            arguments += ["--progress", "--button1disabled", "--small", "--moveable"]
            if let iconPath { arguments += ["--icon", iconPath] }
            return arguments
        }

        if let button2 { arguments += ["--button2text", button2] }
        if let iconPath { arguments += ["--icon", iconPath] }
        if let timer = timerOverride ?? timerSeconds {
            arguments += ["--timer", String(timer)]
            // A persistence timer is not a deadline: it only serves to return control
            // so the dialog can be shown again. Showing its bar would make a close
            // countdown read where there is none, and the user sees the window reopen
            // without anything happening — the exact symptom reported on macOS 26.
            // Only a final warning, which carries `timerSeconds`, shows its timer.
            if timerSeconds == nil { arguments.append("--hidetimerbar") }
        }
        if isBlocking { arguments += ["--blurscreen", "--quitkey", "x"] }
        else { arguments += ["--moveable"] }
        if blursScreen && !isBlocking { arguments.append("--blurscreen") }
        return arguments
    }

    /// Progress dialog shown while the payload is installed.
    public static func progress(
        manifest: Manifest,
        languageCode: String,
        iconPath: String? = nil
    ) -> DialogSpec {
        let strings = manifest.messages.resolve(for: languageCode)
        let values = ["name": manifest.displayName, "version": manifest.version]
        return DialogSpec(
            title: Template.render(strings.title, values: values),
            message: Template.render(strings.progressTitle, values: values),
            button1: "",
            iconPath: iconPath,
            isIndeterminateProgress: true)
    }

    /// Installation completion message, the equivalent of PSADT's
    /// `Show-ADTInstallationPrompt` in `-NoWait`.
    ///
    /// Carries a timer: launched detached, no one will close it, and a confirmation
    /// dialog that stays on screen until the next restart is a nuisance, not
    /// information.
    public static func completion(
        manifest: Manifest,
        languageCode: String,
        secondsOnScreen: Int = 20,
        iconPath: String? = nil
    ) -> DialogSpec {
        let strings = manifest.messages.resolve(for: languageCode)
        let values = ["name": manifest.displayName, "version": manifest.version]
        return DialogSpec(
            title: Template.render(strings.title, values: values),
            message: Template.render(strings.completionBody, values: values),
            button1: "OK",
            iconPath: iconPath,
            timerSeconds: secondsOnScreen,
            maxTotalSeconds: secondsOnScreen)
    }

    /// Builds the "close these applications" dialog from the manifest and the
    /// engine's decision. A pure function: this is what lets us verify the texts, the
    /// presence of the deferral button, the countdown and the persistence without
    /// launching any UI.
    public static func closeApps(
        manifest: Manifest,
        request: PromptRequest,
        languageCode: String,
        timeZone: TimeZone,
        iconPath: String? = nil
    ) -> DialogSpec {
        let strings = manifest.messages.resolve(for: languageCode)
        let values = Template.values(
            manifest: manifest, request: request,
            languageCode: languageCode, timeZone: timeZone)

        let body = request.isFinalWarning ? strings.finalWarningBody : strings.closeAppsBody

        return DialogSpec(
            title: Template.render(strings.title, values: values),
            message: Template.render(body, values: values),
            button1: Template.render(strings.closeButton, values: values),
            button2: request.canDefer
                ? Template.render(strings.deferButton, values: values)
                : nil,
            iconPath: iconPath,
            // A countdown on any dialog whose expiry triggers the installation —
            // including when a deferral remains possible. Without it, a dialog left
            // open would suspend the deployment indefinitely: the gate advanced only
            // after `maxDialogSeconds`, and only to consume a deferral.
            //
            // The trade-off is accepted: a device with no one in front of it loses
            // unsaved work at the end of the countdown, as of the first pass. The
            // deferral mechanism now only protects the user present to click.
            timerSeconds: request.closesOnTimeout ? request.countdownSeconds : nil,
            // Persistence only remains where no countdown bounds the dialog: a visible
            // timer makes re-display pointless, and `--ontop` is enough to keep it in
            // front.
            persistIntervalSeconds: request.closesOnTimeout
                ? nil
                : request.persistIntervalSeconds,
            maxTotalSeconds: request.closesOnTimeout
                ? request.countdownSeconds
                : request.maxDialogSeconds,
            isBlocking: request.isFinalWarning)
    }
}

/// Outcome of a dialog, mapped from swiftDialog's exit code.
public enum DialogOutcome: String, Codable, Equatable, Sendable {

    /// Button 1: "close and install".
    case primary
    /// Button 2: "defer".
    case secondary
    /// Countdown of an expired final warning — to be treated as an implicit consent
    /// to the close, which is the whole point of the warning.
    case timerExpired
    /// The user escaped the dialog (close box, Cmd-Q).
    case userQuit
    /// Presentation budget exhausted without a response, despite the re-displays.
    /// Distinct from `timerExpired`: no one consented to anything.
    case abandoned
    case unknown

    /// swiftDialog exit codes. **To be validated by the spike**: they have been
    /// stable for several versions but are not part of a published contract.
    public static func from(exitCode: Int32) -> DialogOutcome {
        switch exitCode {
        case 0:     return .primary
        case 2:     return .secondary
        case 4:     return .timerExpired
        case 5, 10: return .userQuit
        default:    return .unknown
        }
    }
}

public enum DialogIteration: Equatable, Sendable {
    /// Launch swiftDialog with this timer (`nil` = no timer).
    case present(timerSeconds: Int?)
    /// Budget exhausted: show no more.
    case exhausted
}

/// Drives the presentation loop of a persistent dialog.
///
/// swiftDialog has no persistent mode: to re-display an ignored dialog, it must be
/// relaunched. This loop is pure computation, so testable, whereas its execution is
/// not.
public enum DialogLoop {

    public static func next(spec: DialogSpec, elapsedSeconds: Int) -> DialogIteration {
        var remaining: Int?
        if let total = spec.maxTotalSeconds {
            let left = total - elapsedSeconds
            if left <= 0 { return .exhausted }
            remaining = left
        }

        // Dialog with a visible countdown: we show the time actually remaining, never
        // the persistence interval. A timer that reset would make the user believe
        // they have time left.
        if spec.timerSeconds != nil { return .present(timerSeconds: remaining) }

        guard let interval = spec.persistIntervalSeconds else {
            // Without persistence: a single presentation, bounded by the budget.
            return elapsedSeconds == 0 ? .present(timerSeconds: remaining) : .exhausted
        }
        return .present(timerSeconds: min(interval, remaining ?? interval))
    }

    /// How to interpret a swiftDialog timer expiry (code 4).
    ///
    /// - Returns: the outcome to report, or `nil` if the dialog must be shown again.
    public static func outcomeForTimerExpiry(spec: DialogSpec, elapsedSeconds: Int) -> DialogOutcome? {
        // On a final warning, the expiry IS the response.
        if spec.timerSeconds != nil { return .timerExpired }
        // On a deferrable dialog, it is only a re-display — unless the budget is
        // exhausted.
        if case .exhausted = next(spec: spec, elapsedSeconds: elapsedSeconds) { return .abandoned }
        return nil
    }
}
