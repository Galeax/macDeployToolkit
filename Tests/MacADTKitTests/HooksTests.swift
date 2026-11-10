import XCTest
@testable import MacADTKit

/// Per-application hook security.
///
/// A script path read from a JSON and then run as root is an arbitrary-code-execution
/// primitive. If the manifest — or the directory that contains it — is writable by
/// anything other than root, the deployment becomes a local privilege escalation.
/// These tests cover the four safeguards.
final class HooksTests: XCTestCase {

    private let manifestDirectory = "/Library/Application Support/MacADT/Deploy/manifests/slack"

    private func resolve(_ reference: String) -> Result<String, HookRejection> {
        HookResolver.resolve(reference: reference, manifestDirectory: manifestDirectory)
    }

    // MARK: - Path confinement

    func testRelativeReferenceResolvesInsideManifestDirectory() throws {
        let resolved = try resolve("pre-install.sh").get()
        XCTAssertEqual(resolved, manifestDirectory + "/pre-install.sh")
    }

    func testNestedRelativeReferenceIsAllowed() throws {
        let resolved = try resolve("hooks/pre-install.sh").get()
        XCTAssertEqual(resolved, manifestDirectory + "/hooks/pre-install.sh")
    }

    /// `..` are refused, never resolved: it is the only way to guarantee confinement
    /// without having to reason about symbolic links.
    func testTraversalIsRefused() {
        for reference in ["../evil.sh", "hooks/../../evil.sh", "a/../../../tmp/evil.sh"] {
            guard case .failure(let reason) = resolve(reference) else {
                return XCTFail("\(reference) must be refused")
            }
            XCTAssertEqual(reason, .escapesManifestDirectory)
        }
    }

    /// An absolute path is accepted only if it already denotes a descendant of the
    /// manifest directory. The manifest can only point at scripts shipped with it —
    /// never `/tmp/payload.sh`.
    func testAbsoluteReferenceOutsideDirectoryIsRefused() {
        for reference in ["/tmp/payload.sh", "/usr/local/bin/whatever", "/etc/passwd"] {
            guard case .failure(let reason) = resolve(reference) else {
                return XCTFail("\(reference) must be refused")
            }
            XCTAssertEqual(reason, .escapesManifestDirectory)
        }
    }

    func testAbsoluteReferenceInsideDirectoryIsAccepted() throws {
        let resolved = try resolve(manifestDirectory + "/pre-install.sh").get()
        XCTAssertEqual(resolved, manifestDirectory + "/pre-install.sh")
    }

    /// The string-prefix trap: a neighboring directory whose name starts the same
    /// must not pass for a descendant.
    func testSiblingDirectoryWithSharedPrefixIsRefused() {
        guard case .failure = resolve("/Library/Application Support/MacADT/Deploy/manifests/slack-evil/x.sh") else {
            return XCTFail("a neighboring directory must not be seen as a descendant")
        }
    }

    func testReferenceEqualToDirectoryItselfIsRefused() {
        guard case .failure = resolve(manifestDirectory) else {
            return XCTFail("the directory itself is not a script")
        }
    }

    // MARK: - File security

    private func attributes(
        exists: Bool = true,
        isExecutable: Bool = true,
        ownerUID: UInt32 = 0,
        permissions: UInt16 = 0o755
    ) -> FileSecurityAttributes {
        FileSecurityAttributes(
            exists: exists, isExecutable: isExecutable,
            ownerUID: ownerUID, permissions: permissions)
    }

    func testAcceptsRootOwnedNonWritableExecutable() {
        XCTAssertNil(HookResolver.validate(attributes(permissions: 0o755)))
        XCTAssertNil(HookResolver.validate(attributes(permissions: 0o700)))
        XCTAssertNil(HookResolver.validate(attributes(permissions: 0o555)))
    }

    func testRejectsMissingAndNonExecutable() {
        XCTAssertEqual(HookResolver.validate(attributes(exists: false)), .missing)
        XCTAssertEqual(HookResolver.validate(attributes(isExecutable: false)), .notExecutable)
    }

    func testRejectsNonRootOwner() {
        XCTAssertEqual(HookResolver.validate(attributes(ownerUID: 501)), .notOwnedByRoot)
    }

    /// A root-executable script writable by others is a root shell handed out.
    func testRejectsGroupOrOtherWritable() {
        XCTAssertEqual(HookResolver.validate(attributes(permissions: 0o775)), .writableByGroupOrOther)
        XCTAssertEqual(HookResolver.validate(attributes(permissions: 0o757)), .writableByGroupOrOther)
        XCTAssertEqual(HookResolver.validate(attributes(permissions: 0o777)), .writableByGroupOrOther)
        XCTAssertEqual(HookResolver.validate(attributes(permissions: 0o722)), .writableByGroupOrOther)
    }

    /// The order of the checks must report the most fundamental cause: a missing file
    /// is not "non-executable".
    func testMostFundamentalRejectionWins() {
        XCTAssertEqual(
            HookResolver.validate(attributes(exists: false, isExecutable: false, ownerUID: 501, permissions: 0o777)),
            .missing)
    }

    // MARK: - Decoding the hooks block

    func testHookSpecDecodesBothNamingStyles() throws {
        let manifest = try Manifest.decode(Data("""
        {
          "packageKey": "x",
          "hooks": {
            "preInstall": "pre-install.sh",
            "post-install": "post-install.sh",
            "PreUninstall": "pre-uninstall.sh"
          }
        }
        """.utf8))
        let hooks = try XCTUnwrap(manifest.hooks)

        XCTAssertEqual(hooks.reference(for: .preInstall), "pre-install.sh")
        XCTAssertEqual(hooks.reference(for: .postInstall), "post-install.sh")
        XCTAssertEqual(hooks.reference(for: .preUninstall), "pre-uninstall.sh")
        XCTAssertNil(hooks.reference(for: .postUninstall))
        XCTAssertFalse(hooks.isEmpty)
    }

    func testEmptyHookSpecIsDetected() throws {
        let manifest = try Manifest.decode(Data(#"{"packageKey": "x", "hooks": {}}"#.utf8))
        XCTAssertTrue(try XCTUnwrap(manifest.hooks).isEmpty)
    }

    /// The conventional names reuse those of Veille's `extrafiles/`, so a packager
    /// finds their bearings.
    func testConventionalFilenamesMatchVeilleLayout() {
        XCTAssertEqual(HookPhase.preInstall.conventionalFilename, "pre-install.sh")
        XCTAssertEqual(HookPhase.postInstall.conventionalFilename, "post-install.sh")
        XCTAssertEqual(HookPhase.preUninstall.conventionalFilename, "pre-uninstall.sh")
        XCTAssertEqual(HookPhase.postUninstall.conventionalFilename, "post-uninstall.sh")
    }

    // MARK: - Ignored exit codes

    func testIgnoredExitCodesAcceptVeilleNames() throws {
        for key in ["ignoredExitCodes", "IgnoreExitCodes", "SkipExitCodes"] {
            let manifest = try Manifest.decode(
                Data("{\"packageKey\": \"x\", \"\(key)\": [3010, 1641]}".utf8))
            XCTAssertEqual(manifest.ignoredExitCodes, [3010, 1641], "key \(key)")
        }
    }
}
