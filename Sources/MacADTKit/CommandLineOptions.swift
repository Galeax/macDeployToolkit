import Foundation

public enum ArgumentError: Error, Equatable, CustomStringConvertible {
    case missingCommand
    case unknownCommand(String)
    case unknownFlag(String)
    case missingValue(flag: String)
    case invalidValue(flag: String, value: String)
    case manifestRequired(command: String)
    case targetRequired(command: String)

    public var description: String {
        switch self {
        case .missingCommand:
            return "no subcommand provided"
        case .unknownCommand(let name):
            return "unknown subcommand: \(name)"
        case .unknownFlag(let flag):
            return "unknown option: \(flag)"
        case .missingValue(let flag):
            return "option \(flag) expects a value"
        case .invalidValue(let flag, let value):
            return "invalid value for \(flag): \(value)"
        case .manifestRequired(let command):
            return "\(command) requires --manifest <path>"
        case .targetRequired(let command):
            return "\(command) requires --manifest <path> or --package-key <key>"
        }
    }
}

public struct CommandLineOptions: Equatable, Sendable {

    public enum Command: String, CaseIterable, Sendable {
        /// Intune pre-install: evaluates, prompts, closes. Does not do the
        /// installation, which `installer` handles on the Intune side.
        case pre
        /// Intune post-install: quarantine, signature check, RestartAction, state
        /// write.
        case post
        /// Installs the payload shipped with the manifest: mounts a DMG and copies
        /// the bundle, or delegates a pkg to `installer(8)`.
        ///
        /// This is the transposition of PSADT's `Files/`: Intune never deploys the
        /// vendor's installer, it deploys our wrapper, which contains it.
        case install
        case uninstall
        case repair
        /// Shows the deferral state of one or all deployments.
        case status
        /// Resets the deferral counter.
        case reset
        case version
        case help

        /// Action implied by the subcommand.
        ///
        /// The subcommand takes precedence over the manifest's `action`: running
        /// `macadt-deploy uninstall` on a manifest declaring `action: install` must use
        /// the uninstall countdown (60 s), not the install one (300 s). Without this,
        /// the divergence is silent.
        public var impliedAction: DeploymentAction? {
            switch self {
            case .install:      return .install
            case .uninstall:    return .uninstall
            case .repair:       return .repair
            case .pre, .post, .status, .reset, .version, .help: return nil
            }
        }
    }

    public var command: Command
    public var manifestPath: String?
    public var packageKey: String?

    /// Path of the `.pkg`, when known. Used only to query
    /// `installer -query RestartAction`, and then takes precedence over the
    /// `restartAction` declared in the manifest.
    public var packagePath: String?

    /// Runs no side effect: evaluates, prints the plan, exits. Works without root and
    /// without an installed manifest — this is the mode used to replay a full scenario
    /// off a Mac.
    public var dryRun: Bool

    public var verbose: Bool

    /// Machine-readable output on stdout. The logs stay on stderr, which keeps stdout
    /// pipe-able to `jq`.
    public var json: Bool

    public var logPath: String
    public var statePath: String
    public var dialogPath: String
    public var language: String?

    /// Overrides the deferral counter: forces immediate processing.
    public var force: Bool

    /// Overrides the manifest's `mode`.
    ///
    /// Necessary because MacADT lets the operator choose the `DeployMode` per
    /// deployment in its interface, exactly as it does for Windows via `-DeployMode`
    /// in the PSADT command line. Without this flag, that interface choice would have
    /// no way to reach the agent.
    public var modeOverride: DeploymentMode?

    /// Overrides the manifest's `showDialogWhenNotRunning`.
    ///
    /// Rendered into the generated post-install next to `--mode`, so an operator can
    /// force or disable the "show even when nothing is running" behavior per
    /// deployment, without rebuilding the pkg.
    public var showWhenNotRunningOverride: Bool?

    /// Overrides the action, itself already deduced from the subcommand.
    /// Exists for parity with `-DeploymentType` on the PSADT side.
    public var actionOverride: DeploymentAction?

    public init(
        command: Command,
        manifestPath: String? = nil,
        packageKey: String? = nil,
        packagePath: String? = nil,
        dryRun: Bool = false,
        verbose: Bool = false,
        json: Bool = false,
        logPath: String = FileLogger.defaultPath,
        statePath: String = PlistStateStore.defaultDirectory.path,
        dialogPath: String = CommandLineOptions.defaultDialogPath,
        language: String? = nil,
        force: Bool = false,
        modeOverride: DeploymentMode? = nil,
        showWhenNotRunningOverride: Bool? = nil,
        actionOverride: DeploymentAction? = nil
    ) {
        self.command = command
        self.manifestPath = manifestPath
        self.packageKey = packageKey
        self.packagePath = packagePath
        self.dryRun = dryRun
        self.verbose = verbose
        self.json = json
        self.logPath = logPath
        self.statePath = statePath
        self.dialogPath = dialogPath
        self.language = language
        self.force = force
        self.modeOverride = modeOverride
        self.showWhenNotRunningOverride = showWhenNotRunningOverride
        self.actionOverride = actionOverride
    }

    public static let defaultDialogPath = "/usr/local/bin/dialog"

