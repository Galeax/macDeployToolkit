import Foundation

// The manifest is JSON, read through `LenientContainer`: keys are accepted in
// camelCase as well as PascalCase, and the genuinely different names used by
// Veille's `macadt_config.json` (`AppName`, `AppVersion`, `AppVendor`,
// `ProcessesToClose`, `IgnoreExitCodes`, `LogName`) are accepted as explicit
// aliases.
//
// Rationale: Galeax packagers already write these files for Windows. Imposing a
// second vocabulary for macOS would add a mental translation to every
// round-trip, for no benefit.
//
// Codable note: Swift does not fill in default values when a key is absent. Every
// `init(from:)` is therefore explicit, which also keeps a minimal manifest valid.

public enum DeploymentMode: String, Codable, Sendable {
    /// Dialogs allowed. The normal mode for a "required" Intune deployment on a
    /// device with a logged-in user.
    case interactive
    /// No UI of any kind. Closes by force if policy allows.
    case silent
    /// No gate dialog — nobody is consulted — but progress and the completion
    /// message are shown. Closes by force like `silent`: between the two modes the
    /// difference is visibility, not power.
    case nonInteractive

    /// Accepts the PSADT values (`Interactive`, `Silent`, `NonInteractive`, `Auto`).
    ///
    /// `Auto` is treated as `interactive`: the engine already switches by itself
    /// when no user is logged in, which is exactly what PSADT means by "Auto".
    public init?(lenient raw: String) {
        switch LenientContainer.normalize(raw) {
        case "interactive", "auto": self = .interactive
        case "silent":              self = .silent
        case "noninteractive":      self = .nonInteractive
        default:                    return nil
        }
    }

    /// Does this mode show the non-blocking notifications — the progress dialog
    /// and the completion message?
    ///
    /// They ask nothing and wait for no response: their only purpose is that an
    /// application closed by force does not vanish without explanation. That is
    /// what separates `nonInteractive` from `silent`.
    public var presentsNotifications: Bool { self != .silent }
}

public enum DeploymentAction: String, Codable, Sendable {
    case install
    case uninstall
    /// There is no equivalent of the MSI repair on macOS. Defined here as
    /// "uninstall preserving configuration, then reinstall".
    case repair

    public init?(lenient raw: String) {
        switch LenientContainer.normalize(raw) {
        case "install":   self = .install
        case "uninstall": self = .uninstall
        case "repair":    self = .repair
        default:          return nil
        }
    }
}

/// An application whose presence blocks the deployment.
///
/// `bundleIdentifier` and `executableName` are both optional, but at least one of
/// the two must be present. This is not permissiveness: Veille's Windows catalog
/// describes its 247 blocking applications by process name, not by bundle
/// identifier, and refusing that form would make the conversion impossible.
///
/// An entry may have only an executable name (the case of a Windows
/// `ProcessesToClose`): detection and the `SIGKILL` by PID work in both cases,
/// the `bundleIdentifier` serving mainly for more reliable targeting.
public struct BlockingAppSpec: Codable, Equatable, Sendable {

    /// Reliable identification key, preferred over the executable name for
    /// targeting the processes to close.
    public var bundleIdentifier: String?

    /// Executable name, searched for in the process path. A safety net for
    /// repackaged applications, and the only form available when the declaration
    /// comes from a Windows `ProcessesToClose`.
    public var executableName: String?

    /// Label shown to the user.
    public var displayName: String

    public init(bundleIdentifier: String? = nil, displayName: String, executableName: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.executableName = executableName
        self.displayName = displayName
    }

