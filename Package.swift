// swift-tools-version: 6.0
import PackageDescription

// Tools version 6.0 is required for SwiftPM to wire up swift-testing, but the
// sources stay in Swift 5 language mode: strict concurrency would force
// annotations on the AppKit surface for no real safety gain in a single-process
// menu bar app.
let package = Package(
    name: "Notch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NotchApp", targets: ["NotchApp"]),
        .executable(name: "notchctl", targets: ["notchctl"]),
        .library(name: "NotchCore", targets: ["NotchCore"]),
    ],
    targets: [
        .target(name: "NotchCore"),
        .executableTarget(name: "NotchApp", dependencies: ["NotchCore"]),
        .executableTarget(name: "notchctl", dependencies: ["NotchCore"]),
        .testTarget(name: "NotchCoreTests", dependencies: ["NotchCore"]),
    ],
    swiftLanguageModes: [.v5]
)
