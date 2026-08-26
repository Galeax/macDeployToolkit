import Foundation

/// Per-application log resolution, the equivalent of PSADT's `LogName`.
///
/// SECURITY PROBLEM: `logName` comes from the manifest and becomes a file name
/// opened for writing by a root process. A value like
/// `../../etc/cron.d/backdoor` would turn the log into an arbitrary-write
/// primitive. The value is therefore reduced to a plain file name, with a
/// restricted character set — never interpolated as-is into a path.
public enum LogPaths {

    /// Per-application log directory. Separate from the global log so that a
    /// troubleshooting `rm` on one does not take the other with it.
    public static let applicationDirectory = "/var/log/coreupdate"

    /// Characters kept in a log name. Everything else becomes `_`.
    private static let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    /// Reduces a manifest value to a safe file name.
    ///
    /// - the path is flattened: only the last component is kept, so
    ///   `../../etc/passwd` becomes `passwd`;
    /// - characters outside the allow-list become `_`;
    /// - leading dots are removed, otherwise `...` would stay `...` and `.hidden`
    ///   would produce an invisible log;
    /// - a value empty after cleaning falls back to `nil`, instead of producing a
    ///   file with an empty name.
    public static func sanitize(_ raw: String) -> String? {
        guard let cleaned = sanitizeComponent(raw) else { return nil }
        return cleaned.hasSuffix(".log") ? cleaned : cleaned + ".log"
    }

    /// The same reduction, without an imposed suffix.
    ///
    /// Extracted so that `PlistStateStore` can use it: now that it writes one file
    /// per deployment, the `packageKey` also becomes a file name opened for writing
    /// by a root process, and runs exactly the same risk as `logName`.
    public static func sanitizeComponent(_ raw: String) -> String? {
        // The trim comes BEFORE the replacement: otherwise spaces become
        // underscores and survive, and `"   "` would produce a `___.log` log.
        let lastComponent = (raw.split(separator: "/").last.map(String.init) ?? raw)
            .trimmingCharacters(in: .whitespaces)

        var cleaned = String(lastComponent.map { allowed.contains($0) ? $0 : "_" })
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }

        // A name made only of separators identifies nothing: better to fall back
        // to the derivation from the key and the version.
        guard cleaned.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return cleaned
    }

    /// Log name of a deployment.
    ///
    /// Reuses `logName` when declared, otherwise derives it from the key — and, in
    /// both cases, **the version is part of the name**. The same convention as the
    /// `f"{application}_{version}.log"` of the `coreupdate_config.json` on the
    /// Windows side.
    ///
    /// The version is appended even to a declared `logName`, which departs from the
    /// literal `LogName` of PSADT. This is deliberate: without it, every version of
    /// an application writes to the same file and we lose track of what each
    /// deployment did — yet it is precisely this log we re-read when an update went
    /// wrong. A `logName` that already contains its version is not modified.
    public static func fileName(for manifest: Manifest) -> String {
        let version = sanitizeComponent(manifest.version)
        let base = manifest.logName.flatMap(sanitizeComponent)
            ?? sanitizeComponent(manifest.packageKey)
            ?? "coreupdate-deploy"

        guard let version, !base.contains(version) else { return base + ".log" }
        return "\(base)_\(version).log"
    }

    public static func path(for manifest: Manifest) -> String {
        "\(applicationDirectory)/\(fileName(for: manifest))"
    }
}
