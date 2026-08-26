import Foundation

/// Persistent state of a deployment; carries the deferral counter.
///
/// This is the piece that replaces Munki's silent retry-forever: Intune retries at
/// check-in with no memory, so this is where the memory lives.
public struct DeploymentState: Codable, Equatable, Sendable {

    public var packageKey: String

    /// Number of deferrals consumed by the user.
    public var deferralsUsed: Int

    /// Date of the first prompt shown. Origin of the `deferralDays` window. Set as
    /// of the first dialog, even if the user agrees to close: the window starts at
    /// the first solicitation, not at the first refusal.
    public var firstPromptDate: Date?

    public var lastPromptDate: Date?

    /// Last exit code, as a slug (`ExitCode.slug`).
    public var lastOutcome: String?

    public var lastRunDate: Date?

    /// Version observed installed at the last successful post-install.
    public var installedVersion: String?

    /// Date at which the user agreed to close their applications.
    ///
    /// Used to cross the window between `pre` and `install`: Intune drops the
    /// payload between the two, and the user may have reopened their browser during
    /// those few seconds. A recent consent then authorizes closing again without
    /// re-prompting — neither killing without warning, nor asking again a question
    /// they just answered.
    public var consentGrantedAt: Date?

    public init(packageKey: String) {
        self.packageKey = packageKey
        self.deferralsUsed = 0
        self.firstPromptDate = nil
        self.lastPromptDate = nil
        self.lastOutcome = nil
        self.lastRunDate = nil
        self.installedVersion = nil
        self.consentGrantedAt = nil
    }

    private enum CodingKeys: String, CodingKey {
        case packageKey, deferralsUsed, firstPromptDate, lastPromptDate
        case lastOutcome, lastRunDate, installedVersion, consentGrantedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        packageKey = try container.decode(String.self, forKey: .packageKey)
        deferralsUsed = try container.decodeIfPresent(Int.self, forKey: .deferralsUsed) ?? 0
        firstPromptDate = try container.decodeIfPresent(Date.self, forKey: .firstPromptDate)
        lastPromptDate = try container.decodeIfPresent(Date.self, forKey: .lastPromptDate)
        lastOutcome = try container.decodeIfPresent(String.self, forKey: .lastOutcome)
        lastRunDate = try container.decodeIfPresent(Date.self, forKey: .lastRunDate)
        installedVersion = try container.decodeIfPresent(String.self, forKey: .installedVersion)
        consentGrantedAt = try container.decodeIfPresent(Date.self, forKey: .consentGrantedAt)
    }
}

public protocol StateStoring {
    func load(packageKey: String) -> DeploymentState
    func save(_ state: DeploymentState) throws
    /// Purges the state of a deployment (new campaign, manual reset).
    func reset(packageKey: String) throws
    func allStates() -> [DeploymentState]
}

/// In-memory store, for tests and `--dry-run`.
public final class InMemoryStateStore: StateStoring, @unchecked Sendable {
    private var states: [String: DeploymentState] = [:]
    private let lock = NSLock()

    public init(seed: [DeploymentState] = []) {
        for state in seed { states[state.packageKey] = state }
    }

    public func load(packageKey: String) -> DeploymentState {
        lock.lock(); defer { lock.unlock() }
        return states[packageKey] ?? DeploymentState(packageKey: packageKey)
    }

    public func save(_ state: DeploymentState) throws {
        lock.lock(); defer { lock.unlock() }
        states[state.packageKey] = state
    }

    public func reset(packageKey: String) throws {
        lock.lock(); defer { lock.unlock() }
        states.removeValue(forKey: packageKey)
    }

    public func allStates() -> [DeploymentState] {
        lock.lock(); defer { lock.unlock() }
        return states.values.sorted { $0.packageKey < $1.packageKey }
    }
}

