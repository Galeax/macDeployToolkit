// swift-tools-version:5.9
import PackageDescription

// Zero external dependency, deliberately: this binary runs as root on production
// devices, and the supply-chain surface must stay nil. Corollary: argument
// parsing and the manifest format (JSON, via Foundation) are hand-written.
//
// Split into two modules:
//  - MDTKit  : pure Foundation, no Apple API — all the decision logic, kept
//             unit-testable in isolation from the system.
//  - MDTMac  : AppKit / libproc / SCDynamicStore / IOKit, entirely gated behind
//             `#if canImport(Darwin)` (the sources compile to nothing elsewhere).
let package = Package(
    name: "MacDeployToolkit",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "macdeploy", targets: ["MacDeployToolkitCLI"]),
        .executable(name: "macdeploy-ui", targets: ["MacDeployToolkitUI"]),
        .library(name: "MDTKit", targets: ["MDTKit"]),
    ],
    targets: [
        .target(name: "MDTKit"),
        .target(name: "MDTMac", dependencies: ["MDTKit"]),
        .executableTarget(name: "MacDeployToolkitCLI", dependencies: ["MDTKit", "MDTMac"]),
        .executableTarget(name: "MacDeployToolkitUI", dependencies: ["MDTKit", "MDTMac"]),
        .testTarget(name: "MDTKitTests", dependencies: ["MDTKit"]),
    ]
)
