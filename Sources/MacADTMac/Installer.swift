// NOT VERIFIED BY LINUX CI — this file only compiles on macOS.

#if canImport(Darwin)
import Foundation
import MacADTKit

public enum InstallError: Error, CustomStringConvertible {
    case unsupportedPayload(extension: String)
    case installerFailed(exitCode: Int32, detail: String)
    case copyFailed(detail: String)

    public var description: String {
        switch self {
        case .unsupportedPayload(let ext):
            return "unsupported payload: .\(ext) (expected dmg, pkg, mpkg or app)"
        case .installerFailed(let code, let detail):
            return "installer failed (code \(code)): \(detail)"
        case .copyFailed(let detail):
            return "unable to copy the bundle: \(detail)"
        }
    }
}

public enum Installer {

    /// Queries the `RestartAction` declared in the package's Distribution.
    ///
    /// Do this BEFORE installation: afterwards, the information is no longer as
    /// easily accessible. This is the only reliable way to know that a pkg
    /// requires a restart — there is nothing to guess after the fact.
    public static func restartAction(
        forPackagePath path: String,
        logger: DeployLogging
    ) -> RestartAction {
        guard FileManager.default.fileExists(atPath: path) else {
            logger.warning("package not found for the RestartAction query: \(path)")
            return .none
        }
        guard let result = try? ProcessRunner.run(
                "/usr/sbin/installer",
                ["-query", "RestartAction", "-pkg", path, "-target", "/"],
                timeout: 60)
        else {
            logger.warning("RestartAction query failed on \(path)")
            return .none
        }
        let action = RestartAction.parse(result.standardOutput)
        logger.info("RestartAction of \(BundlePath.lastComponent(path)): \(action.rawValue)")
        return action
    }

    /// Installs a package. Useful for `repair` and for non-Intune use — in the
    /// normal Intune flow, Intune is the one that installs and our scripts only
    /// wrap the operation.
    public static func install(
        packagePath: String,
        timeout: TimeInterval = 3_600,
        logger: DeployLogging
    ) throws -> ProcessResult {
        logger.notice("installing \(BundlePath.lastComponent(packagePath))")
        let result = try ProcessRunner.run(
            "/usr/sbin/installer", ["-pkg", packagePath, "-target", "/"], timeout: timeout)
        if !result.succeeded {
            logger.error("installer failed (code \(result.exitCode)): \(result.standardError)")
        }
        return result
    }

