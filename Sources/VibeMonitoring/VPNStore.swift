import Combine
import AppKit
import Foundation
import NetworkExtension
import SwiftUI
import SystemExtensions
import VibeMonitoringCore
import os
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
    @Published private(set) var providerDiagnostics: VPNProviderDiagnostics?
    @Published private(set) var traffic: VPNTrafficRate?
    @Published private(set) var networkReport: VPNConnectivityReport?
    @Published private(set) var networkReportContext = ""
    @Published private(set) var checkingNetwork = false
    @Published private(set) var probingServers = false
    @Published private(set) var serverResultsAt: Date?
    @Published private(set) var serverResults: [String: VPNServerProbeResult] = [:]
    private var trafficSample: VPNTrafficSample?
    let networkLock: NetworkLockStore
    private var lockObservation: AnyCancellable?
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
        networkLock = NetworkLockStore(demo: demo)
        signed = !demo && VPNInstallation.signingReady
        super.init()
        lockObservation = networkLock.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        guard !demo else { state = .off; return }
        requested = UserDefaults.standard.bool(forKey: "vpnProtectionRequested")
        do { subscription = try VPNKeychain.loadSubscription() }
        catch { issue = "Saved subscription is unavailable. Unlock Keychain or import it again." }
        state = requested || networkLock.wantsLock ? .unverified : .off
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

    func probeServers() {
        guard !demo, !probingServers, let nodes = subscription?.nodes else { return }
        probingServers = true
        Task {
            defer { probingServers = false }
            serverResults = [:]; serverResultsAt = nil
            // Three concurrent handshakes at most, only on explicit request.
            for offset in stride(from: 0, to: min(nodes.count, 200), by: 3) {
                let batch = Array(nodes[offset..<min(offset + 3, nodes.count, 200)])
                await withTaskGroup(of: (String, VPNServerProbeResult).self) { group in
                    for node in batch { group.addTask { (node.id, await VPNServerProbe.measure(host: node.host, port: node.port)) } }
                    for await (id, result) in group { serverResults[id] = result }
                }
            }
            serverResultsAt = Date()
        }
    }

    func checkNetwork() {
        guard !demo, !checkingNetwork else { return }
        checkingNetwork = true
        networkReport = nil
        let selection = subscription?.selectedID
        let initialState = state
        let context = state == .connected ? "Our VPN · " + (subscription?.selected?.name ?? "selected server")
            : "Current network · our VPN is not confirmed active; another VPN may carry this test"
        Task {
            let report = await VPNConnectivityCheck.run()
            networkReportContext = context + (selection != subscription?.selectedID || initialState != state ? " · network mode changed during test; repeat" : " · at test start")
            networkReport = report
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
            let previousPolicy = networkLock.policy
            var policyChanged = false
            var committed = false
            var liveInterface: String?
            state = .connecting
            do {
                guard let manager = try await loadManager(), policyValid(manager),
                      manager.connection.status == .connected,
                      let configuration = manager.protocolConfiguration as? NETunnelProviderProtocol,
                      let session = manager.connection as? NETunnelProviderSession else { throw VPNError.providerUnavailable }
                guard networkLock.confirmed, previousPolicy?.mode == .protected,
                      previousPolicy?.nodeID == next.selectedID else { throw VPNError.providerUnavailable }
                let addresses = try await VPNEndpointResolver.resolve(node.host)
                let reference = try await VPNCredentialClient.store(node)
                let endpoints = try addresses.map { try NetworkLockEndpoint(ip: $0, port: node.port) }
                let oldHealth = try JSONDecoder().decode(VPNProviderHealth.self, from: await Self.providerReply(session))
                guard oldHealth.nodeID == next.selectedID, oldHealth.running, !oldHealth.reasserting,
                      let interface = oldHealth.interfaceName else { throw VPNError.providerUnavailable }
                liveInterface = interface
                policyChanged = true
                try await networkLock.apply(.init(mode: .protected, endpoints: endpoints,
                                                  tunnelInterface: interface, nodeID: node.id))
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
                guard health.nodeID == node.id, health.running, !health.reasserting,
                      let name = health.interfaceName, let policy = networkLock.policy else { throw VPNError.providerUnavailable }
                let filter = try await NetworkLockClient.status(binding: .init(nodeID: node.id, interface: name))
                guard filter.confirms(policy), filter.tunnelInterface == name else { throw VPNError.providerUnavailable }
                state = .connecting
            } catch {
                if policyChanged, !committed, let previousPolicy, previousPolicy.mode == .protected {
                    // Restore the old endpoints on the still-live interface; a rollback without it would
                    // drop the provider's binding and stall protected traffic until the next renewal.
                    let rollback = (try? NetworkLockPolicy(mode: .protected, endpoints: previousPolicy.endpoints,
                                                           tunnelInterface: liveInterface,
                                                           revision: previousPolicy.revision,
                                                           nodeID: previousPolicy.nodeID)) ?? previousPolicy
                    try? await networkLock.apply(rollback)
                }
                state = .unverified
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
        guard engineAvailable, signed, installed, networkLock.installed,
              let node = subscription?.selected else { issue = VPNError.signingRequired.localizedDescription; return }
        busy = true
        issue = nil
        Task {
            defer { busy = false }
            do {
                let manager = try await loadManager() ?? NETunnelProviderManager()
                let addresses: [String]
                if networkLock.wantsLock {
                    guard let saved = manager.protocolConfiguration as? NETunnelProviderProtocol,
                          saved.providerConfiguration?["nodeID"] as? String == node.id,
                          let cached = saved.providerConfiguration?["bootstrapAddresses"] as? [String] else {
                        issue = "This server has no cached endpoint addresses. Allow direct Internet explicitly to resolve it, or reconnect the previous server."
                        return
                    }
                    addresses = try VPNTunnelConfiguration.validatedAddresses(cached)
                } else { addresses = try await VPNEndpointResolver.resolve(node.host) }
                let reference = try await VPNCredentialClient.store(node)
                let endpoints = try addresses.map { try NetworkLockEndpoint(ip: $0, port: node.port) }
                try await networkLock.apply(.init(mode: .protected, endpoints: endpoints, nodeID: node.id))
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
                // The independent lock handles a missing tunnel; On Demand would evict another VPN such as Happ.
                manager.onDemandRules = []
                manager.isOnDemandEnabled = false
                requested = true
                state = .connecting
                UserDefaults.standard.set(true, forKey: "vpnProtectionRequested")
                try await save(manager)
                try await reload(manager)
                guard policyValid(manager) else { throw VPNError.invalidConfiguration }
                try manager.connection.startVPNTunnel()
            } catch {
                state = .unverified
                let detail = (error as? VPNCredentialFailure)?.localizedDescription
                    ?? (error as? VPNError)?.localizedDescription
                    ?? "VPN configuration or connection failed (code \((error as NSError).code))."
                issue = detail + (requested ? " Protection is not confirmed; the protection request remains enabled."
                                          : " No VPN configuration was enabled.")
            }
        }
    }

    func pause() { setNetworkMode(.paused) }
    func allowDirect(quit: Bool = false) { setNetworkMode(.directAllowed, quit: quit) }

    private func setNetworkMode(_ mode: NetworkLockMode, quit: Bool = false) {
        guard !demo, !busy else { return }
        busy = true; issue = nil
        Task {
            defer { busy = false }
            do {
                try await VPNNetworkTransition.perform(mode: mode,
                    stopTunnel: { try await self.retireTunnel(remove: mode == .directAllowed) },
                    applyLock: { try await self.networkLock.apply(.init(mode: $0)) })
                requested = false
                UserDefaults.standard.set(false, forKey: "vpnProtectionRequested")
                state = mode == .paused ? .blocked : .off
                traffic = nil; trafficSample = nil
                if quit { NSApp.terminate(nil) }
            } catch {
                state = .unverified
                issue = networkLock.issue ?? "Network recovery was not confirmed. Retry Allow direct Internet, or open macOS VPN & Filters to disable only VibeMonitoring's VPN and Network Lock."
            }
        }
    }

    private func retireTunnel(remove: Bool) async throws {
        // Recovery handles every profile of ours, including duplicates left by an interrupted save or upgrade;
        // the strict single-profile check would otherwise make explicit unlock impossible.
        for manager in try await loadManagers() {
            manager.isOnDemandEnabled = false
            manager.onDemandRules = []
            manager.isEnabled = false
            try await save(manager)
            try await reload(manager)
            guard !manager.isEnabled, !manager.isOnDemandEnabled else { throw VPNError.invalidConfiguration }
            manager.connection.stopVPNTunnel()
            if remove {
                // Retire includeAllNetworks routing and stale session IPC; subscription and credentials stay in Keychain.
                try await withCheckedThrowingContinuation { (next: CheckedContinuation<Void, Error>) in
                    manager.removeFromPreferences { error in
                        if let error { next.resume(throwing: error) } else { next.resume() }
                    }
                }
            }
            for _ in 0..<40 {
                if [.invalid, .disconnected].contains(manager.connection.status) { break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            guard [.invalid, .disconnected].contains(manager.connection.status) else {
                throw VPNError.providerUnavailable
            }
        }
        if remove { guard try await loadManagers().isEmpty else { throw VPNError.providerUnavailable } }
        Logger(subsystem: "dev.vibemonitoring.app", category: "network-mode")
            .notice("Own VPN retired; profile removed: \(remove, privacy: .public)")
    }

    var statusTitle: String {
        if networkLock.disabledOutsideApp { return "Network lock disabled in macOS · direct traffic not blocked" }
        if networkLock.locked && !requested { return "Network locked · VPN paused" }
        if (networkLock.wantsLock || networkLock.policy != nil) && !networkLock.confirmed { return "Network lock not confirmed" }
        if state == .blocked && networkLock.confirmed { return "Network locked · VPN not connected" }
        if state == .off { return "Direct access allowed" }
        return state.title
    }

    private func refresh() async {
        guard !busy, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await networkLock.refresh()
        do {
            guard let manager = try await loadManager() else {
                traffic = nil; trafficSample = nil; providerDiagnostics = nil
                state = networkLock.locked ? .blocked : (requested || networkLock.wantsLock ? .unverified : .off); return
            }
            guard !busy else { return }
            if manager.isEnabled && !requested {
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
            providerDiagnostics = health?.diagnostics
            guard manager.connection.status == status else {
                traffic = nil; trafficSample = nil; providerDiagnostics = nil
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
            if networkLock.locked && !requested { state = .blocked }
            else if networkLock.wantsLock || requested || networkLock.policy != nil {
                if !networkLock.confirmed { state = .unverified }
                else if requested, status == .disconnected, networkLock.policy?.nodeID == subscription?.selectedID { state = .blocked }
                else if state == .connected,
                        networkLock.policy?.nodeID != subscription?.selectedID || health?.interfaceName == nil
                        || networkLock.health?.tunnelInterface != health?.interfaceName { state = .unverified }
            }
            if state == .connected, let name = health?.interfaceName, let sample = VPNTrafficSample.read(name) {
                traffic = VPNTrafficRate.between(trafficSample, sample)
                trafficSample = sample
            } else { traffic = nil; trafficSample = nil }
            if state == .connected && issue == VPNError.providerUnavailable.localizedDescription { issue = nil }
        } catch {
            guard !busy else { return }
            state = networkLock.locked ? .blocked : (requested || networkLock.wantsLock ? .unverified : .off)
            traffic = nil; trafficSample = nil; providerDiagnostics = nil
            if requested { issue = VPNError.providerUnavailable.localizedDescription }
        }
    }

    private func policyValid(_ manager: NETunnelProviderManager) -> Bool {
        guard manager.isEnabled, !manager.isOnDemandEnabled,
              let configuration = manager.protocolConfiguration as? NETunnelProviderProtocol,
              configuration.providerBundleIdentifier == VPNInstallation.providerID,
              configuration.includeAllNetworks, configuration.enforceRoutes, !configuration.excludeLocalNetworks,
              !configuration.disconnectOnSleep, configuration.passwordReference != nil,
              let addresses = configuration.providerConfiguration?["bootstrapAddresses"] as? [String],
              (try? VPNTunnelConfiguration.validatedAddresses(addresses)) != nil,
              (manager.onDemandRules ?? []).isEmpty else { return false }
        if #available(macOS 13.3, *), configuration.excludeAPNs || configuration.excludeCellularServices { return false }
        if #available(macOS 14.4, *), configuration.excludeDeviceCommunication { return false }
        return true
    }

    private func loadManager() async throws -> NETunnelProviderManager? {
        let own = try await loadManagers()
        guard own.count <= 1 else { throw VPNError.invalidConfiguration }
        return own.first
    }

    private func loadManagers() async throws -> [NETunnelProviderManager] {
        let all: [NETunnelProviderManager] = try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { values, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: values ?? []) }
            }
        }
        return all.filter { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == VPNInstallation.providerID }
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