    /// The most precise identifier available, for logs and reports. Decoding
    /// guarantees that at least one of the three fields is populated.
    public var identifier: String { bundleIdentifier ?? executableName ?? displayName }

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier, executableName, displayName
    }

    public init(from decoder: Decoder) throws {
        // Short form: a plain string. This is what reusing a Windows
        // `ProcessesToClose` produces. A dot in the string marks it as a bundle ID
        // (they always contain one), its absence as an executable name.
        if let single = try? decoder.singleValueContainer().decode(String.self) {
            let trimmed = single.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                throw ManifestError.malformed("empty blocking application")
            }
            if trimmed.contains(".") {
                bundleIdentifier = trimmed
                executableName = nil
                displayName = String(trimmed.split(separator: ".").last ?? Substring(trimmed))
            } else {
                bundleIdentifier = nil
                executableName = trimmed
                displayName = trimmed
            }
            return
        }

        let container = try LenientContainer(decoder)
        bundleIdentifier = try container.decode(
            String.self, "bundleIdentifier", "bundleId", "primaryBundleId")
        executableName = try container.decode(
            String.self, "executableName", "process", "processName")

        guard bundleIdentifier != nil || executableName != nil else {
            throw ManifestError.malformed(
                "a blocking application must declare bundleIdentifier or executableName")
        }

        if let provided = try container.decode(String.self, "displayName", "name") {
            displayName = provided
        } else if let identifier = bundleIdentifier {
            displayName = String(identifier.split(separator: ".").last ?? Substring(identifier))
        } else {
            displayName = executableName!
        }
    }
}

/// Deferral policy. Mirrors the parameters of `Show-ADTInstallationWelcome`.
public struct DeferralPolicy: Codable, Equatable, Sendable {

    public var allowDeferral: Bool

    /// PSADT: `-DeferTimes`.
    public var maxDeferrals: Int

    /// Sliding window in days since the **first** prompt (PSADT `-DeferDays`).
    ///
    /// Computed in seconds (`days × 86400`) rather than in calendar days:
    /// deterministic, insensitive to time zone and DST, and sufficient for a
    /// deployment window.
    public var deferralDays: Int?

    /// Absolute deadline in ISO 8601 (PSADT `-DeferDeadline`).
    public var deadline: Date?

    /// Countdown of the final warning, during install.
    ///
    /// 300 s, the value PSADT `-ForceCountdown 300` uses on the 269 production
    /// applications of the Veille catalog. The previous value of 900 s was an
    /// estimate; this one is measured in the field.
    public var countdownSeconds: Int

    /// Countdown during uninstall and repair.
    ///
    /// 60 s, the value of `-CloseProcessesCountdown 60` on the Veille side. Shorter
    /// than during install, and rightly so: an uninstall is explicitly requested,
    /// it surprises no one.
    public var uninstallCountdownSeconds: Int

    /// Interval at which an ignored dialog is shown again (PSADT `-PersistPrompt`).
    /// `nil` disables persistence.
    ///
    /// Without it, a dialog pushed behind a video-call window is never seen, and
    /// the forced close that follows seems to arrive without warning.
    public var persistPromptSeconds: Int?

    /// Maximum lifetime of a deferrable dialog.
    ///
    /// Deliberately capped below the Intune agent timeout: a dialog killed by the
    /// agent yields no usable outcome. Beyond it, we return `.abandoned` and the
    /// deferral is consumed cleanly.
    public var maxDialogSeconds: Int

    /// Close by force (SIGKILL) when there is no deferral left.
    public var forceCloseWhenExhausted: Bool

    public init(
        allowDeferral: Bool = true,
        maxDeferrals: Int = 3,
        deferralDays: Int? = nil,
        deadline: Date? = nil,
        countdownSeconds: Int = 300,
        uninstallCountdownSeconds: Int = 60,
        persistPromptSeconds: Int? = 60,
        maxDialogSeconds: Int = 1_200,
        forceCloseWhenExhausted: Bool = true
    ) {
        self.allowDeferral = allowDeferral
        self.maxDeferrals = maxDeferrals
        self.deferralDays = deferralDays
        self.deadline = deadline
        self.countdownSeconds = countdownSeconds
        self.uninstallCountdownSeconds = uninstallCountdownSeconds
        self.persistPromptSeconds = persistPromptSeconds
        self.maxDialogSeconds = maxDialogSeconds
        self.forceCloseWhenExhausted = forceCloseWhenExhausted
    }

