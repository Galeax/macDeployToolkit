// NOT VERIFIED BY LINUX CI — this file only compiles on macOS.

#if canImport(Darwin)
import Foundation
import MDTKit

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
    public let timedOut: Bool

    public var succeeded: Bool { exitCode == 0 && !timedOut }

    /// Non-empty lines of stdout — the form in which we consume
    /// `pkgutil --files`, `pkgutil --pkgs`, `dscl` and the like.
    public var outputLines: [String] {
        standardOutput
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

public enum ProcessRunnerError: Error, CustomStringConvertible {
    case launchFailed(executable: String, underlying: String)

    public var description: String {
        switch self {
        case .launchFailed(let executable, let underlying):
            return "unable to launch \(executable): \(underlying)"
        }
    }
}

public enum ProcessRunner {

    /// Runs a binary and captures its output.
    ///
    /// Both pipes are drained on concurrent queues BEFORE `waitUntilExit`. This
    /// is not a theoretical precaution: a full pipe blocks the child's writes,
    /// which never returns, and the parent waits forever. `pkgutil --files` on a
    /// large package far exceeds the buffer size — this is the hang you hit first
    /// in production, and never in tests.
    ///
    /// On timeout: `SIGTERM`, two seconds of grace, then `SIGKILL`.
    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        input: Data? = nil,
        timeout: TimeInterval? = nil,
        environment: [String: String]? = nil,
        currentDirectory: String? = nil
    ) throws -> ProcessResult {

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let inputPipe = input.map { _ in Pipe() }
        if let inputPipe { process.standardInput = inputPipe }

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(
                executable: executable, underlying: error.localizedDescription)
        }

        let box = OutputBox()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.coreupdate.deploy.process", attributes: .concurrent)

        // The write to stdin goes on its own queue, for the same reason as the
        // read: if the payload exceeds the pipe buffer, the write blocks until the
        // child consumes, and the child does not consume as long as we don't read
        // its output.
        if let inputPipe, let input {
            queue.async {
                inputPipe.fileHandleForWriting.write(input)
                try? inputPipe.fileHandleForWriting.close()
            }
        }

        group.enter()
        queue.async {
            box.setOutput(outputPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        queue.async {
            box.setError(errorPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        var timedOut = false
        if let timeout {
            if group.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                process.terminate()
                if group.wait(timeout: .now() + 2) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    group.wait()
                }
            }
        } else {
            group.wait()
        }

        process.waitUntilExit()

        return ProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: box.output),
            standardError: String(decoding: box.error),
            timedOut: timedOut)
    }

    /// Locked box so the two concurrent readers publish their result without a
    /// data race.
    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedOutput = Data()
        private var storedError = Data()

        func setOutput(_ data: Data) { lock.lock(); storedOutput = data; lock.unlock() }
        func setError(_ data: Data) { lock.lock(); storedError = data; lock.unlock() }
        var output: Data { lock.lock(); defer { lock.unlock() }; return storedOutput }
        var error: Data { lock.lock(); defer { lock.unlock() }; return storedError }
    }
}

extension String {
    /// A command's output is not guaranteed to be valid UTF-8 (exotic file names
    /// in a receipt). We substitute instead of failing.
    fileprivate init(decoding data: Data) {
        self = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
    }
}
#endif
