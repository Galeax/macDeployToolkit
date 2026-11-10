// NOT VERIFIED BY LINUX CI — this file only compiles on macOS.

#if canImport(Darwin)
import Foundation
import Darwin

/// Feeds the installation-progress dialog: `progress:` lines appended to the
/// command file swiftDialog watches.
///
/// The agent is root and the file lives in `/tmp`, created by a process of the
/// user's. Writing there blindly would be an arbitrary-append primitive: a symlink
/// or hard link planted at that path would send our lines into any file on the
/// system. So every write opens without following links and checks, on the open
/// descriptor, that the target is a plain single-linked file owned by the console
/// user — a file they could have written themselves. Anything else is skipped: a
/// bar that does not move is harmless.
final class ProgressFeed: @unchecked Sendable {

    private let path: String
    private let ownerUID: uid_t
    private let lock = NSLock()
    private var lastPercent = -1

    init(path: String, ownerUID: uid_t) {
        self.path = path
        self.ownerUID = ownerUID
    }

    /// - Parameter fraction: 0…1.
    func report(_ fraction: Double) {
        let percent = max(0, min(100, Int((fraction * 100).rounded())))
        lock.lock(); defer { lock.unlock() }
        guard percent != lastPercent else { return }

        let descriptor = open(path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1,
              info.st_uid == ownerUID
        else { return }

        let lines = "progress: \(percent)\nprogresstext: \(percent) %\n"
        let written = lines.withCString { write(descriptor, $0, strlen($0)) }
        if written > 0 { lastPercent = percent }
    }

    /// Removes the file, under the same checks: `unlink` on a path in `/tmp` only
    /// ever removes the directory entry, never a link's target.
    func remove() {
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == ownerUID
        else { return }
        unlink(path)
    }
}
#endif
