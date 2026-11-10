// NOT VERIFIED BY LINUX CI — this file only compiles on macOS.
//
// Orchestration. Contains no decision rule: everything that decides lives in
// MacADTKit and is tested. Here we chain side effects in the right order.

#if canImport(Darwin)
import Foundation
import MacADTKit

public struct DeploymentRunner {

    private let options: CommandLineOptions
    private let logger: DeployLogging
    private let store: StateStoring
    private let engine = DeferralEngine()
    private let planner = UninstallPlanner()
    private let helperPath: String

    public init(
        options: CommandLineOptions,
        logger: DeployLogging,
        store: StateStoring,
        helperPath: String? = nil
    ) {
        self.options = options
        self.logger = logger
        self.store = store
        self.helperPath = helperPath ?? Self.siblingHelperPath()
    }

    /// The helper is looked for next to the agent before the default path: both
    /// binaries are shipped in the same pkg, and a relocated installation must
    /// keep working.
    private static func siblingHelperPath() -> String {
        let sibling = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .deletingLastPathComponent()
            .appendingPathComponent("macadt-deploy-ui").path
        return FileManager.default.isExecutableFile(atPath: sibling)
            ? sibling : HelperBridge.defaultHelperPath
    }

    // MARK: - Dispatch

    public func run() -> ExitCode {
        switch options.command {
        case .help:
            print(CommandLineOptions.usage)
            return .success
        case .version:
            print("macadt-deploy \(MacAppDeployToolkit.version)")
            return .success
        case .status:
            return runStatus()
        case .reset:
            return runReset()
        case .pre, .post, .install, .uninstall, .repair:
            return runManifestCommand()
        }
    }

    private func runManifestCommand() -> ExitCode {
        guard let path = options.manifestPath else { return .invalidManifest }

        let manifest: Manifest
        do {
            // Command-line overrides are applied here, once, so that everything
            // that follows reasons over an effective manifest.
            manifest = try Manifest.load(contentsOf: URL(fileURLWithPath: path))
                .applying(options)
        } catch {
            logger.error("\(error)")
            return .invalidManifest
        }

        // Root required, except in `--dry-run`: this is precisely what allows a
        // full scenario to be replayed without privileges.
        //
        // This check comes BEFORE opening the application log: without root,
        // `/var/log/MacADT` is not creatable and the log would emit an open
        // warning just before the privileges error. Two messages for a single
        // cause, the first of which misleads.
        if !options.dryRun && !SystemProbe.isRunningAsRoot() {
            logger.error("macadt-deploy must run as root (Intune agent context)")
            return .privilegesRequired
        }

        attachApplicationLog(for: manifest)

        if let mode = options.modeOverride {
            logger.info("mode overridden on the command line: \(mode.rawValue)")
        }

        let vendor = manifest.publisher.map { " — \($0)" } ?? ""
        logger.notice("=== \(options.command.rawValue) \(manifest.displayName) "
            + "\(manifest.version)\(vendor) (\(manifest.packageKey)) ===")

        switch options.command {
        case .pre:       return runPre(manifest)
        case .post:      return runPost(manifest)
        case .install:   return runInstall(manifest)
        case .uninstall: return runUninstall(manifest, preserveConfiguration: false)
        case .repair:    return runUninstall(manifest, preserveConfiguration: true)
        default:         return .failure
        }
    }

    // MARK: - Gate on blocking apps