    /// Countdown applicable to a given action.
    public func countdown(for action: DeploymentAction) -> Int {
        switch action {
        case .install:              return countdownSeconds
        case .uninstall, .repair:   return uninstallCountdownSeconds
        }
    }

    private enum CodingKeys: String, CodingKey {
        case allowDeferral, maxDeferrals, deferralDays, deadline
        case countdownSeconds, uninstallCountdownSeconds
        case persistPromptSeconds, maxDialogSeconds, forceCloseWhenExhausted
    }

    public init(from decoder: Decoder) throws {
        let c = try LenientContainer(decoder)
        allowDeferral = try c.decode(Bool.self, "allowDeferral", "allowDefer") ?? true
        maxDeferrals = try c.decode(Int.self, "maxDeferrals", "deferTimes") ?? 3
        deferralDays = try c.decode(Int.self, "deferralDays", "deferDays")
        deadline = try c.decode(Date.self, "deadline", "deferDeadline")
        countdownSeconds = try c.decode(
            Int.self, "countdownSeconds", "forceCountdown") ?? 300
        uninstallCountdownSeconds = try c.decode(
            Int.self, "uninstallCountdownSeconds", "closeProcessesCountdown") ?? 60
        // A key present at `0` disables persistence, which is different from an
        // absent key (which takes the default of 60 s).
        if let persist = try c.decode(Int.self, "persistPromptSeconds", "persistPrompt") {
            persistPromptSeconds = persist > 0 ? persist : nil
        } else {
            persistPromptSeconds = 60
        }
        maxDialogSeconds = try c.decode(
            Int.self, "maxDialogSeconds", "installationUITimeout") ?? 1_200
        forceCloseWhenExhausted = try c.decode(Bool.self, "forceCloseWhenExhausted") ?? true
    }
}

/// Requirements evaluated before disturbing the user at all.
public struct Requirements: Codable, Equatable, Sendable {

    public var minimumFreeBytes: Int64?
    public var minimumOSVersion: String?

    /// Do not disturb: defers if a `PreventUserIdleDisplaySleep` PM assertion is
    /// active — which is what video calls and full-screen presentations hold.
    /// Equivalent to PSADT's presentation mode.
    public var respectPresentationMode: Bool

    /// Defers if the session is locked, rather than closing applications while the
    /// user is away and cannot weigh in.
    public var respectScreenLock: Bool

    public init(
        minimumFreeBytes: Int64? = nil,
        minimumOSVersion: String? = nil,
        respectPresentationMode: Bool = true,
        respectScreenLock: Bool = true
    ) {
        self.minimumFreeBytes = minimumFreeBytes
        self.minimumOSVersion = minimumOSVersion
        self.respectPresentationMode = respectPresentationMode
        self.respectScreenLock = respectScreenLock
    }

    private enum CodingKeys: String, CodingKey {
        case minimumFreeBytes, minimumOSVersion, respectPresentationMode, respectScreenLock
    }

    public init(from decoder: Decoder) throws {
        let c = try LenientContainer(decoder)
        minimumFreeBytes = try c.decode(Int64.self, "minimumFreeBytes", "requiredDiskSpace")
        minimumOSVersion = try c.decode(String.self, "minimumOSVersion")
        respectPresentationMode = try c.decode(Bool.self, "respectPresentationMode") ?? true
        respectScreenLock = try c.decode(Bool.self, "respectScreenLock") ?? true
    }
}

/// How to tell that a version is already installed.
public struct DetectionSpec: Codable, Equatable, Sendable {

    /// Bundle path, e.g. `/Applications/Slack.app`. The version read is
    /// `CFBundleShortVersionString`.
    public var bundlePath: String?

    /// Version expected after installation. An installed version greater than or
    /// equal to it is considered satisfactory.
    public var expectedVersion: String?

