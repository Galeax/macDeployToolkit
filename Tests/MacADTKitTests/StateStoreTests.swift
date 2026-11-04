import XCTest
@testable import MacADTKit

final class StateStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macadtkit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> PlistStateStore {
        PlistStateStore(directory: directory)
    }

    func testUnknownKeyYieldsFreshState() {
        let state = makeStore().load(packageKey: "never-seen")
        XCTAssertEqual(state.packageKey, "never-seen")
        XCTAssertEqual(state.deferralsUsed, 0)
        XCTAssertNil(state.firstPromptDate)
    }

    func testRoundTripThroughDisk() throws {
        let store = makeStore()
        var state = DeploymentState(packageKey: "slack")
        state.deferralsUsed = 2
        state.firstPromptDate = Date(timeIntervalSince1970: 1_770_000_000)
        state.lastOutcome = ExitCode.deferredByUser.slug
        state.installedVersion = "4.36.140"
        try store.save(state)

        // Re-read by a fresh instance: we check the disk, not a cache.
        let reloaded = makeStore().load(packageKey: "slack")
        XCTAssertEqual(reloaded, state)
    }

    func testStatesAreIsolatedPerPackage() throws {
        let store = makeStore()
        var slack = DeploymentState(packageKey: "slack")
        slack.deferralsUsed = 3
        try store.save(slack)

        var chrome = DeploymentState(packageKey: "chrome")
        chrome.deferralsUsed = 1
        try store.save(chrome)

        XCTAssertEqual(store.load(packageKey: "slack").deferralsUsed, 3)
        XCTAssertEqual(store.load(packageKey: "chrome").deferralsUsed, 1)
        XCTAssertEqual(store.allStates().count, 2)
    }

    func testResetClearsOnlyTheTargetedPackage() throws {
        let store = makeStore()
        var slack = DeploymentState(packageKey: "slack")
        slack.deferralsUsed = 3
        try store.save(slack)
        var chrome = DeploymentState(packageKey: "chrome")
        chrome.deferralsUsed = 1
        try store.save(chrome)

        try store.reset(packageKey: "slack")
        XCTAssertEqual(store.load(packageKey: "slack").deferralsUsed, 0)
        XCTAssertEqual(store.load(packageKey: "chrome").deferralsUsed, 1)
    }

    /// A corrupted state must never block every deployment on the device. The price
    /// accepted: the deferral counters restart from zero.
    func testCorruptedStateFileDegradesToFreshState() throws {
        let url = directory.appendingPathComponent("slack.plist")
        try Data("this is not a plist".utf8).write(to: url)

        let store = makeStore()
        XCTAssertEqual(store.load(packageKey: "slack").deferralsUsed, 0)
        // And it must stay writable afterward.
        var state = DeploymentState(packageKey: "slack")
        state.deferralsUsed = 1
        try store.save(state)
        XCTAssertEqual(makeStore().load(packageKey: "slack").deferralsUsed, 1)
    }

    /// A corrupted state affects ONLY its application, which was not the case with a
    /// shared file: corruption there handed its deferrals back to everyone.
    func testCorruptionIsConfinedToOneDeployment() throws {
        let store = makeStore()
        var teams = DeploymentState(packageKey: "teams")
        teams.deferralsUsed = 2
        try store.save(teams)

        try Data("corrupt".utf8).write(
            to: directory.appendingPathComponent("slack.plist"))

        XCTAssertEqual(store.load(packageKey: "slack").deferralsUsed, 0)
        XCTAssertEqual(store.load(packageKey: "teams").deferralsUsed, 2)
    }

    /// The heart of the split: two deployments do not write the same file, so they
    /// cannot lose each other's deferral counter. With a single file, the last writer
    /// won and the user got back deferrals already consumed.
    func testConcurrentDeploymentsDoNotClobberEachOther() throws {
        var slack = DeploymentState(packageKey: "slack")
        slack.deferralsUsed = 1
        var teams = DeploymentState(packageKey: "teams")
        teams.deferralsUsed = 3

        // Two distinct stores, like two processes: each read before the other wrote.
        let first = makeStore()
        let second = makeStore()
        try first.save(slack)
        try second.save(teams)

        XCTAssertEqual(makeStore().load(packageKey: "slack").deferralsUsed, 1)
        XCTAssertEqual(makeStore().load(packageKey: "teams").deferralsUsed, 3)
        XCTAssertEqual(makeStore().allStates().map(\.packageKey), ["slack", "teams"])
    }

    /// The `packageKey` becomes a file name written by a root process: it must undergo
    /// the same reduction as `logName`, otherwise a key with `../` would make the state
    /// an arbitrary-write primitive.
    func testTraversalInPackageKeyCannotEscapeTheDirectory() throws {
        let store = makeStore()
        try store.save(DeploymentState(packageKey: "../../etc/evil"))

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("evil.plist").path),
            "the key must be reduced to its last component")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.deletingLastPathComponent()
                    .appendingPathComponent("etc/evil.plist").path))
    }

    func testWritesReadablePlistXML() throws {
        let url = directory.appendingPathComponent("slack.plist")
        let store = makeStore()
        try store.save(DeploymentState(packageKey: "slack"))

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.hasPrefix("<?xml"),
                      "the state must stay readable by an admin during an incident")
        XCTAssertTrue(contents.contains("slack"))
    }

    func testInMemoryStoreMatchesProtocolBehaviour() throws {
        let store = InMemoryStateStore()
        XCTAssertEqual(store.load(packageKey: "x").deferralsUsed, 0)
        var state = DeploymentState(packageKey: "x")
        state.deferralsUsed = 4
        try store.save(state)
        XCTAssertEqual(store.load(packageKey: "x").deferralsUsed, 4)
        try store.reset(packageKey: "x")
        XCTAssertEqual(store.load(packageKey: "x").deferralsUsed, 0)
    }
}
