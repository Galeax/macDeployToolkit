// NOT VERIFIED BY LINUX CI — this file only compiles on macOS.

#if canImport(Darwin)
import Foundation
import MDTKit

public enum HelperBridgeError: Error, CustomStringConvertible {
    case helperMissing(path: String)
    case noConsoleUser
    case timedOut(seconds: TimeInterval)
    case malformedResponse(String)
    case helperFailed(exitCode: Int32, stderr: String)

    public var description: String {
        switch self {
        case .helperMissing(let path):
            return "helper not found: \(path)"
        case .noConsoleUser:
            return "no user session to present the UI"
        case .timedOut(let seconds):
            return "the helper did not respond within \(Int(seconds)) s"
        case .malformedResponse(let detail):
            return "unreadable helper response: \(detail)"
        case .helperFailed(let code, let stderr):
            return "the helper failed (code \(code)): \(stderr)"
        }
    }
}

/// Bridge from agent (root, daemon) -> helper (user session).
///
/// One one-shot invocation per exchange, JSON request on stdin, JSON response on
/// stdout. No unix socket: the exchanges are short, sequential and
/// request/response, and a socket server would only bring file permissions to
/// manage, orphaned sockets to clean up and a lifecycle to watch.
public enum HelperBridge {

    public static let defaultHelperPath = "/usr/local/coreupdate/macdeploy-ui"

    /// Launches the helper in the user's session.
    ///
    /// `launchctl asuser` **and** `sudo -u`, both, and this is not redundant:
    ///  - `asuser` places the process in the session's bootstrap context,
    ///    without which there is no access to the WindowServer and therefore no UI;
    ///  - `sudo -u` actually drops privileges, so the dialog is shown on behalf
    ///    of the user and not root.
    public static func send(
        _ request: UIRequest,
        helperPath: String = defaultHelperPath,
        dialogPath: String = CommandLineOptions.defaultDialogPath,
        timeout: TimeInterval = 1_800,
        logger: DeployLogging
    ) throws -> UIResponse {

        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            throw HelperBridgeError.helperMissing(path: helperPath)
        }
        guard let user = SessionInspector.consoleUser() else {
            throw HelperBridgeError.noConsoleUser
        }

        let payload = try LineCodec.encode(request)
        logger.debug("helper <- \(String(data: payload, encoding: .utf8)?.prefix(400) ?? "")")

        // `dialogPath` is passed in argv[2]: all dialogs are shown by the helper,
        // so without this forwarding the agent's `--dialog` would have no effect
        // and the helper would always fall back to its default.
        let result = try ProcessRunner.run(
            "/bin/launchctl",
            ["asuser", String(user.uid), "/usr/bin/sudo", "-u", user.username,
             helperPath, "serve", dialogPath],
            input: payload,
            timeout: timeout)

        if result.timedOut { throw HelperBridgeError.timedOut(seconds: timeout) }

        // The helper encodes its outcome in the JSON response, not in its exit
        // code: so a non-zero code is only treated as fatal if stdout is empty,
        // otherwise a valid response would be thrown away.
        let lines = LineCodec.split(buffer: Data(result.standardOutput.utf8)).lines
        guard let last = lines.last else {
            throw HelperBridgeError.helperFailed(
                exitCode: result.exitCode, stderr: result.standardError)
        }
        do {
            return try LineCodec.decode(UIResponse.self, from: last)
        } catch {
            throw HelperBridgeError.malformedResponse(String(describing: error))
        }
    }
}
#endif
