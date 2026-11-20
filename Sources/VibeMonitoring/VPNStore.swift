import AppKit
import Foundation
import NetworkExtension
import SwiftUI
import SystemExtensions
import VibeMonitoringCore
#if VIBE_VPN
import VibeXray
#endif

@MainActor
final class VPNStore: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published private(set) var subscription: VPNSubscription?
    @Published private(set) var state: VPNProtectionState = .unavailable
    @Published private(set) var issue: String?
    @Published private(set) var busy = false
    @Published private(set) var installed = false
    @Published private(set) var requested = false
    @Published private(set) var traffic: VPNTrafficRate?
    @Published private(set) var networkReport: VPNConnectivityReport?
    @Published private(set) var checkingNetwork = false
    private var trafficSample: VPNTrafficSample?
    let demo: Bool
    private var polling: Task<Void, Never>?
    private var activation: OSSystemExtensionRequest?
    private var refreshing = false
    private let client = VPNSubscriptionClient()
    private let signed: Bool

    var engineAvailable: Bool {
        #if VIBE_VPN
        return true
        #else
        return false
        #endif
    }

    init(demo: Bool) {
        self.demo = demo
        signed = !demo && VPNInstallation.signingReady
        super.init()
        guard !demo else { state = .off; return }
        requested = UserDefaults.standard.bool(forKey: "vpnProtectionRequested")
        do { subscription = try VPNKeychain.loadSubscription() }
        catch { issue = "Saved subscription is unavailable. Unlock Keychain or import it again." }
        state = requested ? .unverified : .off
        if signed {
            let query = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: VPNInstallation.providerID, queue: .main)
            query.delegate = self
            OSSystemExtensionManager.shared.submitRequest(query)
            polling = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
    }

    deinit { polling?.cancel() }

    func checkNetwork() {
        guard !demo, !checkingNetwork else { return }
        checkingNetwork = true
        Task {
            networkReport = await VPNConnectivityCheck.run()
            checkingNetwork = false
        }
    }

    func importSubscription(_ text: String) {
        guard !demo, !busy, !requested else { return }
        #if VIBE_VPN
        busy = true
        issue = nil
        Task {
            defer { busy = false }
            do {
                let url = try VPNSubscriptionClient.url(text)
                let body = try await client.fetch(url)
                let nodes = try await Task.detached(priority: .utility) { try XrayCore.importSubscription(body) }.value
                let value = try VPNSubscription(sourceURL: url.absoluteString, nodes: nodes, selectedID: subscription?.selectedID)
                try VPNKeychain.saveSubscription(value)
                subscription = value
            } catch { issue = error.localizedDescription }
        }
        #else
        issue = VPNError.engineMissing.localizedDescription
        #endif
    }

    func select(_ id: String) {
        guard !demo, !busy, var next = subscription, next.selectedID != id,
              let node = next.nodes.first(where: { $0.id == id }) else { return }
        if requested { switchServer(node, subscription: next); return }
        next.selectedID = id
        do { try VPNKeychain.saveSubscription(next); subscription = next }
        catch { issue = VPNError.keychainUnavailable.localizedDescription }
    }

    private func switchServer(_ node: VPNNode, subscription next: VPNSubscription) {
        busy = true
        issue = nil
        Task {
            defer { busy = false }
            var committed = false
            do {
                guard let manager = try await loadManager(), policyValid(manager),
                      manager.connection.status == .connected,
                      let configuration = manager.protocolConfiguration as? NETunnelProviderProtocol,
                      let session = manager.connection as? NETunnelProviderSession else { throw VPNError.providerUnavailable }
                let addresses = try await VPNEndpointResolver.resolve(node.host)
                let reference = try await VPNCredentialClient.store(node)
                let change = try VPNServerChange(nodeID: node.id, reference: reference, addresses: addresses)
                configuration.serverAddress = node.host
                configuration.passwordReference = reference
                configuration.providerConfiguration = ["nodeID": node.id, "bootstrapAddresses": addresses]
                manager.protocolConfiguration = configuration
                try await save(manager)
                committed = true
                var updated = next
                updated.selectedID = node.id
                subscription = updated
                // Persist the new intent before contacting the provider; a failed reply must never show old health as green.
                try VPNKeychain.saveSubscription(updated)
                state = .connecting
                let reply = try await Self.providerReply(session, message: JSONEncoder().encode(change), timeout: 10)
                let health = try JSONDecoder().decode(VPNProviderHealth.self, from: reply)
                guard health.nodeID == node.id else { throw VPNError.providerUnavailable }
                state = .connecting
            } catch {
                if committed { state = .unverified }
                issue = "Server change was not confirmed. The protection request remains enabled."
            }
        }
    }

    func install() {
        guard !demo, !busy else { return }
        guard engineAvailable, signed else { issue = VPNError.signingRequired.localizedDescription; return }
        guard Bundle.main.bundleURL.resolvingSymlinksInPath().path.hasPrefix("/Applications/") else {
            issue = "Move the signed VPN app to /Applications before installing the network extension."
            return
        }
        busy = true
        issue = nil
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: VPNInstallation.providerID, queue: .main)
        activation = request
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func enable() {
        guard !demo, !busy else { return }
        guard engineAvailable, signed, installed,
              let node = subscription?.selected else { issue = VPNError.signingRequired.localizedDescription; return }
        busy = true
        issue = nil
        Task {
            defer { busy = false }
            do {
                let manager = try await loadManager() ?? NETunnelProviderManager()
                let addresses = try await VPNEndpointResolver.resolve(node.host)
                let reference = try await VPNCredentialClient.store(node)
                let configuration = NETunnelProviderProtocol()
                configuration.providerBundleIdentifier = VPNInstallation.providerID
                configuration.serverAddress = node.host
                configuration.passwordReference = reference
                configuration.providerConfiguration = ["nodeID": node.id, "bootstrapAddresses": addresses]
                configuration.includeAllNetworks = true
                configuration.enforceRoutes = true
                configuration.excludeLocalNetworks = false
                configuration.disconnectOnSleep = false
                if #available(macOS 13.3, *) { configuration.excludeAPNs = false; configuration.excludeCellularServices = false }
                if #available(macOS 14.4, *) { configuration.excludeDeviceCommunication = false }
                manager.protocolConfiguration = configuration
                manager.localizedDescription = "VibeMonitoring"
                manager.isEnabled = true
                let rule = NEOnDemandRuleConnect()
                rule.interfaceTypeMatch = .any
                manager.onDemandRules = [rule]
                manager.isOnDemandEnabled = true
                requested = true
                state = .connecting
                UserDefaults.standard.set(true, forKey: "vpnProtectionRequested")
                try await save(manager)
                try await reload(manager)
                guard policyValid(manager) else { throw VPNError.invalidConfiguration }
                try manager.connection.startVPNTunnel()
            } catch {
                state = requested ? .unverified : .off
                let detail = (error as? VPNCredentialFailure)?.localizedDescription
                    ?? (error as? VPNError)?.localizedDescription
                    ?? "VPN configuration or connection failed (code \((error as NSError).code))."
                issue = detail + (requested ? " Protection is not confirmed; the protection request remains enabled."
                                          : " No VPN configuration was enabled.")
            }
        }
    }

    func disable() {
        guard !demo, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                if let manager = try await loadManager() {
                    manager.isOnDemandEnabled = false
                    manager.isEnabled = false
                    try await save(manager)
                    try await reload(manager)
                    guard !manager.isEnabled, !manager.isOnDemandEnabled else { throw VPNError.invalidConfiguration }
                    manager.connection.stopVPNTunnel()
                }
                requested = false
                UserDefaults.standard.set(false, forKey: "vpnProtectionRequested")
                state = .off
                issue = nil
            } catch { state = .unverified; issue = "Protection could not be disabled. Check the VPN configuration in macOS Settings." }
        }
    }

    private func refresh() async {
        guard !busy, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            guard let manager = try await loadManager() else { state = requested ? .unverified : .off; return }
            guard !busy else { return }
            if manager.isEnabled && manager.isOnDemandEnabled && !requested {
                requested = true
                UserDefaults.standard.set(true, forKey: "vpnProtectionRequested")
            }
            let status = manager.connection.status
            var health: VPNProviderHealth?
            if status == .connected || status == .reasserting, let session = manager.connection as? NETunnelProviderSession {
                let body = try await Self.providerReply(session)
                guard !busy else { return }
                health = try JSONDecoder().decode(VPNProviderHealth.self, from: body)
            }
            guard manager.connection.status == status else {
                state = requested ? .unverified : .off
                return
            }
            let system: String
            switch status {
            case .connected: system = "connected"
            case .connecting: system = "connecting"
            case .reasserting: system = "reasserting"
            default: system = "disconnected"
            }
            state = VPNProtectionState.evaluate(requested: requested, policyValid: policyValid(manager), system: system,
                                                 health: health, healthAge: health == nil ? nil : 0,
                                                 expectedNodeID: subscription?.selectedID)
            if state == .connected, let name = health?.interfaceName, let sample = VPNTrafficSample.read(name) {
                traffic = VPNTrafficRate.between(trafficSample, sample)
                trafficSample = sample
            } else { traffic = nil; trafficSample = nil }
            if state == .connected { issue = nil }
        } catch {
            guard !busy else { return }
            state = requested ? .unverified : .off
            traffic = nil; trafficSample = nil
            if requested { issue = VPNError.providerUnavailable.localizedDescription }
        }
    }

    private func policyValid(_ manager: NETunnelProviderManager) -> Bool {
        guard manager.isEnabled, manager.isOnDemandEnabled,
              let configuration = manager.protocolConfiguration as? NETunnelProviderProtocol,
              configuration.providerBundleIdentifier == VPNInstallation.providerID,
              configuration.includeAllNetworks, configuration.enforceRoutes, !configuration.excludeLocalNetworks,
              !configuration.disconnectOnSleep, configuration.passwordReference != nil,
              let addresses = configuration.providerConfiguration?["bootstrapAddresses"] as? [String],
              (try? VPNTunnelConfiguration.validatedAddresses(addresses)) != nil,
              let rules = manager.onDemandRules, rules.count == 1, let rule = rules.first as? NEOnDemandRuleConnect,
              rule.interfaceTypeMatch == .any, rule.ssidMatch == nil, rule.dnsSearchDomainMatch == nil,
              rule.dnsServerAddressMatch == nil, rule.probeURL == nil else { return false }
        if #available(macOS 13.3, *), configuration.excludeAPNs || configuration.excludeCellularServices { return false }
        if #available(macOS 14.4, *), configuration.excludeDeviceCommunication { return false }
        return true
    }

    private func loadManager() async throws -> NETunnelProviderManager? {
        let all: [NETunnelProviderManager] = try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { values, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: values ?? []) }
            }
        }
        let own = all.filter { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == VPNInstallation.providerID }
        guard own.count <= 1 else { throw VPNError.invalidConfiguration }
        return own.first
    }

    private func save(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func reload(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func providerReply(_ session: NETunnelProviderSession, message: Data = Data("status".utf8), timeout: Double = 2) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let reply = VPNReply(continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { reply.complete(.failure(VPNError.providerUnavailable)) }
            do {
                try session.sendProviderMessage(message) { data in
                    if let data, data.count <= 4_096 { reply.complete(.success(data)) }
                    else { reply.complete(.failure(VPNError.providerUnavailable)) }
                }
            } catch { reply.complete(.failure(VPNError.providerUnavailable)) }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in issue = "Approve VibeMonitoring's network extension in macOS Settings." }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            guard request === activation else { return }
            busy = false
            installed = result == .completed
            issue = installed ? nil : "Restart macOS to finish installing the network extension."
            activation = nil
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            if request === activation {
                busy = false
                issue = "Network extension installation failed (\((error as NSError).code)). Check signing and provisioning."
                activation = nil
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let enabled = properties.contains {
            $0.bundleIdentifier == VPNInstallation.providerID && $0.isEnabled
                && $0.bundleShortVersion == version && $0.bundleVersion == build
        }
        Task { @MainActor in installed = enabled }
    }
}

private final class VPNReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }
    func complete(_ result: Result<Data, Error>) {
        lock.lock()
        let next = continuation
        continuation = nil
        lock.unlock()
        next?.resume(with: result)
    }
}