    /// - Parameter arguments: arguments without the program name, i.e.
    ///   `Array(CommandLine.arguments.dropFirst())`.
    public static func parse(_ arguments: [String]) throws -> CommandLineOptions {
        guard let first = arguments.first else { throw ArgumentError.missingCommand }

        // `--help` / `--version` accepted in command position: it is what everyone
        // types first.
        let commandToken: String
        switch first {
        case "--help", "-h": commandToken = "help"
        case "--version", "-V": commandToken = "version"
        default: commandToken = first
        }
        guard let command = Command(rawValue: commandToken) else {
            throw ArgumentError.unknownCommand(first)
        }

        var options = CommandLineOptions(command: command)
        let rest = Array(arguments.dropFirst())
        var index = 0

        func nextValue(for flag: String) throws -> String {
            guard index < rest.count else { throw ArgumentError.missingValue(flag: flag) }
            let value = rest[index]
            // A `--other-option` in value position is a forgotten value, not a file
            // name. Better to refuse than to write the state to a file named
            // "--verbose".
            guard !value.hasPrefix("--") else { throw ArgumentError.missingValue(flag: flag) }
            index += 1
            return value
        }

        while index < rest.count {
            let flag = rest[index]
            index += 1
            switch flag {
            case "--manifest", "-m":    options.manifestPath = try nextValue(for: flag)
            case "--package-key", "-k": options.packageKey = try nextValue(for: flag)
            case "--package", "-p":     options.packagePath = try nextValue(for: flag)
            case "--log":               options.logPath = try nextValue(for: flag)
            case "--state":             options.statePath = try nextValue(for: flag)
            case "--dialog":            options.dialogPath = try nextValue(for: flag)
            case "--language", "-l":    options.language = try nextValue(for: flag)
            case "--mode", "--deploy-mode":
                let raw = try nextValue(for: flag)
                guard let parsed = DeploymentMode(lenient: raw) else {
                    throw ArgumentError.invalidValue(flag: flag, value: raw)
                }
                options.modeOverride = parsed
            case "--show-when-not-running", "--dialog-when-not-running":
                let raw = try nextValue(for: flag)
                guard let parsed = CommandLineOptions.parseBool(raw) else {
                    throw ArgumentError.invalidValue(flag: flag, value: raw)
                }
                options.showWhenNotRunningOverride = parsed
            case "--action", "--deployment-type":
                let raw = try nextValue(for: flag)
                guard let parsed = DeploymentAction(lenient: raw) else {
                    throw ArgumentError.invalidValue(flag: flag, value: raw)
                }
                options.actionOverride = parsed
            case "--dry-run", "-n":     options.dryRun = true
            case "--verbose", "-v":     options.verbose = true
            case "--json":              options.json = true
            case "--force", "-f":       options.force = true
            default:                    throw ArgumentError.unknownFlag(flag)
            }
        }

        try options.validate()
        return options
    }

    public func validate() throws {
        switch command {
        case .pre, .post, .install, .uninstall, .repair:
            guard manifestPath != nil else {
                throw ArgumentError.manifestRequired(command: command.rawValue)
            }
        case .reset:
            guard manifestPath != nil || packageKey != nil else {
                throw ArgumentError.targetRequired(command: command.rawValue)
            }
        case .status, .version, .help:
            break
        }
    }

    /// Lenient boolean for `--show-when-not-running`: accepts the common spellings a
    /// generated script or an operator might write. `nil` on anything else, so an
    /// obvious typo is refused rather than silently read as `false`.
    static func parseBool(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "true", "yes", "on", "1":  return true
        case "false", "no", "off", "0": return false
        default:                        return nil
        }
    }

    public static let usage = """
    macadt-deploy — macOS deployment wrapper, invoked by Intune

    USAGE
      macadt-deploy <command> [options]

    COMMANDS
      pre         Pre-install: evaluate, prompt, close the blocking applications
      post        Post-install: quarantine, signature, RestartAction, state
      install     Install the manifest's payload (embedded DMG or PKG)
      uninstall   Uninstall according to the manifest's `uninstall` block
      repair      Uninstall preserving the config, then reinstall
      status      Show the deferral state
      reset       Reset the deferral counter
      version     Binary version
      help        This help

    OPTIONS
      -m, --manifest <path>     JSON manifest of the deployment
      -k, --package-key <key>   Target a deployment without a manifest (status, reset)
      -p, --package <path>      Path of the .pkg, to query RestartAction
          --mode <mode>         Override the mode: Interactive | NonInteractive
                                | Silent | Auto (alias --deploy-mode)
          --show-when-not-running <bool>
                                Override showing the gate when no app is running:
                                true | false (alias --dialog-when-not-running)
          --action <action>      Override the action: Install | Uninstall | Repair
                                (alias --deployment-type)
      -n, --dry-run             Run nothing: evaluate and print the plan
      -v, --verbose             Log at the debug level
      -f, --force               Ignore the deferral counter
          --json                Machine-readable output on stdout
      -l, --language <code>     Force the dialog language (fr, en)
          --log <path>          Log file (default: \(FileLogger.defaultPath))
          --state <directory>   States directory, one file per deployment\n                        (default: \(PlistStateStore.defaultDirectory.path))
          --dialog <path>       swiftDialog binary (default: \(defaultDialogPath))

    EXIT CODES
      0       installed
      1-5     failure (see the log)
      60-69   not installed, transient block: Intune must retry
      70-72   installed, restart / logout / shutdown required
    """
}
