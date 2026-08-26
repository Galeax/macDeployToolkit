import Foundation

// Protocol between the agent (root, daemon context) and the helper (user
// session). The split into two processes is not a stylistic choice: from a
// daemon there is no access to the WindowServer, so no UI is possible. The helper
// therefore only serves to display the dialogs; closing applications happens on
// the agent side, via `SIGKILL`.

public enum UIRequest: Codable, Equatable, Sendable {
    case ping
    case showDialog(DialogSpec)
    /// Displays a dialog and returns immediately, without waiting for it to close.
    /// Since the helper is a one-shot process, swiftDialog is launched detached and
    /// survives its exit: this is what allows a progress dialog while the agent
    /// works.
    ///
    /// The response carries the PID, which the agent keeps for `dismissDetached`.
    /// No PID file: the helper runs in the user session and would not write into
    /// the agent's space.
    case showDetached(DialogSpec)
    case dismissDetached(pid: Int32)
    case dismiss
}

/// Result of a close attempt by `SIGKILL`.
public struct TerminationResult: Codable, Equatable, Sendable {
    public var terminated: [String]
    public var stillRunning: [String]

    public init(terminated: [String] = [], stillRunning: [String] = []) {
        self.terminated = terminated
        self.stillRunning = stillRunning
    }

    public var isComplete: Bool { stillRunning.isEmpty }
}

public enum UIResponse: Codable, Equatable, Sendable {
    case pong
    case dialogOutcome(DialogOutcome)
    /// PID of the detached dialog, to hand back to `dismissDetached`.
    case detachedStarted(pid: Int32)
    case acknowledged
    case failed(reason: String)
}

/// JSON frames delimited by newlines.
///
/// Chosen over a length prefix to stay debuggable: you can hook `nc` onto the
/// socket during an incident and read what goes by. On JSON without
/// `.prettyPrinted`, no literal newline is emitted, so the delimiter is
/// unambiguous.
public enum LineCodec {

    public static let delimiter = UInt8(0x0A)

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(delimiter)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        let payload = line.last == delimiter ? line.dropLast() : line[...]
        return try JSONDecoder().decode(type, from: Data(payload))
    }

    /// Splits an accumulated buffer into complete frames plus the remainder.
    ///
    /// A socket read does not align on messages: it may deliver two frames at once
    /// or cut a frame in two. The remainder is fed back into the next read.
    public static func split(buffer: Data) -> (lines: [Data], remainder: Data) {
        var lines: [Data] = []
        var current = Data()
        for byte in buffer {
            if byte == delimiter {
                if !current.isEmpty { lines.append(current) }
                current = Data()
            } else {
                current.append(byte)
            }
        }
        return (lines, current)
    }
}