    /// pkg receipt, checked via `pkgutil --pkg-info`.
    public var packageIdentifier: String?

    public init(
        bundlePath: String? = nil,
        expectedVersion: String? = nil,
        packageIdentifier: String? = nil
    ) {
        self.bundlePath = bundlePath
        self.expectedVersion = expectedVersion
        self.packageIdentifier = packageIdentifier
    }

    private enum CodingKeys: String, CodingKey {
        case bundlePath, expectedVersion, packageIdentifier
    }

    public init(from decoder: Decoder) throws {
        let c = try LenientContainer(decoder)
        bundlePath = try c.decode(String.self, "bundlePath")
        expectedVersion = try c.decode(String.self, "expectedVersion")
        packageIdentifier = try c.decode(
            String.self, "packageIdentifier", "primaryBundleId", "registryName")
    }
}

/// Uninstall. This is the area where the tool brings the most, since Intune
/// uninstall on macOS can do next to nothing.
public struct UninstallSpec: Codable, Equatable, Sendable {

    /// Receipts to process via `pkgutil --files` then `pkgutil --forget`.
    public var packageIdentifiers: [String]

    /// Paths to delete explicitly.
    public var paths: [String]

    /// launchd labels to unload via `launchctl bootout` BEFORE deletion: removing
    /// the plist of a loaded service leaves an orphaned daemon.
    public var launchdLabels: [String]

    /// Paths never to delete. This is exactly what distinguishes `repair`
    /// (preserves configuration) from `uninstall` (removes everything).
    public var preservedPaths: [String]

    public init(
        packageIdentifiers: [String] = [],
        paths: [String] = [],
        launchdLabels: [String] = [],
        preservedPaths: [String] = []
    ) {
        self.packageIdentifiers = packageIdentifiers
        self.paths = paths
        self.launchdLabels = launchdLabels
        self.preservedPaths = preservedPaths
    }

    private enum CodingKeys: String, CodingKey {
        case packageIdentifiers, paths, launchdLabels, preservedPaths
    }

    public init(from decoder: Decoder) throws {
        let c = try LenientContainer(decoder)
        packageIdentifiers = try c.decode([String].self, "packageIdentifiers") ?? []
        paths = try c.decode([String].self, "paths") ?? []
        launchdLabels = try c.decode([String].self, "launchdLabels") ?? []
        preservedPaths = try c.decode([String].self, "preservedPaths") ?? []
    }
}

/// Payload shipped with the manifest, and installed by `macadt-deploy install`.
///
/// This is the transposition of the `Files/` of a PSADT workspace: Intune never
/// deploys the vendor's installer, it deploys our wrapper, which contains it. The
/// vendor's DMG therefore travels as-is in the pkg payload, and is mounted only on
/// the device — the build host never needs `hdiutil`.
public struct PayloadSpec: Codable, Equatable, Sendable {

    /// File to install, **relative to the manifest directory** and confined within
    /// it, exactly like the hooks. A manifest can only point to what was shipped
    /// with it, never to `/tmp/payload.dmg`.
    public var file: String

    /// Destination of the copied bundles. Ignored for a `.pkg`, which
    /// `installer(8)` places according to its own declaration.
    public var installLocation: String

    /// Name of the bundle to keep when the image contains several. Without it, an
    /// ambiguous image fails the installation rather than choosing at random.
    public var bundleName: String?

    public init(file: String, installLocation: String = "/Applications", bundleName: String? = nil) {
        self.file = file
        self.installLocation = installLocation
        self.bundleName = bundleName
    }

    private enum CodingKeys: String, CodingKey {
        case file, installLocation, bundleName
    }

    public init(from decoder: Decoder) throws {
        let c = try LenientContainer(decoder)
        file = try c.require(String.self, "file", "fileName")
        installLocation = try c.decode(String.self, "installLocation") ?? "/Applications"
        bundleName = try c.decode(String.self, "bundleName")
    }
}

