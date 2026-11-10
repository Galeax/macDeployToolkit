import Foundation
import MacADTKit
#if canImport(Darwin)
import MacADTMac
#endif

// Agent. Invoked by Intune as the pre-install / post-install script of a
// "macOS app (PKG)"-type app, as root and in a daemon context.
//
// Deliberately thin: all the decision logic lives in MacADTKit (tested), all the
// orchestration in MacADTMac.DeploymentRunner.

#if canImport(Darwin)

let arguments = Array(CommandLine.arguments.dropFirst())

let options: CommandLineOptions
do {
    options = try CommandLineOptions.parse(arguments)
} catch {
    FileHandle.standardError.write(Data("macadt-deploy: \(error)\n\n".utf8))
    FileHandle.standardError.write(Data((CommandLineOptions.usage + "\n").utf8))
    exit(ExitCode.failure.rawValue)
}

// Log: file + stderr. Never stdout, which stays reserved for machine-readable
// output so it remains pipe-able into `jq`.
let level: LogLevel = options.verbose ? .debug : .info
let subject = options.packageKey ?? options.manifestPath.map {
    URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
}
let logger = CompositeLogger([
    FileLogger(path: options.logPath, subject: subject, minimumLevel: level),
    ConsoleLogger(subject: subject, minimumLevel: level),
])

// In `--dry-run`, state lives in memory: the scenario can be replayed as many
// times as wanted without ever consuming a real deferral on the device.
let store: StateStoring = options.dryRun
    ? InMemoryStateStore()
    : PlistStateStore(directory: URL(fileURLWithPath: options.statePath))

let runner = DeploymentRunner(options: options, logger: logger, store: store)
exit(runner.run().rawValue)

#else

FileHandle.standardError.write(Data("macadt-deploy only runs on macOS\n".utf8))
exit(ExitCode.failure.rawValue)

#endif
