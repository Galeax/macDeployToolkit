import Foundation
import MDTKit
#if canImport(Darwin)
import MDTMac
#endif

// Helper, executed INSIDE the user's session via
// `launchctl asuser <uid> sudo -u <user>`.
//
// Its separate existence is not a style choice: from the daemon context where an
// Intune script runs there is no access to the WindowServer, so no UI is
// possible. The helper's only job is to display dialogs inside the session.
//
// Protocol: one JSON request on stdin, one JSON response on stdout, then exit.
// No socket to manage, no lifecycle to watch.

#if canImport(Darwin)

let logger = FileLogger(
    path: FileLogger.defaultPath, subject: "ui", minimumLevel: .info)

func respond(_ response: UIResponse) -> Never {
    if let data = try? LineCodec.encode(response) {
        FileHandle.standardOutput.write(data)
    }
    exit(ExitCode.success.rawValue)
}

// The swiftDialog path can be passed as the second argument; otherwise the
// default is used. The agent forwards it when it was overridden on the command line.
let dialogPath = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : CommandLineOptions.defaultDialogPath

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let line = LineCodec.split(buffer: input).lines.first else {
    logger.error("no request on stdin")
    respond(.failed(reason: "no request on stdin"))
}

let request: UIRequest
do {
    request = try LineCodec.decode(UIRequest.self, from: line)
} catch {
    logger.error("unreadable request: \(error)")
    respond(.failed(reason: "unreadable request"))
}

switch request {
case .ping:
    respond(.pong)

case .dismiss:
    respond(.acknowledged)

case .showDialog(let spec):
    do {
        let outcome = try DialogRunner.present(spec, dialogPath: dialogPath, logger: logger)
        respond(.dialogOutcome(outcome))
    } catch {
        logger.error("\(error)")
        respond(.failed(reason: String(describing: error)))
    }

case .showDetached(let spec):
    do {
        let pid = try DialogRunner.presentDetached(spec, dialogPath: dialogPath, logger: logger)
        respond(.detachedStarted(pid: pid))
    } catch {
        logger.error("\(error)")
        respond(.failed(reason: String(describing: error)))
    }

case .dismissDetached(let pid):
    DialogRunner.dismissDetached(pid: pid, logger: logger)
    respond(.acknowledged)
}

#else

FileHandle.standardError.write(Data("macdeploy-ui only runs on macOS\n".utf8))
exit(ExitCode.failure.rawValue)

#endif
