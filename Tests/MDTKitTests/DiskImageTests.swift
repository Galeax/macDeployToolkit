import XCTest
@testable import MDTKit

/// Disk image handling, on the decision side.
///
/// These rules are what let a vendor DMG travel as-is in the wrapper's payload: it
/// is never mounted on the build host, so nothing depends on `hdiutil` being present
/// in the packaging chain.
final class DiskImageTests: XCTestCase {

    // MARK: - Content classification

    func testSingleApplicationBundle() {
        XCTAssertEqual(
            DiskImageInspector.classify(entries: ["Google Chrome.app", "Applications"]),
            .applicationBundle("Google Chrome.app"))
    }

    /// The convenience symlink that almost every drag-and-drop DMG ships. Taking it
    /// for a target would copy `/Applications` into itself.
    func testApplicationsSymlinkIsIgnored() {
        XCTAssertEqual(
            DiskImageInspector.classify(entries: ["Applications"]),
            .empty)
        XCTAssertEqual(
            DiskImageInspector.classify(entries: ["Firefox.app", "Applications alias"]),
            .applicationBundle("Firefox.app"))
    }

    func testHiddenEntriesAreIgnored() {
        XCTAssertEqual(
            DiskImageInspector.classify(entries: [
                ".background", ".DS_Store", ".fseventsd", ".VolumeIcon.icns",
                "Bitwarden.app",
            ]),
            .applicationBundle("Bitwarden.app"))
    }

    func testSinglePackage() {
        XCTAssertEqual(
            DiskImageInspector.classify(entries: ["Install Adobe Acrobat Reader.pkg"]),
            .package("Install Adobe Acrobat Reader.pkg"))
        XCTAssertEqual(
            DiskImageInspector.classify(entries: ["Suite.mpkg"]),
            .package("Suite.mpkg"))
    }

    /// When an image contains both, the `.pkg` is the real installer; the `.app` is
    /// often only an uninstall assistant or documentation.
    func testPackageWinsOverBundle() {
        XCTAssertEqual(
            DiskImageInspector.classify(entries: [
                "Install Foo.pkg", "Uninstall Foo.app", "Applications",
            ]),
            .package("Install Foo.pkg"))
    }

    /// An ambiguous image must fail the install, not pick at random.
    func testMultipleCandidatesAreAmbiguous() {
        XCTAssertEqual(
            DiskImageInspector.classify(entries: ["Foo.app", "Bar.app"]),
            .ambiguous(["Bar.app", "Foo.app"]))
        XCTAssertEqual(
            DiskImageInspector.classify(entries: ["A.pkg", "B.pkg"]),
            .ambiguous(["A.pkg", "B.pkg"]))
    }

    /// `payload.bundleName` resolves the ambiguity.
    func testPreferredNameResolvesAmbiguity() {
        XCTAssertEqual(
            DiskImageInspector.classify(
                entries: ["Foo.app", "Bar.app"], preferredName: "Bar.app"),
            .applicationBundle("Bar.app"))
        XCTAssertEqual(
            DiskImageInspector.classify(
                entries: ["Install Foo.pkg", "Foo.app"], preferredName: "Foo.app"),
            .applicationBundle("Foo.app"),
            "an explicit name must take precedence over the preference for the pkg")
    }

    /// A declared name that is absent from the image must not short-circuit normal
    /// detection — the manifest may simply be behind a new version of the DMG.
    func testAbsentPreferredNameFallsBackToDetection() {
        XCTAssertEqual(
            DiskImageInspector.classify(
                entries: ["Slack.app"], preferredName: "Ancien Nom.app"),
            .applicationBundle("Slack.app"))
    }

    func testEmptyImage() {
        XCTAssertEqual(DiskImageInspector.classify(entries: []), .empty)
        XCTAssertEqual(
            DiskImageInspector.classify(entries: ["Lisez-moi.txt", "Licence.rtf"]),
            .empty)
    }

    // MARK: - Output of `hdiutil attach -plist`

