import XCTest
@testable import MacADTKit

final class IPCTests: XCTestCase {

    private let dialog = DialogSpec(
        title: "T", message: "M", button1: "OK", button2: "Reporter",
        timerSeconds: 60, isBlocking: true)

    func testRequestRoundTrip() throws {
        let requests: [UIRequest] = [
            .ping,
            .dismiss,
            .showDialog(dialog),
            .showDetached(dialog),
            .dismissDetached(pid: 4242),
        ]
        for request in requests {
            let encoded = try LineCodec.encode(request)
            XCTAssertEqual(encoded.last, LineCodec.delimiter)
            XCTAssertEqual(try LineCodec.decode(UIRequest.self, from: encoded), request)
        }
    }

    func testResponseRoundTrip() throws {
        let responses: [UIResponse] = [
            .pong,
            .acknowledged,
            .dialogOutcome(.timerExpired),
            .detachedStarted(pid: 99),
            .failed(reason: "swiftDialog absent"),
        ]
        for response in responses {
            let encoded = try LineCodec.encode(response)
            XCTAssertEqual(try LineCodec.decode(UIResponse.self, from: encoded), response)
        }
    }

    func testDecodeToleratesMissingDelimiter() throws {
        let encoded = try JSONEncoder().encode(UIRequest.ping)
        XCTAssertEqual(try LineCodec.decode(UIRequest.self, from: encoded), .ping)
    }

    /// A read on a socket does not align with messages: it can deliver two frames at
    /// once.
    func testSplitExtractsMultipleFrames() throws {
        var buffer = Data()
        buffer.append(try LineCodec.encode(UIRequest.ping))
        buffer.append(try LineCodec.encode(UIRequest.dismiss))

        let (lines, remainder) = LineCodec.split(buffer: buffer)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(remainder.isEmpty)
        XCTAssertEqual(try LineCodec.decode(UIRequest.self, from: lines[0]), .ping)
        XCTAssertEqual(try LineCodec.decode(UIRequest.self, from: lines[1]), .dismiss)
    }

    /// ...or cut a frame in two. The remainder must come back intact to be reinjected
    /// into the next read.
    func testSplitKeepsPartialFrameAsRemainder() throws {
        var buffer = Data()
        buffer.append(try LineCodec.encode(UIRequest.ping))
        let partial = try JSONEncoder().encode(UIRequest.dismiss)
        buffer.append(partial.prefix(5))

        let (lines, remainder) = LineCodec.split(buffer: buffer)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(remainder, partial.prefix(5))
    }

    func testSplitReassemblesAcrossReads() throws {
        let frame = try LineCodec.encode(UIRequest.showDialog(dialog))
        let firstHalf = frame.prefix(frame.count / 2)
        let secondHalf = frame.suffix(from: frame.count / 2)

        var (lines, remainder) = LineCodec.split(buffer: Data(firstHalf))
        XCTAssertTrue(lines.isEmpty)

        var next = remainder
        next.append(Data(secondHalf))
        (lines, remainder) = LineCodec.split(buffer: next)

        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(remainder.isEmpty)
        XCTAssertEqual(try LineCodec.decode(UIRequest.self, from: lines[0]),
                       .showDialog(dialog))
    }

    func testSplitSkipsEmptyLines() {
        let buffer = Data("\n\n".utf8)
        let (lines, remainder) = LineCodec.split(buffer: buffer)
        XCTAssertTrue(lines.isEmpty)
        XCTAssertTrue(remainder.isEmpty)
    }

    func testTerminationResultCompleteness() {
        XCTAssertTrue(TerminationResult(terminated: ["a"]).isComplete)
        XCTAssertFalse(TerminationResult(stillRunning: ["a"]).isComplete,
                       "a process that survives the SIGKILL is not a success")
    }
}