/// Displayed text, by language. `{name}`, `{version}`, `{apps}`, `{deferrals}`
/// and `{deadline}` are substituted at display time.
public struct LocalizedStrings: Codable, Equatable, Sendable {
    public var title: String
    public var closeAppsBody: String
    public var deferButton: String
    public var closeButton: String
    public var finalWarningBody: String
    public var progressTitle: String
    public var restartBody: String
    /// Installation completion message, the equivalent of PSADT's
    /// `Show-ADTInstallationPrompt` in `-NoWait`.
    public var completionBody: String

    /// Gate body used when `showDialogWhenNotRunning` is on and NO application is
    /// running: an install notice, with no "closing" language and no `{apps}` list
    /// (there is nothing to close).
    public var installNoticeBody: String

    /// Label under the countdown bar. `{remaining}` is substituted every second by
    /// the helper with the time left ("45 s", "4:05").
    public var countdownText: String

    public init(
        title: String,
        closeAppsBody: String,
        deferButton: String,
        closeButton: String,
        finalWarningBody: String,
        progressTitle: String,
        restartBody: String,
        completionBody: String = "L'installation de **{name}** est terminée.",
        installNoticeBody: String = "**{name}** {version} va être installé.",
        countdownText: String = "Démarrage automatique dans {remaining}"
    ) {
        self.title = title
        self.closeAppsBody = closeAppsBody
        self.deferButton = deferButton
        self.closeButton = closeButton
        self.finalWarningBody = finalWarningBody
        self.progressTitle = progressTitle
        self.restartBody = restartBody
        self.completionBody = completionBody
        self.installNoticeBody = installNoticeBody
        self.countdownText = countdownText
    }

    /// Fallback values, as pure literals so they depend on no other static
    /// initialization.
    public static let fallback = LocalizedStrings(
        title: "Software update",
        closeAppsBody: "Installing **{name}** requires closing:\n\n{apps}",
        deferButton: "Defer ({deferrals} left)",
        closeButton: "Close and install",
        finalWarningBody: "**{name}** must be installed now:\n\n{apps}",
        progressTitle: "Installing {name}",
        restartBody: "**{name}** has been installed. A restart is required.",
        completionBody: "**{name}** has been installed.",
        installNoticeBody: "**{name}** {version} will be installed.",
        countdownText: "Starts automatically in {remaining}")

    private enum CodingKeys: String, CodingKey {
        case title, closeAppsBody, deferButton, closeButton
        case finalWarningBody, progressTitle, restartBody, completionBody, installNoticeBody, countdownText
    }

    /// Lenient decoding, each absent key falling back to the fallback.
    ///
    /// Without it, any manifest overriding one language would have to supply all
    /// eight texts, and adding a ninth would retroactively break every manifest in
    /// the fleet. A partial override is the normal case.
    public init(from decoder: Decoder) throws {
        let c = try LenientContainer(decoder)
        let base = LocalizedStrings.fallback
        title = try c.decode(String.self, "title") ?? base.title
        closeAppsBody = try c.decode(String.self, "closeAppsBody") ?? base.closeAppsBody
        deferButton = try c.decode(String.self, "deferButton") ?? base.deferButton
        closeButton = try c.decode(String.self, "closeButton") ?? base.closeButton
        finalWarningBody = try c.decode(String.self, "finalWarningBody") ?? base.finalWarningBody
        progressTitle = try c.decode(String.self, "progressTitle") ?? base.progressTitle
        restartBody = try c.decode(String.self, "restartBody") ?? base.restartBody
        completionBody = try c.decode(String.self, "completionBody") ?? base.completionBody
        installNoticeBody = try c.decode(String.self, "installNoticeBody") ?? base.installNoticeBody
        countdownText = try c.decode(String.self, "countdownText") ?? base.countdownText
    }
}

public struct Messages: Codable, Equatable, Sendable {

    /// Key = ISO language code ("fr", "en"). "en" serves as the mandatory fallback.
    public var strings: [String: LocalizedStrings]

