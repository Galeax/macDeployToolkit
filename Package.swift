// swift-tools-version:5.9
import PackageDescription

// Zero external dependency, deliberately: this binary runs as root on production
// devices, and the supply-chain surface must stay nil. Corollary: argument
// parsing and the manifest format (JSON, via Foundation) are hand-written.
//
// Split into two modules:
//  - MacADTKit  : pure Foundation, no Apple API — all the decision logic, kept
//             unit-testable in isolation from the system.
//  - MacADTMac  : AppKit / libproc / SCDynamicStore / IOKit, entirely gated behind
//             `#if canImport(Darwin)` (the sources compile to nothing elsewhere).
let package = Package(
    name: "MacAppDeployToolkit",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "macadt-deploy", targets: ["MacAppDeployToolkitCLI"]),
        .executable(name: "macadt-deploy-ui", targets: ["MacAppDeployToolkitUI"]),
        .library(name: "MacADTKit", targets: ["MacADTKit"]),
    ],
    targets: [
        .target(name: "MacADTKit"),
        .target(name: "MacADTMac", dependencies: ["MacADTKit"]),
        .executableTarget(name: "MacAppDeployToolkitCLI", dependencies: ["MacADTKit", "MacADTMac"]),
        .executableTarget(name: "MacAppDeployToolkitUI", dependencies: ["MacADTKit", "MacADTMac"]),
        .testTarget(name: "MacADTKitTests", dependencies: ["MacADTKit"]),
    ]
)
