import Foundation

/// Result of `installer -query RestartAction -pkg <x> -target /`.
///
/// This is the macOS equivalent of the Windows 3010 code, and the only reliable
/// way to know that a pkg requires a restart: the `RestartAction` is declared in
/// the package's Distribution, there is nothing to guess after the fact.
///
/// To be queried BEFORE installing: afterwards, the information is no longer
/// available as simply.
public enum RestartAction: String, Codable, Equatable, Sendable {
    case none
    case recommendRestart
    case requireRestart
    case requireLogout
    case requireShutdown

    /// Lenient parsing: `installer` may emit spaces, a newline, or nothing at all
    /// on a pkg without a declaration. Any unrecognized value counts as `.none` —
    /// presuming a restart on unknown output would be far more annoying for the
    /// user than the opposite.
    public static func parse(_ output: String) -> RestartAction {
        let cleaned = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch cleaned {
        case "none", "":            return .none
        case "recommendrestart":    return .recommendRestart
        case "requirerestart":      return .requireRestart
        case "requirelogout":       return .requireLogout
        case "requireshutdown":     return .requireShutdown
        default:                    return .none
        }
    }

    /// `RecommendRestart` and `RequireRestart` both report a 70. The nuance exists
    /// on Apple's side but no MDM does anything with it, and a recommended restart
    /// not done produces the same symptoms as a required restart not done.
    public var exitCode: ExitCode {
        switch self {
        case .none:                                 return .success
        case .recommendRestart, .requireRestart:    return .requiresRestart
        case .requireLogout:                        return .requiresLogout
        case .requireShutdown:                      return .requiresShutdown
        }
    }

    public var requiresUserAction: Bool { self != .none }
}
