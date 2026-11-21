import Foundation
import NetworkExtension
import SwiftUI
import SystemExtensions
import VibeMonitoringCore
import os

@MainActor
final class NetworkLockStore: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published private(set) var policy: NetworkLockPolicy?
    @Published private(set) var health: NetworkLockHealth?
    @Published private(set) var installed = false
    @Published private(set) var busy = false
    @Published private(set) var issue: String?
    @Published private(set) var filterDisabledConfirmed = false
    private var activation: OSSystemExtensionRequest?
    private let demo: Bool
    private let signingReady: Bool
    nonisolated static let identifier = "dev.vibemonitoring.app.lock"
    var confirmed: Bool {
        if policy?.mode == .directAllowed && filterDisabledConfirmed { return true }
        guard let policy, let health else { return false }
        return health.confirms(policy)
    }
    var locked: Bool { confirmed && policy?.mode == .paused }
    var wantsLock: Bool { policy.map { $0.mode != .directAllowed } ?? UserDefaults.standard.bool(forKey: "networkLockRequested") }
    var ready: Bool { signingReady }

    init(demo: Bool) {
        self.demo = demo
        signingReady = !demo && VPNInstallation.ready(providerID: Self.identifier, capability: "content-filter-provider-systemextension")
        super.init()
        if !demo, ready {
            let request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: Self.identifier, queue: .main)
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    func refresh() async {
        guard !demo, !busy, ready else { return }
        do {
            let manager = try await load()
            guard !busy else { return }
            filterDisabledConfirmed = false
            guard let data = manager.providerConfiguration?.vendorConfiguration?["policy"] as? Data else {
                policy = nil; health = nil; return
            }
            policy = try NetworkLockPolicy.decode(data)
            if !manager.isEnabled {
                health = nil
                filterDisabledConfirmed = policy?.mode == .directAllowed
                return
            }
            let result = try await NetworkLockClient.status()
            guard !busy else { return }
            health = result
        } catch { health = nil; filterDisabledConfirmed = false }
    }

    func apply(_ value: NetworkLockPolicy) async throws {
        guard !demo, ready, installed, !busy else { throw VPNError.signingRequired }
        busy = true; issue = nil
        filterDisabledConfirmed = false
        defer { busy = false }
        do {
            let manager = try await load()
            let configuration = NEFilterProviderConfiguration()
            configuration.filterPackets = true
            configuration.filterSockets = false
            configuration.filterPacketProviderBundleIdentifier = Self.identifier
            configuration.vendorConfiguration = ["policy": try value.encoded()]
            manager.providerConfiguration = configuration
            manager.localizedDescription = "VibeMonitoring Network Lock"
            manager.grade = .firewall
            // An explicit unlock removes our filter from the packet path, including when its IPC is unavailable.
            manager.isEnabled = value.mode != .directAllowed
            // Record locked intent before saving. A failed acknowledgement must never imply direct access is safe.
            if value.mode != .directAllowed { UserDefaults.standard.set(true, forKey: "networkLockRequested") }
            try await withCheckedThrowingContinuation { (next: CheckedContinuation<Void, Error>) in
                manager.saveToPreferences { error in
                    if let error { next.resume(throwing: error) } else { next.resume() }
                }
            }
            policy = value; health = nil
            if value.mode == .directAllowed {
                let saved = try await load()
                guard !saved.isEnabled,
                      let data = saved.providerConfiguration?.vendorConfiguration?["policy"] as? Data,
                      let persisted = try? NetworkLockPolicy.decode(data),
                      persisted.mode == .directAllowed, persisted.revision == value.revision else {
                    throw VPNError.providerUnavailable
                }
                filterDisabledConfirmed = true
                UserDefaults.standard.set(false, forKey: "networkLockRequested")
                Logger(subsystem: "dev.vibemonitoring.app", category: "network-mode")
                    .notice("Direct access: own filter disabled in saved OS configuration")
                return
            }
            for _ in 0..<8 {
                if let result = try? await NetworkLockClient.status(), result.confirms(value) {
                    health = result
                    UserDefaults.standard.set(value.mode != .directAllowed, forKey: "networkLockRequested")
                    return
                }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            throw VPNError.providerUnavailable
        } catch {
            health = nil
            filterDisabledConfirmed = false
            issue = "Network lock change was not confirmed. Check macOS Network Filters; no automatic direct-access fallback was requested."
            throw error
        }
    }

    private func load() async throws -> NEFilterManager {
        let manager = NEFilterManager.shared()
        try await withCheckedThrowingContinuation { (next: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error { next.resume(throwing: error) } else { next.resume() }
            }
        }
        if let existing = manager.providerConfiguration?.filterPacketProviderBundleIdentifier,
           existing != Self.identifier { throw VPNError.invalidConfiguration }
        return manager
    }

    func install() {
        guard !demo, !busy, ready else { issue = VPNError.signingRequired.localizedDescription; return }
        guard Bundle.main.bundleURL.resolvingSymlinksInPath().path.hasPrefix("/Applications/") else {
            issue = "Move the signed app to /Applications first."; return
        }
        busy = true; issue = nil
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main)
        activation = request; request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }
    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in issue = "Approve VibeMonitoring Network Lock in macOS Settings." }
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            guard request === activation else { return }
            installed = result == .completed; busy = false; activation = nil
            issue = installed ? nil : "Restart macOS to complete installation."
        }
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let code = (error as NSError).code
        Task { @MainActor in
            guard request === activation else { return }
            busy = false; activation = nil
            issue = "Network lock installation failed (code \(code))."
        }
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let valid = properties.contains { $0.bundleIdentifier == Self.identifier && $0.isEnabled && $0.bundleVersion == build && $0.bundleShortVersion == version }
        Task { @MainActor in installed = valid }
    }
}
