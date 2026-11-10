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

    /// Label shown under the countdown bar, with a `{remaining}` token the helper
    /// re-renders every second. `nil` falls back to the bare time left.
    public var countdownText: String?

    /// Command file of a progress dialog whose bar the agent advances. With it the
    /// bar is a real 0–100 % gauge; without it, swiftDialog's indeterminate
    /// animation — which is drawn grey on grey whenever the window is not the active
    /// one, i.e. always during an installation, and reads as no bar at all.
    public var progressCommandFile: String?

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
        isIndeterminateProgress: Bool = false,
        countdownText: String? = nil,
        progressCommandFile: String? = nil
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
        self.countdownText = countdownText
        self.progressCommandFile = progressCommandFile
    }

    /// Text under the countdown bar for a given time left: "45 s" under a minute,
    /// "4:05" above.
    public func countdownLabel(remaining: Int) -> String {
        let seconds = max(0, remaining)
        let time = seconds < 60
            ? "\(seconds) s"
            : "\(seconds / 60):" + (seconds % 60 < 10 ? "0" : "") + "\(seconds % 60)"
        guard let countdownText else { return time }
        return Template.render(countdownText, values: ["remaining": time])
    }

    /// Height of a non-blocking dialog. swiftDialog does not fit its window to the
    /// content: left alone it opens far too tall, and too small a value pushes the
    /// buttons out of view. So the height is derived from what is actually shown —
    /// measured on the test Mac at 520 pt wide: 260 pt holds a two-line message, the
    /// countdown bar and the buttons.
    var compactHeight: Int {
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false).count
        let base = timerSeconds != nil ? 260 : 215
        return min(480, base + 16 * max(0, lines - 1))
    }

    /// Arguments for the swiftDialog binary.
    ///
    /// `--ontop` was once systematic, so a deployment dialog would not stay buried
    /// under a video-call window. It had to be removed: on macOS 26 (swiftDialog
    /// launched through the agent's `launchctl asuser` + `sudo -u` bridge), `--ontop`
    /// makes swiftDialog run with NO visible window and ignore its own `--timer`, so
    /// the process never returns and the helper kills it at the timeout — a dialog
    /// that never shows. Burial is the lesser evil, and the persistence re-show
    /// already brings an ignored dialog back to the front. Revisit if a swiftDialog
    /// release fixes `--ontop` in that context.
    ///
    /// - Parameter timerOverride: timer for this iteration, computed by `DialogLoop`.
    ///   Differs from `timerSeconds` on a persistent dialog, where each presentation
    ///   lasts only one interval.
    /// - Parameter commandFile: swiftDialog command file the caller will drive. When
    ///   given, the countdown is NOT swiftDialog's own `--timer` — whose bar is
    ///   hard-wired beside the buttons, and which never expires once its bar is
    ///   hidden (both read in swiftDialog 3.1.1's source and confirmed on the Mac).
    ///   It is a `--progress` bar instead, drawn full-width above the buttons, which
    ///   the caller advances and then closes with `quit:` — see `DialogRunner`.
    ///   Without it (detached dialogs nobody drives) the native timer is kept.
    public func arguments(timerOverride: Int? = nil, commandFile: String? = nil) -> [String] {
        var arguments = [
            "--title", title,
            "--message", message,
            "--button1text", button1,
            // Smaller type: swiftDialog's default reads oversized for a deployment
            // prompt.
            "--messagefont", "size=13",
            "--titlefont", "size=18",
        ]

        // A progress dialog has neither an actionable button nor a timer: it lives as
        // long as the operation lasts, and it is the agent that closes it.
        // **To be validated by the spike**, like the exit codes: these options are
        // not part of a contract published by swiftDialog.
        if isIndeterminateProgress {
            // A tile in the bottom-right corner, same width as the gate dialog. No
            // `--small`: it scales `--width`/`--height` by 0.75 as well, which is what
            // squeezed the earlier attempts. 250 pt, not less: title (50) + icon row
            // (~85) + bar (20) + button row (~40) + paddings do not fit in 200, and
            // SwiftUI then drops the bar — the window showed with no progress at all.
            if let progressCommandFile {
                arguments += ["--progress", "100", "--progresstext", "0 %",
                              "--commandfile", progressCommandFile]
            } else {
                arguments.append("--progress")
            }
            arguments += ["--button1disabled", "--moveable",
                          "--position", "bottomright", "--width", "520", "--height", "250",
                          // The only dialog that asks nothing of the user: let them
                          // send it to the Dock while the installation runs. It is
                          // closed by the agent at the end either way.
                          "--windowbuttons", "min"]
            if let iconPath { arguments += ["--icon", iconPath, "--iconsize", "64"] }
            else { arguments += ["--icon", "none"] }
            return arguments
        }

        if let button2 { arguments += ["--button2text", button2] }
        if let iconPath {
            // swiftDialog's default icon is 150 pt and inflates the window; 64 pt
            // is the standard macOS alert size and sits right in a 520 pt card.
            arguments += ["--icon", iconPath, "--iconsize", "64"]
        } else {
            // No icon configured: suppress swiftDialog's large default placeholder,
            // which otherwise inflates the dialog's height out of all proportion to
            // its width.
            arguments += ["--icon", "none"]
        }
        if let timer = timerOverride ?? timerSeconds {
            if commandFile != nil {
                // Caller-driven countdown: a full-width bar above the buttons. A
                // persistence interval (no `timerSeconds`) is not a deadline, so it
                // shows nothing at all — the caller just closes and re-shows.
                if timerSeconds != nil {
                    arguments += ["--progress", String(timer),
                                  "--progresstext", countdownLabel(remaining: timer)]
                }
            } else {
                arguments += ["--timer", String(timer)]
                if timerSeconds == nil { arguments.append("--hidetimerbar") }
            }
        }
        if let commandFile { arguments += ["--commandfile", commandFile] }
        if isBlocking {
            // The final warning monopolizes the screen on purpose: centered, blurred,
            // not dodgeable.
            arguments += ["--position", "center", "--blurscreen", "--quitkey", "x"]
        } else {
            // Every other dialog is a compact card in the bottom-right corner, sized
            // to its content (see `compactHeight`).
            arguments += ["--position", "bottomright", "--width", "520",
                          "--height", String(compactHeight), "--moveable"]
        }
        if blursScreen && !isBlocking { arguments.append("--blurscreen") }
        return arguments
    }

    /// Options that carry no value. Everything else in `arguments()` is a
    /// `--key value` pair.
    private static let booleanOptions: Set<String> = [
        "button1disabled", "moveable", "blurscreen", "hidetimerbar",
    ]

    /// What is actually handed to swiftDialog: the same options as `arguments()`,
    /// as ONE `--jsonstring` argument.
    ///
    /// Not a matter of taste. On swiftDialog 3.1.1 / macOS 26, the same options given
    /// as separate arguments make the process hang before it creates its window,
    /// depending on their ORDER — `--progress` ahead of `--position` or `--width`
    /// is enough. That is why the installation-progress window never showed, and the
    /// centred final warning would not have either. Measured on the test Mac with a
    /// window-list probe: every failing order shows once passed as JSON, where there
    /// is no order.
    public func launchArguments(timerOverride: Int? = nil, commandFile: String? = nil) -> [String] {
        let options = arguments(timerOverride: timerOverride, commandFile: commandFile)
        var configuration: [String: Any] = [:]
        var index = 0
        while index < options.count {
            let key = String(options[index].dropFirst(2))
            let next = index + 1 < options.count ? options[index + 1] : nil
            // `--progress` alone is the indeterminate bar; followed by a number it is
            // the countdown.
            let isFlag = DialogSpec.booleanOptions.contains(key)
                || (key == "progress" && (next == nil || Int(next!) == nil))
            if isFlag || next == nil {
                configuration[key] = true
                index += 1
            } else {
                configuration[key] = next
                index += 2
            }
        }
        guard let data = try? JSONSerialization.data(
                withJSONObject: configuration, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return options
        }
        return ["--jsonstring", json]
    }

    /// Progress dialog shown while the payload is installed.
    public static func progress(
        manifest: Manifest,
        languageCode: String,
        iconPath: String? = nil,
        commandFile: String? = nil
    ) -> DialogSpec {
        let strings = manifest.messages.resolve(for: languageCode)
        let values = ["name": manifest.displayName, "version": manifest.version]
        return DialogSpec(
            title: Template.render(strings.title, values: values),
            message: Template.render(strings.progressTitle, values: values),
            button1: "",
            iconPath: iconPath ?? manifest.icon,
            isIndeterminateProgress: true,
            progressCommandFile: commandFile)
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
            iconPath: iconPath ?? manifest.icon,
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

        // With no application to close (the "show when not running" notice), the
        // close/final-warning copy — which lists `{apps}` — would be empty and
        // misleading, so a dedicated install-notice body is used instead.
        let body: String
        if request.apps.isEmpty {
            body = strings.installNoticeBody
        } else {
            body = request.isFinalWarning ? strings.finalWarningBody : strings.closeAppsBody
        }

        return DialogSpec(
            title: Template.render(strings.title, values: values),
            message: Template.render(body, values: values),
            button1: Template.render(strings.closeButton, values: values),
            button2: request.canDefer
                ? Template.render(strings.deferButton, values: values)
                : nil,
            iconPath: iconPath ?? manifest.icon,
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
            // timer makes re-display pointless. (It used to also lean on `--ontop` to
            // keep the window in front; that flag is gone — see `arguments()` — so a
            // bounded dialog simply relies on its timer.)
            persistIntervalSeconds: request.closesOnTimeout
                ? nil
                : request.persistIntervalSeconds,
            maxTotalSeconds: request.closesOnTimeout
                ? request.countdownSeconds
                : request.maxDialogSeconds,
            isBlocking: request.isFinalWarning,
            countdownText: strings.countdownText)
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