    public init(strings: [String: LocalizedStrings] = Messages.builtIn) {
        self.strings = strings
    }

    public init(from decoder: Decoder) throws {
        // A manifest may supply only one language, or none: we merge over the
        // built-in texts rather than replacing them.
        let container = try LenientContainer(decoder)
        let provided = try container.decode([String: LocalizedStrings].self, "strings") ?? [:]
        strings = Messages.builtIn.merging(provided) { _, override in override }
    }

    private enum CodingKeys: String, CodingKey { case strings }

    public static let builtIn: [String: LocalizedStrings] = [
        "fr": LocalizedStrings(
            title: "Mise à jour logicielle",
            closeAppsBody: "L'installation de **{name}** nécessite la fermeture de :\n\n{apps}\n\nEnregistrez votre travail avant de continuer.",
            deferButton: "Reporter ({deferrals} restants)",
            closeButton: "Fermer et installer",
            finalWarningBody: "**{name}** doit être installé maintenant. Les applications suivantes vont être fermées :\n\n{apps}\n\nEnregistrez votre travail immédiatement.",
            progressTitle: "Installation de {name} en cours",
            restartBody: "L'installation de **{name}** est terminée. Un redémarrage est nécessaire.",
            completionBody: "**{name}** {version} est installé.",
            installNoticeBody: "**{name}** {version} va être installé.",
            countdownText: "Démarrage automatique dans {remaining}"
        ),
        "en": LocalizedStrings(
            title: "Software update",
            closeAppsBody: "Installing **{name}** requires closing:\n\n{apps}\n\nPlease save your work before continuing.",
            deferButton: "Defer ({deferrals} left)",
            closeButton: "Close and install",
            finalWarningBody: "**{name}** must be installed now. The following applications will be closed:\n\n{apps}\n\nSave your work immediately.",
            progressTitle: "Installing {name}",
            restartBody: "**{name}** has been installed. A restart is required.",
            completionBody: "**{name}** {version} has been installed.",
            installNoticeBody: "**{name}** {version} will be installed.",
            countdownText: "Starts automatically in {remaining}"
        ),
    ]

    /// Resolution with fallback: exact language, then English, then whatever
    /// language is available. Cannot fail.
    public func resolve(for languageCode: String) -> LocalizedStrings {
        let base = String(languageCode.prefix(2)).lowercased()
        if let exact = strings[base] { return exact }
        if let english = strings["en"] { return english }
        if let any = strings.sorted(by: { $0.key < $1.key }).first?.value { return any }
        return Messages.builtIn["en"]!
    }
}

public enum ManifestError: Error, CustomStringConvertible {
    case unreadable(path: String, underlying: String)
    case malformed(String)
    case unsupportedSchema(found: Int, supported: Int)
    case missingUninstallSpec

    public var description: String {
        switch self {
        case .unreadable(let path, let underlying):
            return "unreadable manifest (\(path)): \(underlying)"
        case .malformed(let detail):
            return "malformed manifest: \(detail)"
        case .unsupportedSchema(let found, let supported):
            return "schemaVersion \(found) not supported (expected <= \(supported))"
        case .missingUninstallSpec:
            return "uninstall/repair action requested without an `uninstall` block in the manifest"
        }
    }
}

public struct Manifest: Codable, Equatable, Sendable {

    public static let currentSchemaVersion = 1

    public var schemaVersion: Int

    /// Stable identifier of the deployment, and key of the state store: it is what
    /// carries the deferral counter. Changing it resets the deferrals — so we
    /// bump it deliberately for a new campaign, and leave it fixed for a manifest
    /// fix.
    ///
    /// Required, and deliberately not derived from `displayName`: an automatic
    /// derivation would mean that a simple display rename would give every user in
    /// the fleet their deferrals back.
    public var packageKey: String

    public var displayName: String
    public var version: String

    /// Publisher. Present on the 264 Windows apps of the Veille catalog, so carried
    /// over here so that the conversion is lossless.
    public var publisher: String?

