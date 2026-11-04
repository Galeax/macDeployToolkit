// NOT VERIFIED BY LINUX CI — this file only compiles on macOS.
//
// Probe #3 of the spike: does swiftDialog launched via `launchctl asuser` display
// correctly, and does it survive fast user switching.

#if canImport(Darwin)
import Foundation
import Darwin
import MacADTKit

public enum DialogRunnerError: Error, CustomStringConvertible {
    case dialogBinaryMissing(path: String)

    public var description: String {
        switch self {
        case .dialogBinaryMissing(let path):
            return "swiftDialog not found: \(path). Deploy it before macadt-deploy."
        }
    }
}

/// Display via swiftDialog.
///
/// Assumed external dependency: swiftDialog is already notarized by its author,
/// can post to Notification Center (which a bare binary cannot do, for lack of a
/// bundle ID), and handles markdown, dark mode and accessibility. Reimplementing
/// all of it would have cost four weeks for a worse result.
///
/// The indirection through `DialogSpec` is what would let us swap it out without
/// touching the deployment logic.
public enum DialogRunner {

    /// Launches a dialog and returns immediately.
    ///
    /// The helper being a one-shot process, swiftDialog must survive its exit.
    /// This is the case naturally on Unix — the child is reparented to launchd.
    ///
    /// CRITICAL DETAIL: the three streams go to `/dev/null`, and this is not
    /// hygiene. If swiftDialog inherited the helper's standard output, the pipe
    /// would stay open after the helper exits, and the agent — which reads until
    /// end of stream — would wait for the dialog to close. Which is exactly the
    /// hang we are trying to avoid by detaching it.
    public static func presentDetached(
        _ spec: DialogSpec,
        dialogPath: String = CommandLineOptions.defaultDialogPath,
        logger: DeployLogging
    ) throws -> Int32 {

        guard FileManager.default.isExecutableFile(atPath: dialogPath) else {
            throw DialogRunnerError.dialogBinaryMissing(path: dialogPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: dialogPath)
        process.arguments = spec.arguments()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        logger.info("detached dialog launched (pid \(process.processIdentifier))")
        return process.processIdentifier
    }

    /// Closes a detached dialog. A PID that has already exited is not an error:
    /// it's the normal case for a dialog carrying a timer.
    ///
    /// The process identity is verified before any signal. Between the launch and
    /// here, the dialog may have exited on its own and its PID been recycled by the
    /// system: sending a SIGTERM to some arbitrary process of the user's would be
    /// far worse than leaving a dialog open.
    ///
    /// The check is heuristic — comparison of the executable name, because
    /// `/usr/local/bin/dialog` is usually a link to the bundle's internal binary
    /// and `proc_pidpath` returns the resolved path. Its failure is benign: we
    /// refrain from killing.
    public static func dismissDetached(pid: Int32, logger: DeployLogging) {
        guard pid > 0 else { return }

        var buffer = [CChar](repeating: 0, count: procPidPathInfoMaxSize)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else {
            logger.debug("detached dialog pid \(pid) already terminated")
            return
        }

        let path = String(cString: buffer)
        let name = BundlePath.lastComponent(path).lowercased()
        guard name.contains("dialog") else {
            logger.warning("pid \(pid) is no longer swiftDialog but \(path): "
                + "no signal sent")
            return
        }

        kill(pid, SIGTERM)
        logger.debug("detached dialog closed (pid \(pid))")
    }

    /// Presents the dialog, re-showing it as long as the persistence policy
    /// requires.
    ///
    /// swiftDialog has no persistent mode: re-showing an ignored dialog requires
    /// relaunching it. Without this, a dialog pushed behind a video-call window is
    /// never seen, and the forced close that follows seems to arrive without
    /// warning — this is the scenario that destroys trust in the tool.
    ///
    /// The loop computation lives in `MacADTKit.DialogLoop` and is tested.
    public static func present(
        _ spec: DialogSpec,
        dialogPath: String = CommandLineOptions.defaultDialogPath,
        logger: DeployLogging
    ) throws -> DialogOutcome {

        guard FileManager.default.isExecutableFile(atPath: dialogPath) else {
            throw DialogRunnerError.dialogBinaryMissing(path: dialogPath)
        }

        var elapsed = 0
        var presentations = 0

        while true {
            guard case .present(let timer) = DialogLoop.next(spec: spec, elapsedSeconds: elapsed) else {
                logger.notice("dialog budget exhausted after \(elapsed) s without a response")
                return .abandoned
            }

            presentations += 1
            if presentations > 1 {
                logger.info("re-showing the dialog (presentation #\(presentations))")
            }

            // Margin on the process timeout: it is swiftDialog that must expire
            // and return code 4, not us killing it — a killed dialog returns no
            // usable outcome.
            let processTimeout = timer.map { TimeInterval($0) + 30 } ?? 3_600
            let startedAt = Date()
            let result = try ProcessRunner.run(
                dialogPath, spec.arguments(timerOverride: timer), timeout: processTimeout)

            // `max(1, ...)` guarantees the counter advances: without it, a
            // swiftDialog that exited instantly would produce a tight infinite
            // loop.
            elapsed += max(1, Int(Date().timeIntervalSince(startedAt).rounded()))

            if result.timedOut {
                logger.warning("swiftDialog killed after \(Int(processTimeout)) s without returning an outcome")
                return .unknown
            }

            let outcome = DialogOutcome.from(exitCode: result.exitCode)
            if outcome == .timerExpired {
                if let resolved = DialogLoop.outcomeForTimerExpiry(spec: spec, elapsedSeconds: elapsed) {
                    logger.info("dialog: \(resolved.rawValue)")
                    return resolved
                }
                continue
            }

            logger.info("dialog: \(outcome.rawValue) (code \(result.exitCode))")
            return outcome
        }
    }
}
#endif
