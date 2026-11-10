import XCTest
@testable import MacADTKit

final class RestartActionTests: XCTestCase {

    func testParsesEveryDocumentedValue() {
        XCTAssertEqual(RestartAction.parse("None"), RestartAction.none)
        XCTAssertEqual(RestartAction.parse("RecommendRestart"), .recommendRestart)
        XCTAssertEqual(RestartAction.parse("RequireRestart"), .requireRestart)
        XCTAssertEqual(RestartAction.parse("RequireLogout"), .requireLogout)
        XCTAssertEqual(RestartAction.parse("RequireShutdown"), .requireShutdown)
    }

    func testParsingToleratesWhitespaceAndCase() {
        XCTAssertEqual(RestartAction.parse("  requirerestart \n"), .requireRestart)
        XCTAssertEqual(RestartAction.parse("REQUIRELOGOUT"), .requireLogout)
    }

    /// An empty or unexpected output means `.none`: forcing a restart on an output we
    /// do not understand is far more annoying for the user than the opposite.
    func testUnknownOutputDegradesToNone() {
        XCTAssertEqual(RestartAction.parse(""), RestartAction.none)
        XCTAssertEqual(RestartAction.parse("\n"), RestartAction.none)
        XCTAssertEqual(RestartAction.parse("installer: error"), RestartAction.none)
    }

    func testExitCodeMapping() {
        XCTAssertEqual(RestartAction.none.exitCode, .success)
        XCTAssertEqual(RestartAction.recommendRestart.exitCode, .requiresRestart)
        XCTAssertEqual(RestartAction.requireRestart.exitCode, .requiresRestart)
        XCTAssertEqual(RestartAction.requireLogout.exitCode, .requiresLogout)
        XCTAssertEqual(RestartAction.requireShutdown.exitCode, .requiresShutdown)
    }

    func testEveryRestartExitCodeCountsAsSuccess() {
        for action in [RestartAction.recommendRestart, .requireRestart, .requireLogout, .requireShutdown] {
            XCTAssertTrue(action.exitCode.isSuccess,
                          "\(action): the payload is installed, only a system action remains")
            XCTAssertFalse(action.exitCode.isTransientBlock)
        }
    }

    func testRequiresUserAction() {
        XCTAssertFalse(RestartAction.none.requiresUserAction)
        XCTAssertTrue(RestartAction.requireRestart.requiresUserAction)
    }
}