    /// Shared by `pre`, `uninstall` and `repair`: evaluate, prompt, close.
    ///
    /// `exit == nil` means the way is clear. In `--dry-run`, no dialog is
    /// presented and no application closed, but the dialog is built so it appears
    /// in the report.
    private func gate(
        _ manifest: Manifest,
        state: inout DeploymentState,
        now: Date
    ) -> (exit: ExitCode?, dialog: DialogSpec?, context: DeploymentContext) {

        let context = SystemProbe.context(for: manifest, logger: logger)
        let language = options.language ?? SystemProbe.consoleUserLanguage()

        var decision = engine.evaluate(
            manifest: manifest, state: state, context: context, now: now)

        if options.force, case .prompt = decision {
            logger.warning("--force: deferral counter ignored, closing without a dialog")
            decision = .forceClose(
                apps: context.runningBlockingApps, trigger: .deferralDisabled)
        }

        logger.info("decision: \(decision.label)" + (decision.detail.map { " — \($0)" } ?? ""))

        // Outcomes with no follow-up: the exit code is already determined.
        if let immediate = decision.immediateExitCode {
            if case .requirementFailed(let reason) = decision { logger.error(reason) }
            return (immediate == .success ? nil : immediate, nil, context)
        }

        switch decision {
        case .forceClose(let apps, _):
            if options.dryRun { return (nil, nil, context) }
            let code = closeApps(apps)
            return (code == .success ? nil : code, nil, context)

        case .prompt(let request):
            let dialog = DialogSpec.closeApps(
                manifest: manifest, request: request,
                languageCode: language, timeZone: .current)

            if options.dryRun { return (nil, dialog, context) }

            state = engine.markPrompted(state, now: now)
            try? store.save(state)

            let outcome: DialogOutcome
            do {
                let response = try sendToHelper(.showDialog(dialog))
                guard case .dialogOutcome(let value) = response else {
                    logger.error("unexpected helper response: \(response)")
                    return (.failure, dialog, context)
                }
                outcome = value
            } catch {
                // Cannot ask, and applications are open: we close nothing
                // silently. Intune will retry.
                logger.error("dialog not possible: \(error)")
                return (.blockedNoConsoleUser, dialog, context)
            }

            switch outcome {
            case .secondary:
                state = engine.recordDeferral(state, now: now)
                try? store.save(state)
                logger.notice("deferred by the user "
                    + "(\(state.deferralsUsed)/\(manifest.deferral.maxDeferrals))")
                return (.deferredByUser, dialog, context)

            case .primary, .timerExpired:
                if outcome == .timerExpired {
                    logger.notice("countdown expired, close initiated")
                }
                // The consent is persisted BEFORE the close: it is what will allow
                // `install` to re-close without re-prompting an application reopened
                // while Intune was dropping the payload.
                state = engine.recordConsent(state, now: now)
                try? store.save(state)
                let code = closeApps(request.apps)
                return (code == .success ? nil : code, dialog, context)

            case .userQuit, .abandoned:
                // `abandoned` = the presentation budget ran out despite the
                // re-shows. Nobody consented to anything: we consume a deferral
                // rather than close, exactly as for a dismissed dialog.
                let reason = outcome == .abandoned
                    ? "no response within the allotted time"
                    : "dialog dismissed"
                if request.canDefer {
                    state = engine.recordDeferral(state, now: now)
                    try? store.save(state)
                    logger.notice("\(reason), counted as a deferral")
                    return (.deferredByUser, dialog, context)
                }
                logger.warning("\(reason), with no deferral available")
                return (.blockedUserDismissed, dialog, context)

            case .unknown:
                logger.error("uninterpretable dialog outcome")
                return (.failure, dialog, context)
            }

        case .proceed, .retryLater, .requirementFailed:
            return (nil, nil, context)
        }
    }

    /// Closes the blocking apps via `SIGKILL`.
    ///
    /// A single mechanism: `kill(2)` on the PIDs found by libproc, agent-side. It
    /// depends on no session (it works in a daemon context as in a session) and
    /// requires no special authorization. This path is only reached once the close
    /// is already authorized: the user just clicked "Close and install", the
    /// countdown expired, or the deferral window is exhausted. The warning has
    /// therefore already been presented; no save is triggered, unsaved work is lost.
    private func closeApps(_ apps: [BlockingAppSpec]) -> ExitCode {
        guard !apps.isEmpty else { return .success }
        let result = ProcessScanner.forceKill(apps, logger: logger)
        return result.isComplete ? .success : .forceCloseFailed
    }

    /// Adds the per-application log, equivalent of PSADT's `LogName`.
    ///
    /// Cannot be opened at startup: its name comes from the manifest, read later.
    /// The global log keeps being fed in parallel — this one serves to follow a
    /// particular application without filtering.
    private func attachApplicationLog(for manifest: Manifest) {
        guard !options.dryRun, let attachable = logger as? AttachableLogging else { return }
        let path = LogPaths.path(for: manifest)
        attachable.attach(FileLogger(
            path: path,
            subject: "\(manifest.packageKey)/\(manifest.version)",
            minimumLevel: options.verbose ? .debug : .info))
        logger.debug("application log: \(path)")
    }