/// On-disk store, as XML plist.
///
/// XML and not binary, deliberately: an admin must be able to read a device's
/// deferral counter with a simple `plutil -p` or a text editor during an incident.
///
/// ONE FILE PER DEPLOYMENT, and not a single file carrying all the states. This
/// choice is not cosmetic: the previous store read the whole thing, modified one
/// entry and rewrote all of it. Two concurrent deployments — two applications whose
/// post-installs Intune launches at the same time — lost each other's deferral
/// counter, last writer winning. The user would then get back deferrals they had
/// already consumed.
///
/// Isolating the files removes the shared read-modify-write, and so the race,
/// without having to introduce an inter-process `flock`.
///
/// Atomic write via auxiliary file + rename, so that an interrupted run never
/// leaves a truncated state.
public final class PlistStateStore: StateStoring, @unchecked Sendable {

    /// Directory of the states. Next to `manifests/`, never inside it: the
    /// post-install deletes the manifest directory after a successful installation,
    /// and would take the deferral counters with it.
    public static let defaultDirectory = URL(
        fileURLWithPath: "/Library/Application Support/CoreUpdate/Deploy/state")

    private struct Envelope: Codable {
        var schemaVersion: Int
        var state: DeploymentState
    }

    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL = PlistStateStore.defaultDirectory) {
        self.directory = directory
    }

    /// The `packageKey` becomes a file name opened for writing by a root process —
    /// exactly the danger that `LogPaths` handles for `logName`. A key like
    /// `../../etc/cron.d/backdoor` would make the state an arbitrary-write
    /// primitive. We therefore reuse the same reduction.
    private func url(for packageKey: String) -> URL? {
        guard let safe = LogPaths.sanitizeComponent(packageKey) else { return nil }
        return directory.appendingPathComponent(safe + ".plist")
    }

    private func read(_ url: URL) -> DeploymentState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Unreadable state: we start from scratch rather than block the deployment.
        // An accepted consequence, and local to a single application, which was not
        // the case with a shared file: the user gets their deferrals back for this
        // one only.
        return (try? PropertyListDecoder().decode(Envelope.self, from: data))?.state
    }

    private func write(_ state: DeploymentState, to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(Envelope(schemaVersion: 1, state: state))

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])

        // `.atomic` writes to an auxiliary file in the same directory then renames:
        // an interrupted run cannot leave a truncated state.
        //
        // We deliberately do not use `FileManager.replaceItemAt`: its
        // implementation diverges between Apple's Foundation and swift-corelibs,
        // the latter failing as soon as the destination already exists. Verified
        // by this module's tests.
        try data.write(to: url, options: .atomic)

        // After the rename, the file carries the temporary's permissions: we reset
        // them explicitly.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: url.path)
    }

    public func load(packageKey: String) -> DeploymentState {
        lock.lock(); defer { lock.unlock() }
        guard let url = url(for: packageKey), let state = read(url) else {
            return DeploymentState(packageKey: packageKey)
        }
        return state
    }

    public func save(_ state: DeploymentState) throws {
        lock.lock(); defer { lock.unlock() }
        guard let url = url(for: state.packageKey) else {
            throw StateStoreError.unusablePackageKey(state.packageKey)
        }
        try write(state, to: url)
    }

    public func reset(packageKey: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let url = url(for: packageKey) else {
            throw StateStoreError.unusablePackageKey(packageKey)
        }
        // Absent = already reset. This is not an error.
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// All the device's states, in key order. This is what `macdeploy status
    /// --json` returns, and the only operation that still walks the whole
    /// directory.
    public func allStates() -> [DeploymentState] {
        lock.lock(); defer { lock.unlock() }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "plist" }
            .compactMap { read($0) }
            .sorted { $0.packageKey < $1.packageKey }
    }
}

public enum StateStoreError: Error, CustomStringConvertible {
    /// The key produces no usable file name — empty, or made only of separators and
    /// refused characters.
    case unusablePackageKey(String)

    public var description: String {
        switch self {
        case .unusablePackageKey(let key):
            return "packageKey unusable as a file name: \"\(key)\""
        }
    }
}