    private let attachPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>system-entities</key>
      <array>
        <dict>
          <key>content-hint</key><string>GUID_partition_scheme</string>
          <key>dev-entry</key><string>/dev/disk4</string>
          <key>potentially-mountable</key><false/>
        </dict>
        <dict>
          <key>content-hint</key><string>Apple_partition_map</string>
          <key>dev-entry</key><string>/dev/disk4s1</string>
          <key>potentially-mountable</key><false/>
        </dict>
        <dict>
          <key>content-hint</key><string>Apple_HFS</string>
          <key>dev-entry</key><string>/dev/disk4s2</string>
          <key>mount-point</key><string>/private/tmp/dmg.aB3xY9</string>
          <key>potentially-mountable</key><true/>
          <key>volume-kind</key><string>hfs</string>
        </dict>
      </array>
    </dict>
    </plist>
    """

    /// Not every entry is mountable: an image exposes the whole disk, a partition
    /// table, then the volume that carries the mount point. We must find the latter.
    func testFindsMountPointAmongUnmountableEntities() throws {
        let attached = try XCTUnwrap(
            DiskImageAttachOutput.parse(attachPlist: Data(attachPlist.utf8)))
        XCTAssertEqual(attached.mountPoint, "/private/tmp/dmg.aB3xY9")
    }

    /// Detaching the partition would leave the disk attached, and the image would
    /// stay locked for the next run. It is the whole disk we must aim at — the
    /// shortest `/dev` entry.
    func testDetachTargetsWholeDiskNotPartition() throws {
        let attached = try XCTUnwrap(
            DiskImageAttachOutput.parse(attachPlist: Data(attachPlist.utf8)))
        XCTAssertEqual(attached.devEntry, "/dev/disk4")
    }

    func testEmptyMountPointIsNotAMountPoint() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>system-entities</key><array>
          <dict><key>dev-entry</key><string>/dev/disk7</string>
                <key>mount-point</key><string>   </string></dict>
          <dict><key>dev-entry</key><string>/dev/disk7s2</string>
                <key>mount-point</key><string>/Volumes/Foo</string></dict>
        </array></dict></plist>
        """
        let attached = try XCTUnwrap(
            DiskImageAttachOutput.parse(attachPlist: Data(plist.utf8)))
        XCTAssertEqual(attached.mountPoint, "/Volumes/Foo")
    }

    func testNilWhenNothingIsMountable() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>system-entities</key><array>
          <dict><key>dev-entry</key><string>/dev/disk9</string></dict>
        </array></dict></plist>
        """
        XCTAssertNil(DiskImageAttachOutput.parse(attachPlist: Data(plist.utf8)))
    }

    func testNilOnGarbage() {
        XCTAssertNil(DiskImageAttachOutput.parse(attachPlist: Data("not a plist".utf8)))
        XCTAssertNil(DiskImageAttachOutput.parse(attachPlist: Data()))
    }

    // MARK: - Manifest payload

    func testPayloadDecodesWithDefaults() throws {
        let manifest = try Manifest.decode(Data("""
        {"packageKey": "chrome", "payload": {"file": "payload/GoogleChrome.dmg"}}
        """.utf8))
        let payload = try XCTUnwrap(manifest.payload)

        XCTAssertEqual(payload.file, "payload/GoogleChrome.dmg")
        XCTAssertEqual(payload.installLocation, "/Applications")
        XCTAssertNil(payload.bundleName)
    }

    func testPayloadAcceptsExplicitBundleNameAndLocation() throws {
        let manifest = try Manifest.decode(Data("""
        {
          "packageKey": "x",
          "payload": {
            "file": "payload/suite.dmg",
            "bundleName": "Outil.app",
            "installLocation": "/Applications/Utilities"
          }
        }
        """.utf8))
        let payload = try XCTUnwrap(manifest.payload)

        XCTAssertEqual(payload.bundleName, "Outil.app")
        XCTAssertEqual(payload.installLocation, "/Applications/Utilities")
    }

    func testPayloadRequiresAFile() {
        XCTAssertThrowsError(
            try Manifest.decode(Data(#"{"packageKey": "x", "payload": {}}"#.utf8)))
    }

    /// The payload obeys the same confinement as the hooks: a manifest can only point
    /// at what was shipped with it.
    func testPayloadPathIsConfinedToManifestDirectory() {
        let root = "/Library/Application Support/CoreUpdate/Deploy/manifests/chrome"

        XCTAssertEqual(
            PathSafety.confine("payload/GoogleChrome.dmg", within: root),
            root + "/payload/GoogleChrome.dmg")
        XCTAssertNil(PathSafety.confine("../../evil.dmg", within: root))
        XCTAssertNil(PathSafety.confine("/tmp/evil.dmg", within: root))
        XCTAssertNil(PathSafety.confine("/Library/Application Support/CoreUpdate/Deploy/manifests/chrome-evil/x.dmg",
                                        within: root))
    }
}