    /// Shows a progress dialog during `body`, equivalent of PSADT's
    /// `Show-ADTInstallationProgress`.
    ///
    /// Only possible in the wrapper model: when Intune installs the pkg itself, the
    /// installation happens between `pre` and `post` and none of our processes runs
    /// during it. It is because `post` mounts and copies itself that we finally
    /// have someone to hold the dialog.
    ///
    /// Any display failure is swallowed: a progress dialog that does not show must
    /// never make an installation fail.
    private func withProgress<T>(_ manifest: Manifest, _ body: (@escaping (Double) -> Void) -> T) -> T {
        guard manifest.mode.presentsNotifications,
              !options.dryRun,
              let user = SessionInspector.consoleUser()
        else { return body({ _ in }) }

        // The dialog runs as the user and (re)creates this file itself; we only
        // append to it — see `ProgressFeed` for why that is safe from root.
        let commandFile = "/tmp/macadt-progress-\(UUID().uuidString).cmd"
        let feed = ProgressFeed(path: commandFile, ownerUID: user.uid)
        defer { feed.remove() }

        let language = options.language ?? SystemProbe.consoleUserLanguage()
        let spec = DialogSpec.progress(
            manifest: manifest, languageCode: language, commandFile: commandFile)

        var pid: Int32?
        if let response = try? sendToHelper(.showDetached(spec)),
           case .detachedStarted(let started) = response {
            pid = started
        } else {
            logger.debug("progress dialog not shown, continuing")
        }

        defer {
            if let pid {
                _ = try? sendToHelper(.dismissDetached(pid: pid))
            }
        }
        return body({ fraction in feed.report(fraction) })
    }

    /// End-of-installation message, equivalent of PSADT's
    /// `Show-ADTInstallationPrompt` in `-NoWait`. Detached and carrying a timer:
    /// nobody will close it, and a dialog that stays on screen until the next
    /// restart is a nuisance.
    private func notifyCompletion(_ manifest: Manifest) {
        guard manifest.mode.presentsNotifications,
              !options.dryRun,
              SessionInspector.consoleUser() != nil
        else { return }

        let language = options.language ?? SystemProbe.consoleUserLanguage()
        let spec = DialogSpec.completion(manifest: manifest, languageCode: language)
        _ = try? sendToHelper(.showDetached(spec))
    }