    /// Name of the log file specific to this deployment, in addition to the global
    /// log.
    public var logName: String?

    public var action: DeploymentAction
    public var mode: DeploymentMode

    /// Whether the mode's UI still engages when NO blocking application is running.
    ///
    /// `true` (the default, baked in here): an `interactive` deployment shows its
    /// gate even on a device where nothing is open — a courtesy install notice with
    /// a countdown, no application to close. `silent` and `nonInteractive` carry no
    /// gate, so this changes nothing for them.
    ///
    /// `false`: the historical behavior — with nothing running, install straight
    /// away, no dialog.
    ///
    /// Like `mode`, it is only a default: the deployment's `--show-when-not-running`
    /// wins, so it can be flipped in the generated post-install without a rebuild.
    public var showDialogWhenNotRunning: Bool

    /// Icon shown in the dialogs, passed verbatim to swiftDialog's `--icon`: a file
    /// path, an app bundle (`/Applications/Google Chrome.app`), an SF Symbol
    /// (`SF=arrow.down.circle`), a URL, or one of its built-ins. `nil` suppresses the
    /// icon (swiftDialog's oversized default would distort the compact dialog).
    public var icon: String?

    public var blockingApps: [BlockingAppSpec]
    public var deferral: DeferralPolicy
    public var requirements: Requirements
    public var detection: DetectionSpec?
    public var uninstall: UninstallSpec?
    public var hooks: HookSpec?
    public var payload: PayloadSpec?
    public var messages: Messages

    /// Exit codes to treat as successes.
    ///
    /// Applies to hook scripts and to the `installer` invocations we make
    /// ourselves. Carried over from `IgnoreExitCodes` / `SkipExitCodes` on the
    /// Veille side, where 4 applications need it.
    public var ignoredExitCodes: [Int32]

    /// System action required after installation, declared by the packager.
    ///
    /// Necessary because Intune installs the pkg itself: our pre/post scripts do
    /// not receive the package path and so cannot query
    /// `installer -query RestartAction`. When the path is known, `--package`
    /// allows querying it and takes precedence over this declaration.
    public var restartAction: RestartAction?

    public init(
        schemaVersion: Int = Manifest.currentSchemaVersion,
        packageKey: String,
        displayName: String,
        version: String,
        publisher: String? = nil,
        logName: String? = nil,
        action: DeploymentAction = .install,
        mode: DeploymentMode = .interactive,
        showDialogWhenNotRunning: Bool = true,
        icon: String? = nil,
        blockingApps: [BlockingAppSpec] = [],
        deferral: DeferralPolicy = DeferralPolicy(),
        requirements: Requirements = Requirements(),
        detection: DetectionSpec? = nil,
        uninstall: UninstallSpec? = nil,
        hooks: HookSpec? = nil,
        payload: PayloadSpec? = nil,
        messages: Messages = Messages(),
        ignoredExitCodes: [Int32] = [],
        restartAction: RestartAction? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.packageKey = packageKey
        self.displayName = displayName
        self.version = version
        self.publisher = publisher
        self.logName = logName
        self.action = action
        self.mode = mode
        self.showDialogWhenNotRunning = showDialogWhenNotRunning
        self.icon = icon
        self.blockingApps = blockingApps
        self.deferral = deferral
        self.requirements = requirements
        self.detection = detection
        self.uninstall = uninstall
        self.hooks = hooks
        self.payload = payload
        self.messages = messages
        self.ignoredExitCodes = ignoredExitCodes
        self.restartAction = restartAction
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, packageKey, displayName, version, publisher, logName
        case action, mode, showDialogWhenNotRunning, icon, blockingApps, deferral, requirements
        case detection, uninstall, hooks, payload, messages, ignoredExitCodes, restartAction
    }

