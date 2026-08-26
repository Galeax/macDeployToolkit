import Foundation

// Disk-image handling, on the decision side.
//
// The mounting itself lives in MDTMac: it calls `hdiutil`. But everything that
// amounts to *deciding* — what the mount point is, what the image contains, what to
// do with it — is pure computation, so it is tested here.
//
// It is this split that makes the "Intune deploys our wrapper" model viable: the
// vendor's DMG travels as-is in the pkg payload, without ever being mounted on the
// build host, and is opened only on the device where `hdiutil` is native.

/// What a mounted disk image contains that is installable.
public enum DiskImageContent: Equatable, Sendable {
    /// An `.app` bundle to copy to `installLocation`.
    case applicationBundle(String)
    /// A `.pkg` or `.mpkg` to delegate to `installer(8)`.
    case package(String)
    /// Several candidates and no way to decide: the manifest must designate which
    /// one via `payload.bundleName`.
    case ambiguous([String])
    case empty
}

public enum DiskImageInspector {

    /// Entries to ignore in a mounted image.
    ///
    /// `Applications` is the convenience symlink that almost every drag-and-drop DMG
    /// ships: taking it for an install target would copy `/Applications` into itself.
    private static let ignoredNames: Set<String> = [
        "Applications", "Applications alias", ".background", ".DS_Store",
        ".fseventsd", ".Trashes", ".VolumeIcon.icns", "Desktop DB", "Desktop DF",
    ]

    /// Classifies the content of an image from the list of its root entries.
    ///
    /// - Parameter preferredName: name declared by `payload.bundleName`, which
    ///   decides images containing several candidates.
    public static func classify(
        entries: [String],
        preferredName: String? = nil
    ) -> DiskImageContent {

        let visible = entries
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(".") && !ignoredNames.contains($0) }

        if let preferredName, visible.contains(preferredName) {
            return kind(of: preferredName) ?? .ambiguous(visible.sorted())
        }

        let packages = visible.filter { $0.hasSuffix(".pkg") || $0.hasSuffix(".mpkg") }
        let bundles = visible.filter { $0.hasSuffix(".app") }

        // A package takes precedence over a bundle: when an image contains both, the
        // `.pkg` is the real installer and the `.app` is often only an uninstall
        // assistant or a documentation shortcut.
        if packages.count == 1 { return .package(packages[0]) }
        if packages.count > 1 { return .ambiguous(packages.sorted()) }
        if bundles.count == 1 { return .applicationBundle(bundles[0]) }
        if bundles.count > 1 { return .ambiguous(bundles.sorted()) }
        return .empty
    }

    private static func kind(of name: String) -> DiskImageContent? {
        if name.hasSuffix(".pkg") || name.hasSuffix(".mpkg") { return .package(name) }
        if name.hasSuffix(".app") { return .applicationBundle(name) }
        return nil
    }
}

/// Usable result of an `hdiutil attach -plist`.
public struct AttachedDiskImage: Equatable, Sendable {
    public let mountPoint: String

    /// `/dev` entry to unmount. The whole disk, not the partition: unmounting
    /// `/dev/disk4s1` leaves `/dev/disk4` attached, and the image stays locked for
    /// the next run.
    public let devEntry: String

    public init(mountPoint: String, devEntry: String) {
        self.mountPoint = mountPoint
        self.devEntry = devEntry
    }
}

public enum DiskImageAttachOutput {

    /// Extracts the mount point and the `/dev` entry to unmount.
    ///
    /// `hdiutil attach -plist` returns a `system-entities` dictionary of which
    /// **not all** entries are mountable: a typical image exposes the whole disk, a
    /// protection partition, and finally the HFS/APFS volume that carries the
    /// `mount-point`. We therefore look for the first entry that has one.
    public static func parse(attachPlist data: Data) -> AttachedDiskImage? {
        guard let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else { return nil }

        var mountPoint: String?
        var devEntries: [String] = []

        for entity in entities {
            if let dev = entity["dev-entry"] as? String, !dev.isEmpty {
                devEntries.append(dev)
            }
            if mountPoint == nil,
               let point = entity["mount-point"] as? String,
               !point.trimmingCharacters(in: .whitespaces).isEmpty {
                mountPoint = point
            }
        }

        guard let mountPoint else { return nil }

        // The whole disk is the shortest `/dev` entry: `/dev/disk4` precedes
        // `/dev/disk4s1`. Failing a `/dev` entry, we will unmount by mount point,
        // which also works but sometimes leaves the disk attached.
        let whole = devEntries.min { $0.count < $1.count } ?? mountPoint
        return AttachedDiskImage(mountPoint: mountPoint, devEntry: whole)
    }
}
