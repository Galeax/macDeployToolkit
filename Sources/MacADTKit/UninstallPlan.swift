import Foundation

// The most dangerous code in the project. A mistake here is not a ticket, it is a
// device to reinstall — or even a whole fleet, since the same plan runs
// everywhere.
//
// Hence three stances:
//  1. the plan is a pure value, computed without touching the disk, so auditable
//     and entirely testable off macOS;
//  2. the validation of each path happens BEFORE the pruning. `pkgutil --files`
//     lists intermediate directories, including `Applications` itself: pruning
//     first would fold everything under `/Applications` and wipe the whole folder;
//  3. every refusal is reported with its reason, never silent.

public enum RejectionReason: String, Codable, Equatable, Sendable {
    case notAbsolute
    case pathTraversal
    case criticalSystemPath
    case sharedUserPath
    case tooShallow
    case outsideAllowedRoots
    case preserved
    case ancestorOfPreserved
    case emptyLaunchdLabel
}

public struct PathRejection: Codable, Equatable, Sendable {
    public let path: String
    public let reason: RejectionReason

    public init(path: String, reason: RejectionReason) {
        self.path = path
        self.reason = reason
    }
}

public struct UninstallPlan: Codable, Equatable, Sendable {

    /// Minimal roots to delete, sorted.
    public var deletions: [String]

    /// Number of paths absorbed by an ancestor during pruning. Purely informative,
    /// but useful in the log: a receipt of 4000 files that reduces to 1 root is the
    /// normal case.
    public var prunedCount: Int

    /// launchd labels to unload BEFORE any deletion: removing the plist of a loaded
    /// service leaves an orphaned daemon in memory.
    public var launchdLabels: [String]

    /// Receipts to forget via `pkgutil --forget`, AFTER deletion: forgetting first
    /// would make the file list unrecoverable in case of failure.
    public var receiptsToForget: [String]

    public var rejections: [PathRejection]
    public var warnings: [String]

    public var isEmpty: Bool {
        deletions.isEmpty && launchdLabels.isEmpty && receiptsToForget.isEmpty
    }
}

public struct UninstallPlanner: Sendable {

    /// System paths never deletable, whatever the source.
    ///
    /// The `/var` and `/private/var` forms are both listed: on macOS they designate
    /// the same thing, and listing only one would make the denylist circumventable
    /// via the other spelling.
    public static let criticalSystemPaths: Set<String> = [
        "/",
        "/Applications", "/Applications/Utilities",
        "/System", "/Users", "/Volumes", "/cores", "/dev", "/net", "/home",
        "/bin", "/sbin", "/etc", "/tmp", "/var", "/private",
        "/private/etc", "/private/tmp", "/private/var", "/private/var/db",
        "/private/var/db/receipts", "/var/db", "/var/db/receipts",
        "/private/var/root", "/var/root", "/private/var/folders", "/var/folders",
        "/usr", "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/libexec",
        "/usr/share", "/usr/local", "/usr/local/bin", "/usr/local/sbin",
        "/usr/local/lib", "/usr/local/share", "/usr/local/etc",
        "/usr/local/include", "/usr/local/opt", "/usr/local/Cellar",
        "/opt", "/opt/homebrew", "/opt/homebrew/bin", "/opt/homebrew/lib",
        "/opt/homebrew/share", "/opt/homebrew/opt", "/opt/X11",
        "/Library",
        "/Library/Application Support", "/Library/Preferences",
        "/Library/LaunchAgents", "/Library/LaunchDaemons",
        "/Library/PrivilegedHelperTools", "/Library/Managed Preferences",
        "/Library/Extensions", "/Library/Frameworks", "/Library/Caches",
        "/Library/Logs", "/Library/Fonts", "/Library/Audio",
        "/Library/Internet Plug-Ins", "/Library/Security", "/Library/Keychains",
        "/Library/StartupItems", "/Library/Developer", "/Library/Java",
        "/Library/Printers", "/Library/Scripts", "/Library/Services",
        "/Library/ColorSync", "/Library/QuickLook", "/Library/Screen Savers",
        "/Library/SystemExtensions", "/Library/Widgets",
    ]

    /// Paths relative to a user home never deletable: they are shared by all of that
    /// user's applications.
    public static let criticalUserRelativePaths: Set<String> = [
        "",
        "Library",
        "Library/Application Support", "Library/Preferences", "Library/Caches",
        "Library/Containers", "Library/Group Containers", "Library/LaunchAgents",
        "Library/Logs", "Library/Cookies", "Library/HTTPStorages",
        "Library/WebKit", "Library/Saved Application State", "Library/Keychains",
        "Library/Fonts", "Library/Services", "Library/Mobile Documents",
        "Library/Autosave Information", "Library/ColorPickers",
        "Applications",
        "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures",
        "Public", "Sites",
    ]

    /// A path must be under one of these roots. Everything else is refused,
    /// including what is not explicitly in the denylist: allowlist by default, not
    /// denylist by default.
    public static let defaultAllowedRoots: [String] = [
        "/Applications", "/Library", "/usr/local", "/opt", "/Users",
        "/private/var/db/receipts", "/var/db/receipts",
    ]

    public let allowedRoots: [String]
    public let minimumDepth: Int
    public let minimumUserDepth: Int

