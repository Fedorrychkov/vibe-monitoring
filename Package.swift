// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VibeMonitoring",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VibeMonitoring", targets: ["VibeMonitoring"]),
        .executable(name: "vibe-monitoring-scan", targets: ["VibeMonitoringScan"]),
    ],
    targets: [
        .target(name: "VibeMonitoringCore"),
        .executableTarget(name: "VibeMonitoring", dependencies: ["VibeMonitoringCore"]),
        .executableTarget(name: "VibeMonitoringScan", dependencies: ["VibeMonitoringCore"]),
        .testTarget(name: "VibeMonitoringCoreTests", dependencies: ["VibeMonitoringCore"]),
    ]
)