    /// The manifest's directory: confinement root for hook scripts.
    private func manifestDirectory() -> String {
        guard let path = options.manifestPath else { return "/" }
        return URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    /// Runs a phase's hook. `nil` = continue.
    private func hook(_ phase: HookPhase, _ manifest: Manifest) -> ExitCode? {
        HookRunner.run(
            phase: phase, manifest: manifest,
            manifestDirectory: manifestDirectory(),
            dryRun: options.dryRun, logger: logger)
    }

    /// Single passage point to the helper.
    ///
    /// Centralizes `helperPath` and `dialogPath`: a direct call to
    /// `HelperBridge.send` would forget the second, and the helper would silently
    /// fall back to the default swiftDialog path.
    private func sendToHelper(_ request: UIRequest) throws -> UIResponse {
        try HelperBridge.send(
            request, helperPath: helperPath, dialogPath: options.dialogPath, logger: logger)
    }

    // MARK: - pre

    private func runPre(_ manifest: Manifest) -> ExitCode {
        var state = store.load(packageKey: manifest.packageKey)
        let now = Date()

        // Already in place: we exit before disturbing anyone. This check first
        // prevents an Intune re-run from re-showing a dialog for an installation
        // already done.
        if let detection = manifest.detection, BundleInspector.isSatisfied(detection) {
            logger.notice("\(manifest.displayName) \(manifest.version) already in place")
            return finish(.success, manifest: manifest, state: &state, now: now)
        }

        let (exit, dialog, context) = gate(manifest, state: &state, now: now)

        if options.dryRun {
            emit(DryRunReport(
                command: "pre", manifest: manifest, context: context,
                state: state, decision: engine.evaluate(
                    manifest: manifest, state: state, context: context, now: now),
                dialog: dialog))
            return .success
        }

        if let exit { return finish(exit, manifest: manifest, state: &state, now: now) }

        // The pre-install hook runs after the applications are closed and before
        // Intune installs: this is the only window where the device is in the state
        // the script expects.
        if let failure = hook(.preInstall, manifest) {
            return finish(failure, manifest: manifest, state: &state, now: now)
        }

        logger.notice("way clear, Intune can install")
        return finish(.success, manifest: manifest, state: &state, now: now)
    }

    // MARK: - post

    private func runPost(_ manifest: Manifest) -> ExitCode {
        var state = store.load(packageKey: manifest.packageKey)
        let now = Date()

        // When the manifest declares a payload, it is our wrapper that carries the
        // vendor's installer: it must be installed here, before hardening and
        // detection. Without a `payload` block, Intune has already installed the
        // pkg itself and we continue directly.
        if let failure = installPayload(manifest, state: &state, now: now) {
            return finish(failure, manifest: manifest, state: &state, now: now)
        }

        if let bundlePath = manifest.detection?.bundlePath {
            for anomaly in Installer.harden(
                bundlePath: bundlePath, logger: logger, dryRun: options.dryRun) {
                logger.warning(anomaly)
            }
            if let installed = BundleInspector.version(atBundlePath: bundlePath) {
                state.installedVersion = installed.raw
                logger.notice("version detected: \(installed.raw)")
            }
        }

        // An `installer` that returns 0 does not guarantee the payload is in place:
        // detection is the only verdict that counts.
        if let detection = manifest.detection, !BundleInspector.isSatisfied(detection) {
            logger.error("detection failed after installation: "
                + "\(manifest.displayName) \(manifest.version) absent or too old")
            return finish(.failure, manifest: manifest, state: &state, now: now)
        }

        if let failure = hook(.postInstall, manifest) {
            return finish(failure, manifest: manifest, state: &state, now: now)
        }

        let action = options.packagePath
            .map { Installer.restartAction(forPackagePath: $0, logger: logger) }
            ?? manifest.restartAction
            ?? .none

        if action.requiresUserAction && !options.dryRun {
            notifyRestart(manifest: manifest, action: action)
        } else {
            // Mutually exclusive: two dialogs back to back for the same
            // installation are a nuisance, and the restart notice already carries
            // the information that the installation succeeded.
            notifyCompletion(manifest)
        }
        return finish(action.exitCode, manifest: manifest, state: &state, now: now)
    }

    /// Restart notification, best-effort: its failure must never change the exit
    /// code of a successful installation.
    private func notifyRestart(manifest: Manifest, action: RestartAction) {
        guard SessionInspector.consoleUser() != nil else { return }
        let language = options.language ?? SystemProbe.consoleUserLanguage()
        let strings = manifest.messages.resolve(for: language)
        let dialog = DialogSpec(
            title: Template.render(strings.title, values: ["name": manifest.displayName]),
            message: Template.render(strings.restartBody, values: [
                "name": manifest.displayName, "version": manifest.version,
            ]),
            button1: "OK",
            timerSeconds: 300)
        do {
            _ = try sendToHelper(.showDialog(dialog))
        } catch {
            logger.warning("restart notification not shown: \(error)")
        }
    }

    // MARK: - install

    /// `install` is `post` with a mandatory payload. It used to stop right after the
    /// copy, which skipped everything `post` does next — and the standalone
    /// post-install script only ever calls `install`. The bundle was therefore left
    /// as copied from the vendor's disk image: still quarantined and owned by the
    /// image's build user, so it would not open (error -47 on Chrome), with no
    /// detection verdict, no post-install hook and no completion message.
    private func runInstall(_ manifest: Manifest) -> ExitCode {
        guard manifest.payload != nil else {
            logger.error("install command with no `payload` block in the manifest")
            return .invalidManifest
        }
        return runPost(manifest)
    }

    /// Installs the declared payload, if one exists.
    ///
    /// Shared between `install` and `post`: the post-install script generated for
    /// Intune always calls `post`, and it is solely the presence of a `payload`
    /// block in the manifest that decides whether there is something to install.
    /// A single template therefore covers both models — Intune installs the pkg
    /// itself, or our wrapper carries the vendor's DMG.
    ///
    /// - Returns: `nil` if all is well or if there is no payload.
    private func installPayload(
        _ manifest: Manifest,
        state: inout DeploymentState,
        now: Date
    ) -> ExitCode? {

        guard let payload = manifest.payload else { return nil }

        guard let payloadPath = PathSafety.confine(payload.file, within: manifestDirectory()) else {
            logger.error("payload outside the manifest's directory: \(payload.file)")
            return .invalidManifest
        }

        // Cross the window between `pre` and here. Intune dropped the payload in
        // between, and the user may have reopened their browser during those few
        // seconds.
        let context = SystemProbe.context(for: manifest, logger: logger)
        if engine.hasFreshConsent(state, now: now) {
            // The user already consented in a prior pass: never re-prompt. Just
            // re-close whatever reopened in the window since, if anything did.
            if !context.runningBlockingApps.isEmpty {
                let names = context.runningBlockingApps.map(\.displayName).joined(separator: ", ")
                logger.notice("recent consent: re-closing \(names) without a dialog")
                let code = closeApps(context.runningBlockingApps)
                guard code == .success else { return code }
            }
        } else {
            // No fresh consent: let the engine decide. It closes the running apps
            // after a dialog, shows the idle install notice when
            // `showDialogWhenNotRunning` is on, or simply proceeds when there is
            // nothing to do. This is the ONLY gate in the standalone model, whose
            // post-install calls `install` and never `pre` — so the decision for
            // "nothing running" has to be taken here too, not only in `pre`.
            logger.info("no recent consent, going through the full gate")
            let (exit, _, _) = gate(manifest, state: &state, now: now)
            if let exit { return exit }
        }

        if options.dryRun {
            logger.notice("[dry-run] would install \(payloadPath) to \(payload.installLocation)")
            return nil
        }

        // The progress dialog surrounds only the installation itself: it must not
        // overlap with the gate dialogs above.
        let failure: ExitCode? = withProgress(manifest) { progress in
            do {
                try performInstall(
                    payloadPath: payloadPath, payload: payload, manifest: manifest,
                    progress: progress)
                return nil
            } catch {
                logger.error("\(error)")
                return ExitCode.failure
            }
        }
        return failure
    }

    private func performInstall(
        payloadPath: String,
        payload: PayloadSpec,
        manifest: Manifest,
        progress: @escaping (Double) -> Void = { _ in }
    ) throws {

        switch (payloadPath as NSString).pathExtension.lowercased() {
        case "dmg":
            // `withMounted` unmounts whatever happens, including if the body throws:
            // an installation error must not leave an image attached, which would
            // make the next deployment of the same application fail.
            try DiskImageMounter.withMounted(payloadPath, logger: logger) { image in
                let entries = DiskImageMounter.entries(at: image.mountPoint)
                logger.debug("image contents: \(entries.joined(separator: ", "))")

                switch DiskImageInspector.classify(
                    entries: entries, preferredName: payload.bundleName) {
                case .applicationBundle(let name):
                    _ = try Installer.copyApplication(
                        from: "\(image.mountPoint)/\(name)",
                        to: payload.installLocation,
                        logger: logger,
                        progress: progress)
                case .package(let name):
                    try runPackageInstaller("\(image.mountPoint)/\(name)", manifest: manifest)
                case .ambiguous(let candidates):
                    throw DiskImageError.ambiguousContent(path: payloadPath, candidates: candidates)
                case .empty:
                    throw DiskImageError.emptyImage(path: payloadPath)
                }
            }

        case "pkg", "mpkg":
            try runPackageInstaller(payloadPath, manifest: manifest)

        case "app":
            _ = try Installer.copyApplication(
                from: payloadPath, to: payload.installLocation, logger: logger,
                progress: progress)

        case let other:
            throw InstallError.unsupportedPayload(extension: other)
        }
    }

    private func runPackageInstaller(_ path: String, manifest: Manifest) throws {
        let result = try Installer.install(packagePath: path, logger: logger)
        if result.succeeded { return }
        if manifest.ignoredExitCodes.contains(result.exitCode) {
            logger.notice("installer returned \(result.exitCode), ignored by ignoredExitCodes")
            return
        }
        throw InstallError.installerFailed(
            exitCode: result.exitCode,
            detail: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - uninstall / repair

    /// `preserveConfiguration` is the only difference between `repair` and
    /// `uninstall`: in `repair` the manifest's `preservedPaths` are honoured, in a
    /// full uninstall they are ignored.
    private func runUninstall(_ manifest: Manifest, preserveConfiguration: Bool) -> ExitCode {
        guard var spec = manifest.uninstall else {
            logger.error("\(ManifestError.missingUninstallSpec)")
            return .invalidManifest
        }
        if !preserveConfiguration && !spec.preservedPaths.isEmpty {
            logger.info("full uninstall: \(spec.preservedPaths.count) "
                + "preserved path(s) ignored")
            spec.preservedPaths = []
        }

        var state = store.load(packageKey: manifest.packageKey)
        let now = Date()

        // Close before deleting: erasing the bundle of a running application leaves
        // a live process without files, and a reinstall in that state fails in an
        // incomprehensible way.
        let (exit, dialog, context) = gate(manifest, state: &state, now: now)

        let receipts = options.dryRun
            ? [:]
            : Uninstaller.receiptFiles(for: spec.packageIdentifiers, logger: logger)
        let plan = planner.plan(
            spec: spec,
            receiptFiles: receipts,
            homeDirectories: SystemProbe.userHomeDirectories())

        if options.dryRun {
            emit(DryRunReport(
                command: options.command.rawValue, manifest: manifest, context: context,
                state: state, decision: engine.evaluate(
                    manifest: manifest, state: state, context: context, now: now),
                dialog: dialog, uninstallPlan: plan))
            return .success
        }

        if let exit { return finish(exit, manifest: manifest, state: &state, now: now) }

        if let failure = hook(.preUninstall, manifest) {
            return finish(failure, manifest: manifest, state: &state, now: now)
        }

        let outcome = Uninstaller.execute(plan, dryRun: false, logger: logger)
        logger.notice("uninstall: \(outcome.removed.count) deleted, "
            + "\(outcome.unloadedLabels.count) service(s) unloaded, "
            + "\(outcome.forgottenReceipts.count) receipt(s) forgotten")

        guard outcome.isClean else {
            for failure in outcome.failures { logger.error(failure) }
            return finish(.failure, manifest: manifest, state: &state, now: now)
        }

        // The post-uninstall hook only runs if the deletion succeeded: launching it
        // after a partial failure would make it operate on a state it does not
        // expect.
        if let failure = hook(.postUninstall, manifest) {
            return finish(failure, manifest: manifest, state: &state, now: now)
        }

        if preserveConfiguration {
            // In `repair`, the installation that follows is Intune's: we return
            // success so it takes place.
            logger.notice("repair: uninstall done, Intune installation to follow")
            state.installedVersion = nil
        } else {
            state.installedVersion = nil
        }
        return finish(.success, manifest: manifest, state: &state, now: now)
    }

    // MARK: - status / reset

    private func runStatus() -> ExitCode {
        let states: [DeploymentState]
        if let key = resolvedPackageKey() {
            states = [store.load(packageKey: key)]
        } else {
            states = store.allStates()
        }
        if options.json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(states),
               let text = String(data: data, encoding: .utf8) {
                print(text)
            }
        } else if states.isEmpty {
            print("no recorded deployment")
        } else {
            for state in states {
                print("\(state.packageKey): \(state.deferralsUsed) deferral(s)"
                    + (state.installedVersion.map { ", version \($0)" } ?? "")
                    + (state.lastOutcome.map { ", last outcome \($0)" } ?? ""))
            }
        }
        return .success
    }

    private func runReset() -> ExitCode {
        guard let key = resolvedPackageKey() else { return .invalidManifest }
        do {
            try store.reset(packageKey: key)
            logger.notice("deferral counter reset to zero: \(key)")
            return .success
        } catch {
            logger.error("reset failed: \(error.localizedDescription)")
            return .failure
        }
    }

    private func resolvedPackageKey() -> String? {
        if let key = options.packageKey { return key }
        guard let path = options.manifestPath,
              let manifest = try? Manifest.load(contentsOf: URL(fileURLWithPath: path))
        else { return nil }
        return manifest.packageKey
    }

    // MARK: - Outputs

    private func emit(_ report: DryRunReport) {
        print(options.json ? report.encodedJSON() : report.describe())
    }

    /// Stamps the state and logs the outcome. Going through here for every exit
    /// guarantees the state store always reflects the last run, which makes it the
    /// source of truth for reporting in place of the Intune dashboard.
    private func finish(
        _ code: ExitCode,
        manifest: Manifest,
        state: inout DeploymentState,
        now: Date
    ) -> ExitCode {
        state.lastOutcome = code.slug
        state.lastRunDate = now
        do {
            try store.save(state)
        } catch {
            logger.warning("state not persisted: \(error.localizedDescription)")
        }
        let level: LogLevel = code.isSuccess ? .notice : (code.isTransientBlock ? .notice : .error)
        logger.log(level, "outcome: \(code.slug) (code \(code.rawValue))")
        return code
    }
}
#endif