    /// `minimumUserDepth` is 4: under `/Users`, at least
    /// `/Users/<name>/Library/<something>` is required. At 3 we would allow deleting
    /// `/Users/<name>/Library` in full.
    public init(
        allowedRoots: [String] = UninstallPlanner.defaultAllowedRoots,
        minimumDepth: Int = 2,
        minimumUserDepth: Int = 4
    ) {
        self.allowedRoots = allowedRoots
        self.minimumDepth = minimumDepth
        self.minimumUserDepth = minimumUserDepth
    }

    /// Verdict on an isolated path, without considering the preserved paths.
    /// `nil` = acceptable.
    public func classify(_ rawPath: String) -> RejectionReason? {
        guard rawPath.hasPrefix("/") else { return .notAbsolute }
        guard let path = PathSafety.normalize(rawPath) else { return .pathTraversal }

        if Self.criticalSystemPaths.contains(path) { return .criticalSystemPath }

        let parts = PathSafety.components(path)

        if parts.first == "Users" {
            // The relative denylist is evaluated BEFORE the depth: both refuse, but
            // "shared path" tells the admin why their manifest is rejected, where
            // "too shallow" sends them hunting for a syntax problem that does not
            // exist.
            let relative = parts.dropFirst(2).joined(separator: "/")
            if Self.criticalUserRelativePaths.contains(relative) { return .sharedUserPath }
            if parts.count < minimumUserDepth { return .tooShallow }
        } else if parts.count < minimumDepth {
            return .tooShallow
        }

        guard allowedRoots.contains(where: { PathSafety.isAncestor($0, of: path) }) else {
            return .outsideAllowedRoots
        }
        return nil
    }

    /// - Parameters:
    ///   - receiptFiles: output of `pkgutil --files <id>`, by identifier. The paths
    ///     there are relative to the root, without a leading slash.
    ///   - homeDirectories: user homes to resolve `~`. A `~` with no home provided is
    ///     ignored with a warning, never guessed.
    public func plan(
        spec: UninstallSpec,
        receiptFiles: [String: [String]] = [:],
        homeDirectories: [String] = []
    ) -> UninstallPlan {

        var warnings: [String] = []
        var rejections: [PathRejection] = []

        let preserved = spec.preservedPaths
            .flatMap { expandTilde($0, homeDirectories: homeDirectories, warnings: &warnings) }
            .compactMap(PathSafety.normalize)

        var candidates: [String] = []
        for raw in spec.paths {
            candidates.append(contentsOf: expandTilde(raw, homeDirectories: homeDirectories, warnings: &warnings))
        }
        for identifier in receiptFiles.keys.sorted() {
            for file in receiptFiles[identifier] ?? [] {
                let trimmed = file.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                candidates.append(trimmed.hasPrefix("/") ? trimmed : "/" + trimmed)
            }
        }

        var accepted: [String] = []
        for candidate in candidates {
            if let reason = classify(candidate) {
                rejections.append(PathRejection(path: candidate, reason: reason))
                continue
            }
            // `classify` has already validated the normalization.
            let path = PathSafety.normalize(candidate)!

            if preserved.contains(where: { PathSafety.isAncestor($0, of: path, orEqual: true) }) {
                rejections.append(PathRejection(path: path, reason: .preserved))
                continue
            }
            if let inner = preserved.first(where: { PathSafety.isAncestor(path, of: $0) }) {
                // We refuse rather than delete selectively: enumerating the FS to
                // spare a sub-tree would make the plan depend on the state of the
                // disk, and so not auditable. The refusal is visible.
                rejections.append(PathRejection(path: path, reason: .ancestorOfPreserved))
                warnings.append(
                    "\(path) kept: it contains the preserved path \(inner). "
                    + "Declare finer deletions if the cleanup must be complete.")
                continue
            }
            accepted.append(path)
        }

        let deletions = PathSafety.minimalRoots(accepted)

        var labels: [String] = []
        for label in spec.launchdLabels {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                rejections.append(PathRejection(path: label, reason: .emptyLaunchdLabel))
            } else {
                labels.append(trimmed)
            }
        }

        if deletions.isEmpty && labels.isEmpty && spec.packageIdentifiers.isEmpty {
            warnings.append("empty plan: nothing to uninstall after validation.")
        }

        return UninstallPlan(
            deletions: deletions,
            prunedCount: accepted.count - deletions.count,
            launchdLabels: labels,
            receiptsToForget: spec.packageIdentifiers,
            rejections: rejections,
            warnings: warnings)
    }

    /// Expands `~/...` over each user home provided. A path without `~` is returned
    /// as-is. The `~user/...` form is not supported: we refuse it later rather than
    /// interpret it wrongly.
    private func expandTilde(
        _ raw: String,
        homeDirectories: [String],
        warnings: inout [String]
    ) -> [String] {
        guard raw.hasPrefix("~") else { return [raw] }
        guard !homeDirectories.isEmpty else {
            warnings.append("\(raw) ignored: no user home provided to resolve `~`.")
            return []
        }
        let relative = String(String(raw.dropFirst()).drop(while: { $0 == "/" }))
        return homeDirectories.map { home in
            let base = home.hasSuffix("/") ? String(home.dropLast()) : home
            return relative.isEmpty ? base : base + "/" + relative
        }
    }
}
