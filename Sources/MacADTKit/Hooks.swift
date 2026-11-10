import Foundation

// Per-application escape hatches. Of the 264 Windows apps in the Veille catalog,
// 20 need a `pre-install.ps1` and 14 a `post-install.ps1` — there is no reason
// macOS would be different, and a purely declarative manifest always ends up
// hitting a special case.
//
// CENTRAL SECURITY PROBLEM: a script path read from a JSON and executed as root is
// an arbitrary-code-execution primitive. If a manifest is modifiable by a user —
// or by anything that writes into its directory — the deployment becomes a local
// privilege escalation.
//
// Hence four safeguards, all checked before execution:
//   1. the resolved path must stay INSIDE the manifest directory;
//   2. the script must exist and be executable;
//   3. it must be owned by root;
//   4. it must not be writable by the group or by others.
//
// Rules 2 to 4 are exactly those `launchd` applies to its plists, for the same
// reason.

public enum HookPhase: String, Codable, Equatable, Sendable, CaseIterable {
    case preInstall
    case postInstall
    case preUninstall
    case postUninstall

    /// Conventional file name, aligned with Veille's `extrafiles/` so that a
    /// packager finds their bearings.
    public var conventionalFilename: String {
        switch self {
        case .preInstall:     return "pre-install.sh"
        case .postInstall:    return "post-install.sh"
        case .preUninstall:   return "pre-uninstall.sh"
        case .postUninstall:  return "post-uninstall.sh"
        }
    }
}

public struct HookSpec: Codable, Equatable, Sendable {

    public var preInstall: String?
    public var postInstall: String?
    public var preUninstall: String?
    public var postUninstall: String?

    public init(
        preInstall: String? = nil,
        postInstall: String? = nil,
        preUninstall: String? = nil,
        postUninstall: String? = nil
    ) {
        self.preInstall = preInstall
        self.postInstall = postInstall
        self.preUninstall = preUninstall
        self.postUninstall = postUninstall
    }

    public func reference(for phase: HookPhase) -> String? {
        switch phase {
        case .preInstall:    return preInstall
        case .postInstall:   return postInstall
        case .preUninstall:  return preUninstall
        case .postUninstall: return postUninstall
        }
    }

    public var isEmpty: Bool {
        HookPhase.allCases.allSatisfy { reference(for: $0) == nil }
    }

    private enum CodingKeys: String, CodingKey {
        case preInstall, postInstall, preUninstall, postUninstall
    }

    public init(from decoder: Decoder) throws {
        let container = try LenientContainer(decoder)
        preInstall = try container.decode(String.self, "preInstall", "pre-install")
        postInstall = try container.decode(String.self, "postInstall", "post-install")
        preUninstall = try container.decode(String.self, "preUninstall", "pre-uninstall")
        postUninstall = try container.decode(String.self, "postUninstall", "post-uninstall")
    }
}

public enum HookRejection: String, Codable, Equatable, Sendable, Error {
    case escapesManifestDirectory
    case missing
    case notExecutable
    case notOwnedByRoot
    case writableByGroupOrOther
}

/// Attributes of a file, as read by `MacADTMac`.
///
/// Declared as a plain value so that the security decision is a pure function, and
/// therefore testable — the check that prevents a privilege escalation must not be
/// the only one in the project left unverified.
public struct FileSecurityAttributes: Equatable, Sendable {
    public let exists: Bool
    public let isExecutable: Bool
    public let ownerUID: UInt32
    /// POSIX permission bits (the low 12 bits of `st_mode`).
    public let permissions: UInt16

    public init(exists: Bool, isExecutable: Bool, ownerUID: UInt32, permissions: UInt16) {
        self.exists = exists
        self.isExecutable = isExecutable
        self.ownerUID = ownerUID
        self.permissions = permissions
    }
}

public enum HookResolver {

    /// Resolves a hook reference to an absolute path, guaranteeing it does not leave
    /// the manifest directory.
    ///
    /// An absolute reference is accepted only if it already designates a descendant
    /// of that directory. In other words, the manifest can only designate scripts
    /// shipped with it — never `/tmp/payload.sh`.
    public static func resolve(
        reference: String,
        manifestDirectory: String
    ) -> Result<String, HookRejection> {
        // A `..` is refused by `PathSafety.normalize`, and not resolved: this is the
        // only way to guarantee confinement without having to reason about symbolic
        // links.
        guard let resolved = PathSafety.confine(reference, within: manifestDirectory) else {
            return .failure(.escapesManifestDirectory)
        }
        return .success(resolved)
    }

    /// Security verdict on the file itself. `nil` = executable safely.
    public static func validate(_ attributes: FileSecurityAttributes) -> HookRejection? {
        guard attributes.exists else { return .missing }
        guard attributes.isExecutable else { return .notExecutable }
        guard attributes.ownerUID == 0 else { return .notOwnedByRoot }
        // 0o022 = group write + other write. A root-executable script writable by
        // others is equivalent to a root shell handed out.
        guard attributes.permissions & 0o022 == 0 else { return .writableByGroupOrOther }
        return nil
    }
}