    public init(from decoder: Decoder) throws {
        let c = try LenientContainer(decoder)

        schemaVersion = try c.decode(Int.self, "schemaVersion") ?? Manifest.currentSchemaVersion
        packageKey = try c.require(String.self, "packageKey", "registryName")
        displayName = try c.decode(String.self, "displayName", "appName") ?? packageKey
        version = try c.decode(String.self, "version", "appVersion") ?? "0"
        publisher = try c.decode(String.self, "publisher", "appVendor")
        logName = try c.decode(String.self, "logName")

        if let raw = try c.decode(String.self, "action", "deploymentType") {
            guard let parsed = DeploymentAction(lenient: raw) else {
                throw ManifestError.malformed("unknown action: \(raw)")
            }
            action = parsed
        } else {
            action = .install
        }

        if let raw = try c.decode(String.self, "mode", "deployMode") {
            guard let parsed = DeploymentMode(lenient: raw) else {
                throw ManifestError.malformed("unknown mode: \(raw)")
            }
            mode = parsed
        } else {
            mode = .interactive
        }

        // Baked-in default: show even when nothing is running. Absent key → true.
        showDialogWhenNotRunning = try c.decode(
            Bool.self, "showDialogWhenNotRunning", "showWhenNotRunning") ?? true

        icon = try c.decode(String.self, "icon", "iconPath")

        blockingApps = try c.decode(
            [BlockingAppSpec].self,
            "blockingApps", "closeApps", "processesToClose", "appProcessesToClose") ?? []
        deferral = try c.decode(DeferralPolicy.self, "deferral") ?? DeferralPolicy()
        requirements = try c.decode(Requirements.self, "requirements") ?? Requirements()
        detection = try c.decode(DetectionSpec.self, "detection")
        uninstall = try c.decode(UninstallSpec.self, "uninstall")
        hooks = try c.decode(HookSpec.self, "hooks")
        payload = try c.decode(PayloadSpec.self, "payload")
        messages = try c.decode(Messages.self, "messages") ?? Messages()
        ignoredExitCodes = try c.decode(
            [Int32].self, "ignoredExitCodes", "ignoreExitCodes", "skipExitCodes") ?? []
        restartAction = try c.decode(RestartAction.self, "restartAction")
    }

    /// Decoder configured for manifests. `.iso8601` requires a deadline of the form
    /// `2026-09-01T18:00:00Z`, with no time-zone ambiguity.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func load(contentsOf url: URL) throws -> Manifest {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ManifestError.unreadable(path: url.path, underlying: error.localizedDescription)
        }
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> Manifest {
        let manifest: Manifest
        do {
            manifest = try makeDecoder().decode(Manifest.self, from: data)
        } catch let error as ManifestError {
            throw error
        } catch {
            throw ManifestError.malformed(String(describing: error))
        }
        try manifest.validate()
        return manifest
    }

    public func validate() throws {
        guard schemaVersion <= Manifest.currentSchemaVersion else {
            throw ManifestError.unsupportedSchema(
                found: schemaVersion, supported: Manifest.currentSchemaVersion)
        }
        guard !packageKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ManifestError.malformed("empty packageKey")
        }
        if action != .install && uninstall == nil {
            throw ManifestError.missingUninstallSpec
        }
    }

    /// Applies the command-line overrides.
    ///
    /// Precedence order, from weakest to strongest:
    ///   manifest  →  subcommand  →  explicit flag
    ///
    /// The subcommand deliberately takes precedence over the manifest for the
    /// action: running `macadt-deploy uninstall` on a manifest declaring
    /// `action: install` would otherwise use the install countdown (300 s) instead
    /// of the uninstall one (60 s), and the divergence would be silent.
    public func applying(_ options: CommandLineOptions) throws -> Manifest {
        var updated = self
        if let mode = options.modeOverride { updated.mode = mode }
        if let show = options.showWhenNotRunningOverride { updated.showDialogWhenNotRunning = show }
        if let implied = options.command.impliedAction { updated.action = implied }
        if let action = options.actionOverride { updated.action = action }
        try updated.validate()
        return updated
    }
}
