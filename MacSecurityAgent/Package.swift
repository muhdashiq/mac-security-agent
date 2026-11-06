// swift-tools-version:6.0
//
// MacSecurityAgent Swift package.
//
// * `MacSecurityCore` holds every non-UI component (camera pipeline, motion
//   detection, recording, monitoring coordinator, Telegram client, encrypted
//   upload queue, Keychain storage, power management).
// * `MacSecurityAgentSPM` is the SwiftUI menu-bar executable. It is only
//   declared when the manifest is evaluated on macOS. The Xcode project at the
//   repository root builds the same `Sources/App` files as a proper .app bundle.
//
// On Linux (CI / headless verification) the Apple-only files compile to empty
// units, and swift-crypto stands in for CryptoKit so that the encryption code
// path is still exercised by the tests. On macOS the package has no external
// dependencies.
import PackageDescription

var packageDependencies: [Package.Dependency] = []
var coreDependencies: [Target.Dependency] = []
var testDependencies: [Target.Dependency] = ["MacSecurityCore"]
var linuxTargets: [Target] = []

#if os(Linux)
packageDependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0"))
coreDependencies.append(.product(name: "Crypto", package: "swift-crypto"))
// Works around a Swift 6.0.x Linux link error in libswiftObservation.so.
linuxTargets.append(.target(name: "ObservationShim", path: "LinuxSupport/ObservationShim"))
testDependencies.append("ObservationShim")
#endif

var products: [Product] = [
    .library(name: "MacSecurityCore", targets: ["MacSecurityCore"]),
]

var targets: [Target] = [
    .target(
        name: "MacSecurityCore",
        dependencies: coreDependencies,
        path: "Sources",
        exclude: ["App"],
        sources: ["Camera", "Monitoring", "Telegram", "Storage", "Security", "Models", "Support"]
    ),
    .testTarget(
        name: "MacSecurityCoreTests",
        dependencies: testDependencies,
        path: "Tests"
    ),
] + linuxTargets

#if os(macOS)
products.append(.executable(name: "MacSecurityAgentSPM", targets: ["MacSecurityAgentSPM"]))
targets.append(
    .executableTarget(
        name: "MacSecurityAgentSPM",
        dependencies: ["MacSecurityCore"],
        path: "Sources/App"
    )
)
#endif

let package = Package(
    name: "MacSecurityAgent",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: packageDependencies,
    targets: targets,
    swiftLanguageModes: [.v6]
)
