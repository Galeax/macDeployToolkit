import Foundation

/// Path primitives, with no disk access whatsoever.
///
/// No symlink resolution, no `realpath`: we reason about what the manifest
/// declares, not about the current state of the file system. This is deliberately
/// conservative — the FS state can change between computing the plan and running
/// it, and a plan that depends on the FS is not auditable.
public enum PathSafety {

    /// Normalizes an absolute path. Returns `nil` if the path is not absolute or
    /// contains a `..`.
    ///
    /// `..` segments are **refused** and not resolved: in a deletion plan,
    /// accepting `/Applications/Foo.app/../..` by silently reducing it to `/` would
    /// be exactly the bug not to have.
    public static func normalize(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var parts: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." { return nil }
            parts.append(String(component))
        }
        return "/" + parts.joined(separator: "/")
    }

    public static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Is `parent` an ancestor of `child`?
    ///
    /// Compares component by component, never by string prefix: a `hasPrefix` would
    /// see `/Applications/Slack.app` as an ancestor of
    /// `/Applications/Slack.app.backup`, which would be enough to wipe a backup.
    public static func isAncestor(_ parent: String, of child: String, orEqual: Bool = false) -> Bool {
        let parentParts = components(parent)
        let childParts = components(child)
        if parentParts.count > childParts.count { return false }
        if parentParts.count == childParts.count {
            return orEqual && parentParts == childParts
        }
        return Array(childParts.prefix(parentParts.count)) == parentParts
    }

    /// Resolves a reference while guaranteeing it stays under `root`.
    ///
    /// An absolute reference is accepted only if it already designates a descendant
    /// of `root`. In other words, the manifest can only designate files shipped
    /// with it — never `/tmp/payload.dmg`.
    ///
    /// Shared between the hooks and the payload: both are files designated by a JSON
    /// then manipulated as root, so both need the same confinement.
    public static func confine(_ reference: String, within root: String) -> String? {
        guard let base = normalize(root) else { return nil }
        let candidate = reference.hasPrefix("/") ? reference : base + "/" + reference
        guard let resolved = normalize(candidate), isAncestor(base, of: resolved) else {
            return nil
        }
        return resolved
    }

    /// Reduces a list of paths to its minimal roots: if an ancestor is present, its
    /// descendants are superfluous.
    ///
    /// Lexicographic order guarantees that an ancestor always precedes its
    /// descendants (an ancestor is a strict prefix). We do, however, compare
    /// against **all** the roots already kept and not only the last one: a sibling
    /// path can slip between an ancestor and its descendant (`/A/b`, `/A/b-x`,
    /// `/A/b/c`), and a test on the last root only would then let `/A/b/c` through.
    public static func minimalRoots(_ paths: [String]) -> [String] {
        var roots: [String] = []
        for path in Set(paths).sorted() {
            if roots.contains(where: { isAncestor($0, of: path, orEqual: true) }) { continue }
            roots.append(path)
        }
        return roots
    }
}
