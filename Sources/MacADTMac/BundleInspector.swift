// NOT VERIFIED BY LINUX CI — this file only compiles on macOS.

#if canImport(Darwin)
import Foundation
import MacADTKit

/// Reads the version of an installed bundle, for detection.
public enum BundleInspector {

    /// Version presented by a bundle.
    ///
    /// `CFBundleShortVersionString` first, `CFBundleVersion` as fallback.
    /// The reverse would be a mistake: `CFBundleVersion` is a build number,
    /// often monotonic but unrelated to the displayed version, and the manifest
    /// declares the version the admin sees in "About".
    public static func version(atBundlePath path: String) -> BundleVersion? {
        guard let plist = infoPlist(atBundlePath: path) else { return nil }
        if let short = plist["CFBundleShortVersionString"] as? String, !short.isEmpty {
            return BundleVersion(short)
        }
        if let build = plist["CFBundleVersion"] as? String, !build.isEmpty {
            return BundleVersion(build)
        }
        return nil
    }

    public static func bundleIdentifier(atBundlePath path: String) -> String? {
        infoPlist(atBundlePath: path)?["CFBundleIdentifier"] as? String
    }

    public static func exists(atBundlePath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    private static func infoPlist(atBundlePath path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path + "/Contents/Info.plist"),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return plist
    }

    /// Is the payload declared by the manifest already in place?
    ///
    /// `>=` comparison, not `==`: if the device carries a version newer than the
    /// manifest's, reinstalling would be a regression. This is the real scenario
    /// of a user who updated the application themselves.
    public static func isSatisfied(_ detection: DetectionSpec) -> Bool {
        if let bundlePath = detection.bundlePath {
            guard exists(atBundlePath: bundlePath) else { return false }
            guard let expected = detection.expectedVersion else { return true }
            guard let installed = version(atBundlePath: bundlePath) else { return false }
            return installed >= BundleVersion(expected)
        }

        // No bundle to inspect: detection by receipt. This is the only recourse
        // for a package that does not install an application — driver, system
        // extension, VPN agent. Without it, `detection.packageIdentifier` would be
        // a promise of the format that nothing would honour.
        if let identifier = detection.packageIdentifier {
            guard let installed = receiptVersion(forPackageIdentifier: identifier) else {
                return false
            }
            guard let expected = detection.expectedVersion else { return true }
            return installed >= BundleVersion(expected)
        }
        return false
    }

    /// Version recorded for a receipt, via `pkgutil --pkg-info-plist`.
    ///
    /// The `-plist` variant rather than the text output: `pkgutil --pkg-info`
    /// returns `key: value` pairs whose format is not contractual, the plist
    /// output is.
    public static func receiptVersion(forPackageIdentifier identifier: String) -> BundleVersion? {
        guard let result = try? ProcessRunner.run(
                "/usr/sbin/pkgutil", ["--pkg-info-plist", identifier], timeout: 60),
              result.succeeded,
              let plist = try? PropertyListSerialization.propertyList(
                  from: Data(result.standardOutput.utf8), options: [], format: nil)
                  as? [String: Any],
              let version = plist["pkg-version"] as? String,
              !version.isEmpty
        else { return nil }
        return BundleVersion(version)
    }
}
#endif
