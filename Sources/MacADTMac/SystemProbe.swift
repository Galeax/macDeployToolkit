// NOT VERIFIED BY LINUX CI — this file only compiles on macOS.

#if canImport(Darwin)
import Foundation
import MacADTKit

/// Assembles the `DeploymentContext` consumed by the decision engine.
///
/// This is the project's boundary: above it, everything is tested; below it,
/// everything is an Apple system call. We keep this layer as thin as possible —
/// it collects, it does not decide.
public enum SystemProbe {

    public static func context(for manifest: Manifest, logger: DeployLogging) -> DeploymentContext {
        let consoleUser = SessionInspector.consoleUser()
        let running = ProcessScanner.running(from: manifest.blockingApps)

        if let consoleUser {
            logger.debug("console session: \(consoleUser.username) (uid \(consoleUser.uid))")
        } else {
            logger.debug("no usable console session")
        }
        if !running.isEmpty {
            logger.info("blocking apps running: "
                + running.map(\.displayName).joined(separator: ", "))
        }

        return DeploymentContext(
            runningBlockingApps: running,
            hasConsoleUser: consoleUser != nil,
            isScreenLocked: SessionInspector.isScreenLocked(),
            isPresenting: SessionInspector.isPresenting(),
            freeBytes: freeBytes(atPath: "/"),
            osVersion: osVersion())
    }

    /// Available space.
    ///
    /// `volumeAvailableCapacityForImportantUsageKey` and not the raw capacity:
    /// on APFS, the raw capacity ignores the space the system can reclaim by
    /// purging snapshots and caches. This is the value `installer` will actually
    /// see, and the gap between the two is measured in tens of GB.
    public static func freeBytes(atPath path: String) -> Int64? {
        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            return Int64(capacity)
        }
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
           let free = attributes[.systemFreeSize] as? NSNumber {
            return free.int64Value
        }
        return nil
    }

    public static func osVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    public static func isRunningAsRoot() -> Bool { getuid() == 0 }

    /// Real user home directories, to resolve the `~` of an uninstall plan.
    ///
    /// Filters on `/Users/` and excludes `Shared`: `dscl` also lists system
    /// accounts, whose homes point to `/var/empty` — including them would send
    /// out-of-scope paths to the planner, which would reject them, but polluting
    /// the rejection report.
    public static func userHomeDirectories() -> [String] {
        guard let result = try? ProcessRunner.run(
                "/usr/bin/dscl", [".", "-list", "/Users", "NFSHomeDirectory"], timeout: 20),
              result.succeeded
        else { return [] }

        var homes: [String] = []
        for line in result.outputLines {
            // Format: "<name><spaces></home/path>"
            guard let range = line.range(of: " ", options: .backwards) else { continue }
            let home = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard home.hasPrefix("/Users/"), home != "/Users/Shared" else { continue }
            homes.append(home)
        }
        return homes.sorted()
    }

    /// Preferred language of the logged-in user, to choose the dialog language.
    /// Read from their preferences domain, not root's: root is in English on
    /// just about every device.
    public static func consoleUserLanguage() -> String {
        guard let user = SessionInspector.consoleUser() else { return "en" }
        guard let result = try? ProcessRunner.run(
                "/usr/bin/sudo",
                ["-u", user.username, "/usr/bin/defaults", "read", "-g", "AppleLocale"],
                timeout: 10),
              result.succeeded,
              let locale = result.outputLines.first
        else { return "en" }
        return String(locale.prefix(2)).lowercased()
    }
}
#endif
