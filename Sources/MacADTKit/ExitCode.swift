import Foundation

/// Exit-code contract of the binary.
///
/// Two consumers, with opposite needs:
///
///  - **Intune** only distinguishes 0 / non-zero. A pre-install script returning
///    non-zero moves the app to `failed` in the dashboard, and the agent retries
///    at the next check-in cycle. That is functionally correct for a user
///    deferral, but unreadable in reporting.
///  - **Our telemetry** therefore needs the detail. The source of truth for
///    reporting is `os_log` + the state store, not the Intune dashboard.
///
/// The ranges are stable and must not be reordered: log queries rely on them.
public enum ExitCode: Int32, CaseIterable, Sendable {

    // MARK: 0-9 — definitive outcome

    /// Installation done, nothing else to do.
    case success = 0
    /// Unclassified failure. To avoid: prefer a specific code.
    case failure = 1
    /// Manifest absent, unreadable, or schemaVersion not supported.
    case invalidManifest = 2
    /// The binary must run as root (Intune agent context).
    case privilegesRequired = 3
    /// Requirement not met (disk, OS version). Do not retry identically: the state
    /// of the device must change first.
    case requirementNotMet = 4
    /// The forced close (SIGKILL) failed: a process survived the signal.
    case forceCloseFailed = 5
    /// A hook script failed, or was refused by the security checks (path outside
    /// the manifest directory, owner other than root, writable by others).
    case hookFailed = 6

    // MARK: 60-69 — not installed, but nothing is broken

    /// The user requested a deferral. They have at least one left.
    case deferredByUser = 60
    /// Blocking apps open and no one logged in to respond.
    case blockedNoConsoleUser = 61
    /// User in a video call or full-screen presentation (PM assertion).
    case blockedUserPresenting = 62
    /// Session locked: closing apps now risks losing work with no one able to
    /// weigh in.
    case blockedScreenLocked = 63
    /// Silent/nonInteractive mode with blocking apps and no authorization for a
    /// forced close.
    case blockedSilentMode = 64
    /// The user dodged the dialog (close box, Cmd-Q) with no deferral available,
    /// or applications stayed open while the forced close was not authorized.
    /// Distinct from `deferredByUser`: no deferral was consumed, so the counter
    /// does not advance.
    case blockedUserDismissed = 65

    // MARK: 70-79 — installed, system action required

    /// Equivalent of the Windows 3010. Derived from
    /// `installer -query RestartAction` = RecommendRestart | RequireRestart.
    case requiresRestart = 70
    /// RestartAction = RequireLogout.
    case requiresLogout = 71
    /// RestartAction = RequireShutdown.
    case requiresShutdown = 72

    /// `true` if the installation did not happen for a legitimate and transient
    /// reason. Intune will show `failed`: that is expected, not a breakdown.
    public var isTransientBlock: Bool { (60...69).contains(Int(rawValue)) }

    /// `true` if the payload is indeed installed, with or without a system action.
    public var isSuccess: Bool { rawValue == 0 || (70...79).contains(Int(rawValue)) }

    /// Stable snake_case slug, meant for log parsing. Never change it without
    /// updating the corresponding telemetry queries.
    public var slug: String {
        switch self {
        case .success:              return "success"
        case .failure:              return "failure"
        case .invalidManifest:      return "invalid_manifest"
        case .privilegesRequired:   return "privileges_required"
        case .requirementNotMet:    return "requirement_not_met"
        case .forceCloseFailed:     return "force_close_failed"
        case .hookFailed:           return "hook_failed"
        case .deferredByUser:       return "deferred_by_user"
        case .blockedNoConsoleUser: return "blocked_no_console_user"
        case .blockedUserPresenting:return "blocked_user_presenting"
        case .blockedScreenLocked:  return "blocked_screen_locked"
        case .blockedSilentMode:    return "blocked_silent_mode"
        case .blockedUserDismissed: return "blocked_user_dismissed"
        case .requiresRestart:      return "requires_restart"
        case .requiresLogout:       return "requires_logout"
        case .requiresShutdown:     return "requires_shutdown"
        }
    }
}
