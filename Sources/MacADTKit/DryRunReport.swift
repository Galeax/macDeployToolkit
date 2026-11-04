import Foundation

public enum MacAppDeployToolkit {
    public static let version = "0.1.0"
    public static let bundleIdentifier = "com.macadt.deploy"
}

extension DeploymentDecision {

    /// Stable label, for the logs and the `--dry-run` report.
    public var label: String {
        switch self {
        case .proceed:              return "proceed"
        case .prompt:               return "prompt"
        case .forceClose:           return "force_close"
        case .retryLater:           return "retry_later"
        case .requirementFailed:    return "requirement_failed"
        }
    }

    public var detail: String? {
        switch self {
        case .proceed:
            return nil
        case .prompt(let request):
            if request.isFinalWarning {
                return "final warning, countdown \(request.countdownSeconds) s"
            }
            let base = "deferral available, \(request.deferralsRemaining) remaining"
            return request.closesOnTimeout
                ? base + ", install after \(request.countdownSeconds) s without a response"
                : base
        case .forceClose(_, let trigger):
            return trigger.rawValue
        case .retryLater(let reason):
            return reason.rawValue
        case .requirementFailed(let reason):
            return reason
        }
    }

    /// Corresponding exit code, for the outcomes that require no further action.
    /// `nil` when the rest of the processing determines the code (a dialog to
    /// present, applications to close).
    public var immediateExitCode: ExitCode? {
        switch self {
        case .proceed:              return .success
        case .requirementFailed:    return .requirementNotMet
        case .retryLater(let reason): return reason.exitCode
        case .prompt, .forceClose:  return nil
        }
    }
}

/// `--dry-run` report.
///
/// The `--dry-run` mode is what makes a full scenario replayable without a Mac and
/// without root: it goes through the same evaluation, builds the same dialog and the
/// same uninstall plan, but runs nothing. It is also the output compared in the
/// scenario tests.
public struct DryRunReport: Codable, Equatable, Sendable {

    public var command: String
    public var packageKey: String
    public var displayName: String
    public var version: String

    public var decision: String
    public var detail: String?

    public var runningApps: [String]
    public var hasConsoleUser: Bool
    public var isScreenLocked: Bool
    public var isPresenting: Bool

    public var deferralsUsed: Int
    public var deferralsRemaining: Int
    public var deadline: Date?

    /// The dialog that would be shown, substituted texts included.
    public var dialog: DialogSpec?
    /// The plan that would be run, refusals and warnings included.
    public var uninstallPlan: UninstallPlan?

    public init(
        command: String,
        manifest: Manifest,
        context: DeploymentContext,
        state: DeploymentState,
        decision: DeploymentDecision,
        dialog: DialogSpec? = nil,
        uninstallPlan: UninstallPlan? = nil
    ) {
        self.command = command
        self.packageKey = manifest.packageKey
        self.displayName = manifest.displayName
        self.version = manifest.version
        self.decision = decision.label
        self.detail = decision.detail
        self.runningApps = context.runningBlockingApps.map(\.identifier)
        self.hasConsoleUser = context.hasConsoleUser
        self.isScreenLocked = context.isScreenLocked
        self.isPresenting = context.isPresenting
        self.deferralsUsed = state.deferralsUsed
        self.deferralsRemaining = max(0, manifest.deferral.maxDeferrals - state.deferralsUsed)
        self.deadline = manifest.deferral.deadline
        self.dialog = dialog
        self.uninstallPlan = uninstallPlan
    }

    public func encodedJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    /// Human-readable rendering for someone tuning a manifest.
    public func describe() -> String {
        // Each fragment is computed before the array literal: concatenating ternaries
        // directly inside it makes the compiler's type inference explode.
        let decisionDetail: String = detail.map { " — \($0)" } ?? ""
        let appsSummary: String = runningApps.isEmpty
            ? "none"
            : runningApps.joined(separator: ", ")
        var sessionSummary: String = hasConsoleUser ? "console user" : "none"
        if isScreenLocked { sessionSummary += ", screen locked" }
        if isPresenting { sessionSummary += ", presenting" }

        var lines: [String] = [
            "command     : \(command)",
            "package     : \(displayName) \(version) (\(packageKey))",
            "decision    : \(decision)\(decisionDetail)",
            "open apps   : \(appsSummary)",
            "session     : \(sessionSummary)",
            "deferrals   : \(deferralsUsed) used, \(deferralsRemaining) remaining",
        ]
        if let dialog {
            lines.append("dialog      : \(dialog.title)")
            lines.append("  button 1  : \(dialog.button1)")
            lines.append("  button 2  : \(dialog.button2 ?? "(none)")")
            lines.append("  timer     : \(dialog.timerSeconds.map { "\($0) s" } ?? "(none)")")
            lines.append("  message   :")
            for line in dialog.message.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("    \(line)")
            }
        }
        if let uninstallPlan {
            let counts = "\(uninstallPlan.deletions.count) deletions, "
                + "\(uninstallPlan.prunedCount) pruned, \(uninstallPlan.rejections.count) refusals"
            lines.append("plan        : \(counts)")
            for path in uninstallPlan.deletions { lines.append("  - \(path)") }
            for rejection in uninstallPlan.rejections {
                lines.append("  ! \(rejection.path) (\(rejection.reason.rawValue))")
            }
            for warning in uninstallPlan.warnings { lines.append("  ⚠ \(warning)") }
        }
        return lines.joined(separator: "\n")
    }
}
