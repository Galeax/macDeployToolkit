// NOT VERIFIED BY LINUX CI — this file only compiles on macOS.
//
// The area where the tool adds the most: Intune uninstall on macOS can do almost
// nothing. All the decision logic — which paths are deletable — lives in
// `MDTKit.UninstallPlanner` and is tested. This file only executes an
// already-validated plan.

#if canImport(Darwin)
import Foundation
import MDTKit

public struct UninstallOutcome: Sendable {
    public var removed: [String] = []
    public var failures: [String] = []
    public var unloadedLabels: [String] = []
    public var forgottenReceipts: [String] = []

    public var isClean: Bool { failures.isEmpty }
}

public enum Uninstaller {

    /// List of files for each receipt, via `pkgutil --files`.
    ///
    /// An unknown receipt is not an error: the package may have been uninstalled
    /// by hand, or never have been installed on this device.
    public static func receiptFiles(
        for identifiers: [String],
        logger: DeployLogging
    ) -> [String: [String]] {
        var files: [String: [String]] = [:]
        for identifier in identifiers {
            guard let result = try? ProcessRunner.run(
                    "/usr/sbin/pkgutil", ["--files", identifier], timeout: 120)
            else {
                logger.warning("pkgutil unreachable for \(identifier)")
                continue
            }
            guard result.succeeded else {
                logger.info("receipt \(identifier) absent from this device, ignored")
                continue
            }
            files[identifier] = result.outputLines
            logger.debug("receipt \(identifier): \(result.outputLines.count) entries")
        }
        return files
    }

    /// Executes a plan.
    ///
    /// The order of the three steps is non-negotiable:
    ///  1. unload the launchd services — removing the plist of a still-loaded
    ///     service leaves an orphaned daemon in memory, which can recreate the
    ///     files we are about to delete;
    ///  2. delete the files;
    ///  3. forget the receipts last — forgetting them first would make the file
    ///     list unrecoverable if the deletion fails partway through.
    public static func execute(
        _ plan: UninstallPlan,
        dryRun: Bool,
        logger: DeployLogging
    ) -> UninstallOutcome {

        var outcome = UninstallOutcome()

        for warning in plan.warnings { logger.warning(warning) }
        for rejection in plan.rejections {
            logger.info("path discarded (\(rejection.reason.rawValue)): \(rejection.path)")
        }

        for label in plan.launchdLabels {
            if dryRun {
                logger.notice("[dry-run] launchctl bootout \(label)")
                outcome.unloadedLabels.append(label)
                continue
            }
            if unload(label: label, logger: logger) {
                outcome.unloadedLabels.append(label)
            }
        }

        for path in plan.deletions {
            if dryRun {
                logger.notice("[dry-run] deletion of \(path)")
                outcome.removed.append(path)
                continue
            }
            guard FileManager.default.fileExists(atPath: path) else {
                logger.debug("already absent: \(path)")
                continue
            }
            do {
                try FileManager.default.removeItem(atPath: path)
                logger.notice("deleted: \(path)")
                outcome.removed.append(path)
            } catch {
                let message = "unable to delete \(path): \(error.localizedDescription)"
                logger.error(message)
                outcome.failures.append(message)
            }
        }

        for identifier in plan.receiptsToForget {
            if dryRun {
                logger.notice("[dry-run] pkgutil --forget \(identifier)")
                outcome.forgottenReceipts.append(identifier)
                continue
            }
            guard let result = try? ProcessRunner.run(
                    "/usr/sbin/pkgutil", ["--forget", identifier], timeout: 60)
            else { continue }
            if result.succeeded {
                logger.info("receipt forgotten: \(identifier)")
                outcome.forgottenReceipts.append(identifier)
            } else {
                // An already-absent receipt makes pkgutil exit with an error: this
                // is not an uninstall failure.
                logger.debug("pkgutil --forget \(identifier): \(result.standardError)")
            }
        }

        return outcome
    }

    /// Unloads a launchd service.
    ///
    /// Two domains to try, because the label alone does not say whether it is a
    /// daemon or an agent: `system/` for LaunchDaemons, `gui/<uid>/` for the
    /// current session's LaunchAgents. A failure on both most often means the
    /// service was not loaded, which is inconsequential.
    private static func unload(label: String, logger: DeployLogging) -> Bool {
        var domains = ["system/\(label)"]
        if let user = SessionInspector.consoleUser() {
            domains.append("gui/\(user.uid)/\(label)")
        }
        for domain in domains {
            if let result = try? ProcessRunner.run(
                "/bin/launchctl", ["bootout", domain], timeout: 60), result.succeeded {
                logger.info("service unloaded: \(domain)")
                return true
            }
        }
        logger.debug("\(label) was not loaded in any known domain")
        return false
    }
}
#endif