    /// Copies a bundle to its destination, cleanly replacing the existing one.
    ///
    /// `ditto` and not `cp`: it preserves ACLs, extended attributes and the
    /// bundle's internal hard links. A `cp -R` breaks embedded frameworks whose
    /// structure relies on relative symbolic links.
    ///
    /// The replacement goes through a swap, not an overwrite: `ditto` onto an
    /// existing destination MERGES the trees, which leaves behind files from the
    /// old version that the new one no longer has. An application with leftovers
    /// from the previous version fails signature verification, and the symptom
    /// looks nothing like the cause.
    public static func copyApplication(
        from source: String,
        to installLocation: String,
        logger: DeployLogging,
        dryRun: Bool = false,
        progress: ((Double) -> Void)? = nil
    ) throws -> String {

        let name = BundlePath.lastComponent(source)
        let destination = "\(installLocation)/\(name)"

        if dryRun {
            logger.notice("[dry-run] copy of \(source) to \(destination)")
            return destination
        }

        let manager = FileManager.default
        try manager.createDirectory(
            atPath: installLocation, withIntermediateDirectories: true)

        let staged = "\(installLocation)/.\(name).macadt-new"
        let previous = "\(installLocation)/.\(name).macadt-old"
        try? manager.removeItem(atPath: staged)
        try? manager.removeItem(atPath: previous)

        // `ditto` says nothing while it works, so progress is the size of what has
        // landed against the size of the source, sampled once a second.
        let watcher = progress.map {
            CopyProgressWatcher(source: source, destination: staged, report: $0)
        }
        watcher?.start()
        defer { watcher?.stop() }

        let copy = try ProcessRunner.run(
            "/usr/bin/ditto", ["--rsrc", "--extattr", source, staged], timeout: 1_800)
        watcher?.stop()
        guard copy.succeeded else {
            try? manager.removeItem(atPath: staged)
            throw InstallError.copyFailed(
                detail: copy.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let hadPrevious = manager.fileExists(atPath: destination)
        if hadPrevious {
            try manager.moveItem(atPath: destination, toPath: previous)
        }
        do {
            try manager.moveItem(atPath: staged, toPath: destination)
        } catch {
            // The swap failed: we put the old version back rather than leaving the
            // device with no application at all.
            if hadPrevious { try? manager.moveItem(atPath: previous, toPath: destination) }
            try? manager.removeItem(atPath: staged)
            throw error
        }
        if hadPrevious { try? manager.removeItem(atPath: previous) }

        progress?(1)
        logger.notice("installed: \(destination)")
        return destination
    }

    /// Post-installation hardening. Returns the list of anomalies found — never
    /// fatal, but all to be reported.
    ///
    /// The three operations are in this order for a reason:
    ///  1. remove the quarantine, otherwise the first open triggers the Gatekeeper
    ///     warning for the user;
    ///  2. verify the signature, to detect a corrupted or substituted payload
    ///     before it is used;
    ///  3. reset the owner to `root:wheel` and remove write access for group and
    ///     others — a bundle writable by the user in `/Applications` is a local
    ///     privilege escalation.
    public static func harden(
        bundlePath: String,
        logger: DeployLogging,
        dryRun: Bool = false
    ) -> [String] {

        var anomalies: [String] = []
        guard FileManager.default.fileExists(atPath: bundlePath) else {
            return ["bundle missing after installation: \(bundlePath)"]
        }
        if dryRun {
            logger.info("[dry-run] hardening of \(bundlePath) not executed")
            return []
        }

        // `xattr -d` exits with an error when the attribute is absent, which is the
        // normal case for a package installed by `installer`. So we ignore the
        // return code instead of treating it as a failure.
        _ = try? ProcessRunner.run(
            "/usr/bin/xattr", ["-dr", "com.apple.quarantine", bundlePath], timeout: 120)

        // Files copied out of a mounted disk image carry a `com.apple.FinderInfo`
        // attribute (seen on Chrome's DMG, macOS 26). It is not part of the
        // signature, but `codesign --strict` rejects it as "detritus" — on the
        // vendor's own image as much as on our copy — so the check below would cry
        // wolf on every install. Same tolerance for an absent attribute.
        _ = try? ProcessRunner.run(
            "/usr/bin/xattr", ["-dr", "com.apple.FinderInfo", bundlePath], timeout: 120)

        if let signature = try? ProcessRunner.run(
            "/usr/bin/codesign", ["--verify", "--deep", "--strict", bundlePath], timeout: 300),
           !signature.succeeded {
            let detail = signature.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            anomalies.append("invalid signature on \(bundlePath): \(detail)")
            logger.error("codesign rejected \(bundlePath): \(detail)")
        }

        // Only for system-wide bundles: rewriting the owner of a bundle installed
        // in a user home would make it unusable by its owner.
        if bundlePath.hasPrefix("/Applications/") {
            if let owner = try? ProcessRunner.run(
                "/usr/sbin/chown", ["-R", "root:wheel", bundlePath], timeout: 300),
               !owner.succeeded {
                anomalies.append("chown failed on \(bundlePath)")
            }
            if let mode = try? ProcessRunner.run(
                "/bin/chmod", ["-R", "go-w", bundlePath], timeout: 300),
               !mode.succeeded {
                anomalies.append("chmod failed on \(bundlePath)")
            }
        }

        return anomalies
    }
}

/// Samples a copy in progress: bytes on disk at the destination over bytes at the
/// source. Approximate — `du` counts allocated blocks — and capped below 100 %:
/// only the caller knows when the copy is really over.
private final class CopyProgressWatcher: @unchecked Sendable {

    private let source: String
    private let destination: String
    private let report: (Double) -> Void
    private let queue = DispatchQueue(label: "com.macadt.deploy.copy-progress")
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var total: Int64 = 0

    init(source: String, destination: String, report: @escaping (Double) -> Void) {
        self.source = source
        self.destination = destination
        self.report = report
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler { [weak self] in self?.sample() }
        lock.lock(); self.timer = timer; lock.unlock()
        timer.resume()
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        timer?.cancel()
        timer = nil
    }

    private func sample() {
        if total == 0 { total = CopyProgressWatcher.kilobytes(at: source) }
        guard total > 0 else { return }
        let done = CopyProgressWatcher.kilobytes(at: destination)
        lock.lock(); let running = timer != nil; lock.unlock()
        if running { report(min(0.99, Double(done) / Double(total))) }
    }

    private static func kilobytes(at path: String) -> Int64 {
        guard let result = try? ProcessRunner.run("/usr/bin/du", ["-sk", path], timeout: 60),
              let field = result.standardOutput.split(whereSeparator: { $0 == "\t" || $0 == " " }).first
        else { return 0 }
        return Int64(field) ?? 0
    }
}
#endif
