import Foundation

/// A process observed on the device. Collected by `MacADTMac` via libproc, but
/// declared here so that the reconciliation with the manifest stays a pure
/// function — and therefore testable off macOS, which the collection cannot be.
public struct RunningProcess: Equatable, Sendable {
    public let pid: Int32
    public let executablePath: String
    /// Resolved by walking up to the enclosing `.app` bundle. `nil` for a binary
    /// outside a bundle (a daemon, a command-line tool).
    public let bundleIdentifier: String?

    public init(pid: Int32, executablePath: String, bundleIdentifier: String?) {
        self.pid = pid
        self.executablePath = executablePath
        self.bundleIdentifier = bundleIdentifier
    }
}

public enum AppMatcher {

    /// Which of the manifest's blocking applications are actually running.
    ///
    /// The manifest order is preserved: it is the order in which they will appear in
    /// the dialog, and a stable order prevents a user from seeing the list
    /// reorganize between two displays.
    ///
    /// Two criteria, in this order:
    ///  1. bundle ID, compared case-insensitively — this is the reliable criterion;
    ///  2. `executableName`, a safety net for applications repackaged internally
    ///     whose bundle ID was rewritten.
    public static func matching(
        specs: [BlockingAppSpec],
        processes: [RunningProcess]
    ) -> [BlockingAppSpec] {
        specs.filter { spec in processes.contains { matches(spec, $0) } }
    }

    /// The PIDs to target for a given application. Useful for the last-resort
    /// `SIGKILL`: a modern application has several processes (renderer, GPU,
    /// helpers) and killing only one leaves it in an inconsistent state.
    public static func pids(
        for spec: BlockingAppSpec,
        processes: [RunningProcess]
    ) -> [Int32] {
        processes.filter { matches(spec, $0) }.map(\.pid)
    }

    /// Both criteria are optional on the manifest side, but at least one is
    /// guaranteed present by decoding.
    private static func matches(_ spec: BlockingAppSpec, _ process: RunningProcess) -> Bool {
        if let specIdentifier = spec.bundleIdentifier,
           let processIdentifier = process.bundleIdentifier,
           specIdentifier.compare(processIdentifier, options: .caseInsensitive) == .orderedSame {
            return true
        }
        if let executableName = spec.executableName {
            return BundlePath.lastComponent(process.executablePath) == executableName
        }
        return false
    }
}

public enum BundlePath {

    public static func lastComponent(_ path: String) -> String {
        String(path.split(separator: "/").last ?? "")
    }

    /// Walks up from an executable path to the **innermost** `.app` bundle that
    /// contains it.
    ///
    /// The innermost and not the outermost, deliberately: for
    /// `/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper`
    /// we want `Slack Helper.app`, whose bundle ID is the helper's. Otherwise every
    /// render process would be counted as the main application, and closing Slack
    /// would seem to have failed while only helpers remain.
    /// Returns `nil` for a plug-in process (`.appex`, `.xpc`): the innermost
    /// container is then not a `.app`, and walking up to the host `.app` would make
    /// a widget extension pass for the application itself.
    ///
    /// Measured on macOS 26: Notes, Calendar, Photos, Weather, Reminders and a dozen
    /// others appeared permanently open this way, while no window existed — their
    /// widget extensions run in the background. For the gate, the consequence is not
    /// cosmetic: the dialog asks to close an invisible application, the user cannot
    /// satisfy the request, and `terminate()` does not make an extension disappear
    /// that the system relaunches on demand.
    public static func enclosingAppBundle(forExecutablePath path: String) -> String? {
        // The three containers that carry an Info.plist and can therefore resolve a
        // bundle ID. Only `.app` designates an application.
        let containers = [".app", ".appex", ".xpc"]
        let parts = PathSafety.components(path)
        guard let index = parts.lastIndex(where: { part in
            containers.contains { part.hasSuffix($0) }
        }) else { return nil }
        guard parts[index].hasSuffix(".app") else { return nil }
        return "/" + parts.prefix(index + 1).joined(separator: "/")
    }
}
