import Foundation

public enum LogLevel: String, Comparable, Sendable, CaseIterable {
    case debug, info, notice, warning, error

    private var rank: Int {
        switch self {
        case .debug:   return 0
        case .info:    return 1
        case .notice:  return 2
        case .warning: return 3
        case .error:   return 4
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }
}

public struct LogRecord: Equatable, Sendable {
    public let timestamp: Date
    public let level: LogLevel
    /// Deployment context, typically `packageKey/version`. Present on every line so
    /// that a `grep` on an incident isolates a deployment without having to
    /// reconstruct blocks.
    public let subject: String?
    public let message: String

    public init(timestamp: Date, level: LogLevel, subject: String?, message: String) {
        self.timestamp = timestamp
        self.level = level
        self.subject = subject
        self.message = message
    }
}

public enum LogFormatter {

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Deliberately flat, fixed-field format:
    /// `2026-08-05T14:03:11.482+0200 notice [Slack/4.3.1] message`
    ///
    /// A single line per event, never multi-line — that is what keeps `log show`
    /// and a `grep` usable during an incident. Newlines in the message are escaped.
    public static func format(_ record: LogRecord) -> String {
        let subject = record.subject.map { " [\($0)]" } ?? ""
        let message = record.message
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\(formatter.string(from: record.timestamp)) \(record.level.rawValue)\(subject) \(message)"
    }
}

public protocol DeployLogging: Sendable {
    func log(_ level: LogLevel, _ message: String)
}

extension DeployLogging {
    public func debug(_ message: String)   { log(.debug, message) }
    public func info(_ message: String)    { log(.info, message) }
    public func notice(_ message: String)  { log(.notice, message) }
    public func warning(_ message: String) { log(.warning, message) }
    public func error(_ message: String)   { log(.error, message) }
}

/// File logger, in append mode.
///
/// Degrades silently if the file is not writable (binary launched without root,
/// read-only volume): a deployment tool must never fail because it cannot write
/// its log. The failure is reported once on stderr, not on every line.
public final class FileLogger: DeployLogging, @unchecked Sendable {

    public static let defaultPath = "/var/log/coreupdate-deploy.log"

    private let handle: FileHandle?
    private let subject: String?
    private let minimumLevel: LogLevel
    private let lock = NSLock()

    public init(path: String = FileLogger.defaultPath, subject: String? = nil, minimumLevel: LogLevel = .info) {
        self.subject = subject
        self.minimumLevel = minimumLevel

        let manager = FileManager.default
        if !manager.fileExists(atPath: path) {
            let directory = (path as NSString).deletingLastPathComponent
            try? manager.createDirectory(atPath: directory, withIntermediateDirectories: true)
            // 0640: readable by the admin group, not by everyone. The log may
            // contain user file names.
            _ = manager.createFile(atPath: path, contents: nil,
                                   attributes: [.posixPermissions: 0o640])
        }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            self.handle = handle
        } else {
            self.handle = nil
            FileHandle.standardError.write(
                Data("macdeploy: log not writable (\(path)), continuing without a file log\n".utf8))
        }
    }

    deinit { try? handle?.close() }

    public func log(_ level: LogLevel, _ message: String) {
        guard level >= minimumLevel, let handle else { return }
        let record = LogRecord(timestamp: Date(), level: level, subject: subject, message: message)
        let line = LogFormatter.format(record) + "\n"
        lock.lock(); defer { lock.unlock() }
        handle.write(Data(line.utf8))
    }
}

/// stderr logger — never stdout: stdout stays reserved for machine-readable output
/// (`--dry-run --json`) so it remains pipe-able.
public final class ConsoleLogger: DeployLogging, @unchecked Sendable {

    private let subject: String?
    private let minimumLevel: LogLevel
    private let lock = NSLock()

    public init(subject: String? = nil, minimumLevel: LogLevel = .info) {
        self.subject = subject
        self.minimumLevel = minimumLevel
    }

    public func log(_ level: LogLevel, _ message: String) {
        guard level >= minimumLevel else { return }
        let record = LogRecord(timestamp: Date(), level: level, subject: subject, message: message)
        let line = LogFormatter.format(record) + "\n"
        lock.lock(); defer { lock.unlock() }
        FileHandle.standardError.write(Data(line.utf8))
    }
}

/// In-memory collection, for tests and to replay a run in `--dry-run`.
public final class MemoryLogger: DeployLogging, @unchecked Sendable {

    private var storage: [LogRecord] = []
    private let lock = NSLock()

    public init() {}

    public var records: [LogRecord] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    public func log(_ level: LogLevel, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append(LogRecord(timestamp: Date(), level: level, subject: nil, message: message))
    }
}

/// A log to which a destination can be added along the way.
///
/// Necessary for the per-application log: its name comes from the manifest, which
/// is only read after the global log is built. Opening the file at startup would
/// require reading the manifest twice, with two error-handling paths to keep in
/// sync.
public protocol AttachableLogging: DeployLogging {
    func attach(_ sink: DeployLogging)
}

public final class CompositeLogger: AttachableLogging, @unchecked Sendable {

    private var sinks: [DeployLogging]
    private let lock = NSLock()

    public init(_ sinks: [DeployLogging]) { self.sinks = sinks }

    public func attach(_ sink: DeployLogging) {
        lock.lock(); defer { lock.unlock() }
        sinks.append(sink)
    }

    public func log(_ level: LogLevel, _ message: String) {
        lock.lock()
        let current = sinks
        lock.unlock()
        // The copy is taken under lock then released: a slow sink must not block
        // adding another, and a write must not happen while holding the lock — a
        // FileLogger that blocks would freeze the whole log.
        for sink in current { sink.log(level, message) }
    }
}
