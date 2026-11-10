// NOT VERIFIED BY LINUX CI — this file only compiles on macOS.
//
// This is probe #4 of the spike. The point to validate on a real Mac: does the
// libproc enumeration from root correctly see applications launched from a user
// home (`~/Applications`) and from an external volume.

#if canImport(Darwin)
import Foundation
import Darwin
import MacADTKit

// `PROC_PIDPATHINFO_MAXSIZE` is not visible from Swift: the macro expands to
// `(4*MAXPATHLEN)` and the importer does not translate arithmetic macros
// ("unavailable: structure not supported"). So we reproduce the definition from
// <sys/proc_info.h> by hand, backed by PATH_MAX, which is imported.
let procPidPathInfoMaxSize = 4 * Int(PATH_MAX)

public enum ProcessScanner {

    /// Snapshot of every visible process, with its resolved bundle ID.
    ///
    /// libproc and not `NSWorkspace`: from a daemon context — which is what an
    /// Intune script is — `NSWorkspace.shared.runningApplications` returns an
    /// empty or incomplete list, for lack of a connection to the user session.
    /// libproc queries the kernel and depends on no session.
    ///
    /// The bundle ID is resolved by reading the enclosing bundle's `Info.plist`,
    /// never via a session API. Reads are cached: on a busy device, several
    /// hundred processes share a handful of bundles.
    public static func snapshot() -> [RunningProcess] {
        var cache: [String: String?] = [:]
        return executablePaths().map { pid, path in
            let bundlePath = BundlePath.enclosingAppBundle(forExecutablePath: path)
            var identifier: String?
            if let bundlePath {
                if let cached = cache[bundlePath] {
                    identifier = cached
                } else {
                    identifier = bundleIdentifier(atBundlePath: bundlePath)
                    cache[bundlePath] = identifier
                }
            }
            return RunningProcess(pid: pid, executablePath: path, bundleIdentifier: identifier)
        }
    }

    /// PID -> executable path, for every readable process.
    private static func executablePaths() -> [(Int32, String)] {
        // First call empty to size, second to fill. We add a margin: processes
        // can be born between the two calls, and without the margin we would
        // silently truncate the list.
        let probe = proc_listallpids(nil, 0)
        guard probe > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(probe) + 128)
        let byteCount = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let written = proc_listallpids(&pids, byteCount)
        guard written > 0 else { return [] }

        var results: [(Int32, String)] = []
        results.reserveCapacity(Int(written))

        for pid in pids.prefix(Int(written)) where pid > 0 {
            var buffer = [CChar](repeating: 0, count: procPidPathInfoMaxSize)
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            // length <= 0 is the normal case, not an error: the process died
            // between enumeration and the read, or belongs to a context we cannot
            // inspect even as root (processes protected by SIP).
            guard length > 0 else { continue }
            results.append((Int32(pid), String(cString: buffer)))
        }
        return results
    }

    private static func bundleIdentifier(atBundlePath bundlePath: String) -> String? {
        let plistPath = bundlePath + "/Contents/Info.plist"
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }

    /// Which of the manifest's blocking apps are running.
    /// The matching itself lives in `MacADTKit.AppMatcher` and is tested.
    public static func running(from specs: [BlockingAppSpec]) -> [BlockingAppSpec] {
        AppMatcher.matching(specs: specs, processes: snapshot())
    }

    /// `SIGKILL` from the agent, without going through the helper.
    ///
    /// `kill(2)` on the PIDs found by libproc depends on no session: it works in
    /// a daemon context as in a session, and for an application declared by
    /// bundle ID as by plain process name. This is the only close mechanism.
    ///
    /// No save possible, no save dialog.
    public static func forceKill(
        _ specs: [BlockingAppSpec],
        logger: DeployLogging
    ) -> TerminationResult {

        var result = TerminationResult()
        let processes = snapshot()

        for spec in specs {
            let pids = AppMatcher.pids(for: spec, processes: processes)
            guard !pids.isEmpty else {
                logger.debug("\(spec.displayName) is not running")
                continue
            }
            logger.warning("force-closing \(spec.displayName) "
                + "(\(pids.count) processes): possible loss of work")
            for pid in pids { kill(pid, SIGKILL) }

            Thread.sleep(forTimeInterval: 1)
            // Fresh snapshot: the PIDs from the first pass may already be
            // recycled, and a test on the old list would prove nothing.
            if AppMatcher.pids(for: spec, processes: snapshot()).isEmpty {
                result.terminated.append(spec.identifier)
            } else {
                result.stillRunning.append(spec.identifier)
                logger.error("\(spec.displayName) survives SIGKILL")
            }
        }
        return result
    }
}
#endif
