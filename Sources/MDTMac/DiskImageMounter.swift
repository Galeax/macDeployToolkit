// NOT VERIFIED BY LINUX CI — this file only compiles on macOS.
//
// All the decision logic (mount point, content classification) lives in
// MDTKit.DiskImage and is tested. Here we only call `hdiutil`.

#if canImport(Darwin)
import Foundation
import MDTKit

public enum DiskImageError: Error, CustomStringConvertible {
    case attachFailed(path: String, detail: String)
    case noMountPoint(path: String)
    case ambiguousContent(path: String, candidates: [String])
    case emptyImage(path: String)

    public var description: String {
        switch self {
        case .attachFailed(let path, let detail):
            return "unable to mount \(path): \(detail)"
        case .noMountPoint(let path):
            return "no mountable volume in \(path)"
        case .ambiguousContent(let path, let candidates):
            return "ambiguous content in \(path): \(candidates.joined(separator: ", ")). "
                + "Declare payload.bundleName in the manifest."
        case .emptyImage(let path):
            return "\(path) contains neither a bundle nor an installable package"
        }
    }
}

public enum DiskImageMounter {

    /// Mounts an image and returns the mount point.
    ///
    /// Three options are non-negotiable:
    ///  - `-nobrowse`: the image must not appear in the user's Finder during a
    ///    silent deployment;
    ///  - `-mountrandom /private/tmp`: mounting under `/Volumes` would collide
    ///    with a volume of the same name already mounted by the user, and macOS
    ///    would rename ours to "Foo 1";
    ///  - `-readonly`: nothing must be able to modify the vendor's image.
    ///
    /// `-noverify` skips the checksum verification: it costs tens of seconds on a
    /// large image, and integrity is already guaranteed by the signature of the
    /// pkg that carries this image.
    ///
    /// The `Y\n` on stdin answers images that carry a software license agreement
    /// (SLA): without it, `hdiutil` waits for an acceptance that will never come
    /// and the script is killed by the Intune agent's timeout.
    public static func attach(_ path: String, logger: DeployLogging) throws -> AttachedDiskImage {
        guard FileManager.default.fileExists(atPath: path) else {
            throw DiskImageError.attachFailed(path: path, detail: "file not found")
        }

        let result: ProcessResult
        do {
            result = try ProcessRunner.run(
                "/usr/bin/hdiutil",
                ["attach", path, "-plist", "-nobrowse", "-noverify", "-readonly",
                 "-mountrandom", "/private/tmp"],
                input: Data("Y\n".utf8),
                timeout: 600)
        } catch {
            throw DiskImageError.attachFailed(path: path, detail: String(describing: error))
        }

        guard result.succeeded else {
            throw DiskImageError.attachFailed(
                path: path,
                detail: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let attached = DiskImageAttachOutput.parse(
                attachPlist: Data(result.standardOutput.utf8)) else {
            throw DiskImageError.noMountPoint(path: path)
        }

        logger.info("image mounted: \(attached.mountPoint) (\(attached.devEntry))")
        return attached
    }

    /// Unmounts, insistently.
    ///
    /// An unmount immediately after a copy regularly fails with "resource busy":
    /// `mds` is indexing the volume we just read. We retry, then force. A failed
    /// unmount leaves the image attached and makes the next deployment of the same
    /// application fail.
    @discardableResult
    public static func detach(_ image: AttachedDiskImage, logger: DeployLogging) -> Bool {
        for attempt in 1...3 {
            if let result = try? ProcessRunner.run(
                "/usr/bin/hdiutil", ["detach", image.devEntry], timeout: 120),
               result.succeeded {
                return true
            }
            logger.debug("unmounting \(image.devEntry): attempt \(attempt) without success")
            Thread.sleep(forTimeInterval: 2)
        }

        logger.warning("forced unmount of \(image.devEntry)")
        if let forced = try? ProcessRunner.run(
            "/usr/bin/hdiutil", ["detach", image.devEntry, "-force"], timeout: 120),
           forced.succeeded {
            return true
        }
        logger.error("\(image.devEntry) stays attached: the next deployment of this "
            + "application will fail until it is released")
        return false
    }

    public static func entries(at mountPoint: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: mountPoint)) ?? []
    }

    /// Mounts, runs the body, unmounts whatever happens — including if the body
    /// throws. This is the only way to guarantee that an installation error does
    /// not leave an image attached behind it.
    public static func withMounted<T>(
        _ path: String,
        logger: DeployLogging,
        _ body: (AttachedDiskImage) throws -> T
    ) throws -> T {
        let attached = try attach(path, logger: logger)
        defer { detach(attached, logger: logger) }
        return try body(attached)
    }
}
#endif
