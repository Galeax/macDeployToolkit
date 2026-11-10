// WARNING: this file is NOT covered by unit tests. It only compiles on macOS and
// its three functions are exactly probes #1 and #4 of the spike. Treat as
// untested until validated on a real Mac.

#if canImport(Darwin)
import Foundation
import SystemConfiguration
import CoreGraphics
import IOKit
import IOKit.pwr_mgt

public struct ConsoleUserInfo: Equatable, Sendable {
    public let username: String
    public let uid: uid_t

    public init(username: String, uid: uid_t) {
        self.username = username
        self.uid = uid
    }
}

public enum SessionInspector {

    /// The console-logged-in user, or `nil` if there is no usable one.
    ///
    /// Three cases must be excluded explicitly — this is the classic source of
    /// bugs when naively reading `SCDynamicStoreCopyConsoleUser`:
    ///  - `nil` or empty string: nobody;
    ///  - `loginwindow`: login screen shown, so no GUI session;
    ///  - uid < 501: system accounts, including `_mbsetupuser` during Setup
    ///    Assistant. Installing during the setup assistant is the scenario that
    ///    produces the most painful tickets.
    public static func consoleUser() -> ConsoleUserInfo? {
        var uid: uid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String? else {
            return nil
        }
        guard !name.isEmpty, name != "loginwindow", uid >= 501 else { return nil }
        return ConsoleUserInfo(username: name, uid: uid)
    }

    /// Locked session.
    ///
    /// `CGSSessionScreenIsLocked` is absent from the dictionary when the screen
    /// is unlocked — absence and `false` are equivalent here.
    public static func isScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as NSDictionary? else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Presentation or video call in progress: something is actively preventing
    /// display sleep.
    ///
    /// This is the macOS equivalent of PSADT's presentation mode. Chosen over
    /// reading the Focus / Do Not Disturb status, which has no public API and
    /// whose database format is not contractual — it has changed several times
    /// between major macOS versions.
    public static func isPresenting() -> Bool {
        var assertions: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&assertions) == kIOReturnSuccess,
              let dictionary = assertions?.takeRetainedValue() as? [String: Int]
        else { return false }

        let blockingTypes = [
            kIOPMAssertionTypePreventUserIdleDisplaySleep as String,
            kIOPMAssertionTypeNoDisplaySleep as String,
        ]
        return blockingTypes.contains { (dictionary[$0] ?? 0) > 0 }
    }
}

#else

/// Off macOS the module is empty, and that's intentional: all the testable logic
/// lives in MacADTKit, MacADTMac only contains Apple system calls.
public enum MacADTMacUnavailable {
    public static let reason = "MacADTMac requires macOS"
}

#endif
