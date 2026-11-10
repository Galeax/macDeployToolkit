// NOT VERIFIED BY LINUX CI — this file only compiles on macOS.
//
// The security decision (path confinement, owner, permissions) lives in
// MacADTKit.HookResolver and is tested. Here we only read the file's attributes and
// execute.

#if canImport(Darwin)
import Foundation
import MacADTKit

public enum HookRunner {

    /// A hook that does not return would block the deployment forever. 600 s
    /// leaves room for a legitimate script while staying under the Intune agent's
    /// timeout, which is the real bound.
    public static let timeoutSeconds: TimeInterval = 600

    /// Runs a phase's hook, if one is declared.
    ///
    /// - Returns: `nil` if all is well (hook absent, or finished with an accepted
    ///   code). Otherwise the exit code to report.
    public static func run(
        phase: HookPhase,
        manifest: Manifest,
        manifestDirectory: String,
        dryRun: Bool,
        logger: DeployLogging
    ) -> ExitCode? {

        guard let reference = manifest.hooks?.reference(for: phase) else { return nil }

        let path: String
        switch HookResolver.resolve(reference: reference, manifestDirectory: manifestDirectory) {
        case .success(let resolved):
            path = resolved
        case .failure(let rejection):
            logger.error("hook \(phase.rawValue) rejected (\(rejection.rawValue)): \(reference)")
            return .hookFailed
        }

        if let rejection = HookResolver.validate(securityAttributes(ofPath: path)) {
            logger.error("hook \(phase.rawValue) rejected (\(rejection.rawValue)): \(path)")
            // Explicit message: this is the most frequent packaging error, and a
            // packager who reads "notOwnedByRoot" with no more context loses an
            // hour.
            if rejection == .notOwnedByRoot || rejection == .writableByGroupOrOther {
                logger.error("fix with: chown root:wheel \(path) && chmod 755 \(path)")
            }
            return .hookFailed
        }

        if dryRun {
            logger.notice("[dry-run] hook \(phase.rawValue) not executed: \(path)")
            return nil
        }

        logger.notice("running hook \(phase.rawValue): \(path)")

        // Context passed through the environment rather than positional arguments:
        // a script can ignore what it doesn't care about, and adding a variable
        // breaks no existing hook.
        var environment = ProcessInfo.processInfo.environment
        environment["MACADT_PACKAGE_KEY"] = manifest.packageKey
        environment["MACADT_APP_NAME"] = manifest.displayName
        environment["MACADT_APP_VERSION"] = manifest.version
        environment["MACADT_ACTION"] = manifest.action.rawValue
        environment["MACADT_PHASE"] = phase.rawValue
        environment["MACADT_MANIFEST_DIR"] = manifestDirectory
        environment["MACADT_LOG"] = FileLogger.defaultPath
        if let bundlePath = manifest.detection?.bundlePath {
            environment["MACADT_BUNDLE_PATH"] = bundlePath
        }

        let result: ProcessResult
        do {
            result = try ProcessRunner.run(
                path, [], timeout: timeoutSeconds,
                environment: environment, currentDirectory: manifestDirectory)
        } catch {
            logger.error("hook \(phase.rawValue) not launchable: \(error)")
            return .hookFailed
        }

        for line in result.outputLines { logger.info("[\(phase.rawValue)] \(line)") }
        let errorText = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if !errorText.isEmpty { logger.warning("[\(phase.rawValue)] \(errorText)") }

        if result.timedOut {
            logger.error("hook \(phase.rawValue) killed after \(Int(timeoutSeconds)) s")
            return .hookFailed
        }
        if result.exitCode == 0 { return nil }
        if manifest.ignoredExitCodes.contains(result.exitCode) {
            logger.notice("hook \(phase.rawValue) returned \(result.exitCode), "
                + "ignored by ignoredExitCodes")
            return nil
        }
        logger.error("hook \(phase.rawValue) failed (code \(result.exitCode))")
        return .hookFailed
    }

    private static func securityAttributes(ofPath path: String) -> FileSecurityAttributes {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return FileSecurityAttributes(
                exists: false, isExecutable: false, ownerUID: 0, permissions: 0)
        }
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value ?? UInt32.max
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0

        // The execute bit is read from the mode rather than via
        // `isExecutableFile(atPath:)`: the latter answers "can the current process
        // execute this file", which is almost always true as root and would hide a
        // script without the x bit.
        return FileSecurityAttributes(
            exists: true,
            isExecutable: mode & 0o111 != 0,
            ownerUID: owner,
            permissions: mode)
    }
}
#endif
