// swift-tools-version: 5.9
import PackageDescription
import Foundation

let vpn = ProcessInfo.processInfo.environment["VIBE_BUILD_VPN"] == "1"
var appDependencies: [Target.Dependency] = ["VibeMonitoringCore"]
if vpn { appDependencies.append("VibeXray") }

let package = Package(
    name: "VibeMonitoring",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VibeMonitoring", targets: ["VibeMonitoring"]),
        .executable(name: "vibe-monitoring-scan", targets: ["VibeMonitoringScan"]),
    ] + (vpn ? [
        .executable(name: "VibeTunnel", targets: ["VibeTunnel"]),
        .executable(name: "vibe-vpn-check", targets: ["vibe-vpn-check"]),
    ] : []),
    targets: [
        .target(name: "VibeMonitoringCore"),
        .executableTarget(name: "VibeMonitoring", dependencies: appDependencies,
                          swiftSettings: vpn ? [.define("VIBE_VPN")] : []),
        .executableTarget(name: "VibeMonitoringScan", dependencies: ["VibeMonitoringCore"]),
        .testTarget(name: "VibeMonitoringCoreTests", dependencies: ["VibeMonitoringCore"]),
    ] + (vpn ? [
        .binaryTarget(name: "LibXray", path: "Vendor/LibXray.xcframework"),
        .target(name: "VibeXray", dependencies: ["LibXray", "VibeMonitoringCore"],
                linkerSettings: [.linkedFramework("Security"), .linkedFramework("CoreFoundation"), .linkedLibrary("resolv")]),
        .executableTarget(name: "VibeTunnel", dependencies: ["VibeXray", "VibeMonitoringCore"]),
        .executableTarget(name: "vibe-vpn-check", dependencies: ["VibeXray", "VibeMonitoringCore"], path: "Sources/VibeVPNCheck"),
    ] : [])
)
