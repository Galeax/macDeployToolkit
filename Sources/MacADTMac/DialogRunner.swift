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
        process.arguments = spec.launchArguments()
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

            // The countdown is driven from here, not by swiftDialog's `--timer`: its
            // bar is hard-wired beside the buttons, and once hidden it never expires
            // at all (both verified on swiftDialog 3.1.1). We advance a `--progress`
            // bar through the command file and close the dialog ourselves.
            let commandFile = NSTemporaryDirectory() + "macadt-dialog-\(UUID().uuidString).cmd"
            FileManager.default.createFile(atPath: commandFile, contents: nil)
            let ticker = timer.map { CountdownTicker(spec: spec, seconds: $0, commandFile: commandFile) }
            ticker?.start()
            defer {
                ticker?.cancel()
                try? FileManager.default.removeItem(atPath: commandFile)
            }

            // Margin on the process timeout: the `quit:` we send at expiry should
            // close the dialog; the kill is only the safety net.
            let processTimeout = timer.map { TimeInterval($0) + 30 } ?? 3_600
            let startedAt = Date()
            let result = try ProcessRunner.run(
                dialogPath, spec.launchArguments(timerOverride: timer, commandFile: commandFile),
                timeout: processTimeout)
            let expired = ticker?.cancel() ?? false

            // `max(1, ...)` guarantees the counter advances: without it, a
            // swiftDialog that exited instantly would produce a tight infinite
            // loop.
            elapsed += max(1, Int(Date().timeIntervalSince(startedAt).rounded()))

            var outcome = DialogOutcome.from(exitCode: result.exitCode)
            // A dialog we closed at expiry exits like a user quit (code 5), or is
            // killed if it ignored `quit:`. Either way it is an expiry — unless the
            // user clicked a button in the same instant, which is honored.
            if expired, outcome != .primary, outcome != .secondary {
                outcome = .timerExpired
            } else if result.timedOut {
                logger.warning("swiftDialog killed after \(Int(processTimeout)) s without returning an outcome")
                return .unknown
            }

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

/// Advances the countdown bar of a running dialog, then closes it.
///
/// One line per second into swiftDialog's command file: the bar position and the
/// label under it. At zero, `quit:`.
private final class CountdownTicker: @unchecked Sendable {

    private let spec: DialogSpec
    private let seconds: Int
    private let commandFile: String
    private let queue = DispatchQueue(label: "com.macadt.deploy.countdown")
    private let lock = NSLock()
    private var source: DispatchSourceTimer?
    private var elapsed = 0
    private var expired = false

    init(spec: DialogSpec, seconds: Int, commandFile: String) {
        self.spec = spec
        self.seconds = seconds
        self.commandFile = commandFile
    }

    func start() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 1, repeating: 1)
        source.setEventHandler { [weak self] in self?.tick() }
        lock.lock(); self.source = source; lock.unlock()
        source.resume()
    }

    /// Stops the ticker. Returns whether the countdown had run out.
    @discardableResult
    func cancel() -> Bool {
        lock.lock(); defer { lock.unlock() }
        source?.cancel()
        source = nil
        return expired
    }

    private func tick() {
        lock.lock(); defer { lock.unlock() }
        guard source != nil, !expired else { return }
        elapsed += 1
        var lines: [String] = []
        // Only a real deadline shows its bar; a persistence interval is silent.
        if spec.timerSeconds != nil {
            lines.append("progress: \(elapsed)")
            lines.append("progresstext: \(spec.countdownLabel(remaining: seconds - elapsed))")
        }
        if elapsed >= seconds {
            expired = true
            lines.append("quit:")
        }
        guard !lines.isEmpty, let handle = FileHandle(forWritingAtPath: commandFile) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try? handle.close()
    }
}
#endif
