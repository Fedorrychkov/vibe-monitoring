import Foundation
import NetworkExtension
import VibeMonitoringCore

@MainActor
enum VPNReadOnlyDiagnostics {
    static func collect(checkNetwork: Bool = false) async throws -> Data {
        var report: [String: Any] = ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                                     "readOnly": true]
        let subscription = try? VPNKeychain.loadSubscription()
        if let selected = subscription?.selected {
            let metadata = try VPNNodeDiagnostics(selected)
            report["selectedNode"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata))
        } else { report["selectedNode"] = "unavailable" }
        let managers: [NETunnelProviderManager] = try await withCheckedThrowingContinuation { next in
            NETunnelProviderManager.loadAllFromPreferences { values, error in
                if let error { next.resume(throwing: error) } else { next.resume(returning: values ?? []) }
            }
        }
        let own = managers.filter { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == VPNInstallation.providerID }
        report["vpnConfigurationCount"] = own.count
        if own.count == 1, let manager = own.first,
           let configuration = manager.protocolConfiguration as? NETunnelProviderProtocol {
            report["vpn"] = ["status": manager.connection.status.rawValue, "enabled": manager.isEnabled,
                             "onDemand": manager.isOnDemandEnabled, "includeAllNetworks": configuration.includeAllNetworks]
            let addresses = configuration.providerConfiguration?["bootstrapAddresses"] as? [String] ?? []
            report["bootstrapFamilies"] = ["IPv4": addresses.filter { !$0.contains(":") }.count,
                                            "IPv6": addresses.filter { $0.contains(":") }.count]
            if [.connected, .reasserting].contains(manager.connection.status), let session = manager.connection as? NETunnelProviderSession {
                if let health = try? await providerHealth(session) {
                    report["provider"] = ["running": health.running, "reasserting": health.reasserting,
                                          "matchesSelectedNode": health.nodeID == subscription?.selectedID]
                    if let diagnostics = health.diagnostics {
                        report["providerCounters"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagnostics))
                    }
                } else { report["provider"] = "unavailable" }
            }
        }
        let filter = NEFilterManager.shared()
        let filterLoaded: Bool = await withCheckedContinuation { next in
            filter.loadFromPreferences { error in next.resume(returning: error == nil) }
        }
        if filterLoaded, !filter.isEnabled,
           filter.providerConfiguration?.filterPacketProviderBundleIdentifier == NetworkLockStore.identifier,
           let data = filter.providerConfiguration?.vendorConfiguration?["policy"] as? Data,
           let policy = try? NetworkLockPolicy.decode(data) {
            report["networkLock"] = ["enabled": false, "mode": policy.mode.rawValue,
                                      "confirmation": "OS configuration; packet filter disabled"]
        } else if let health = try? await NetworkLockClient.status() {
            report["networkLock"] = ["active": health.active, "validPolicy": health.validPolicy,
                                      "mode": health.mode?.rawValue ?? "unknown", "hasBoundTunnel": health.tunnelInterface != nil]
            if let count = health.preservedPolicyReloads { report["preservedLockPolicyReloads"] = count }
        } else { report["networkLock"] = "unavailable" }
        if checkNetwork {
            let checks = await VPNConnectivityCheck.run()
            report["networkChecks"] = checks.results.map { value -> [String: Any] in
                var result: [String: Any] = ["name": value.id, "passed": value.passed, "milliseconds": value.milliseconds]
                if let status = value.status { result["status"] = status }
                if let detail = value.detail { result["detail"] = detail }
                return result
            }
        }
        return try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    }

    private static func providerHealth(_ session: NETunnelProviderSession) async throws -> VPNProviderHealth {
        let data: Data = try await withCheckedThrowingContinuation { next in
            let reply = DiagnosticReply(next)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { reply.finish(nil) }
            do { try session.sendProviderMessage(Data("status".utf8)) { reply.finish($0) } }
            catch { reply.finish(nil) }
        }
        return try JSONDecoder().decode(VPNProviderHealth.self, from: data)
    }
}

private final class DiagnosticReply: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CheckedContinuation<Data, Error>?
    init(_ pending: CheckedContinuation<Data, Error>) { self.pending = pending }
    func finish(_ value: Data?) {
        lock.lock(); let next = pending; pending = nil; lock.unlock()
        guard let next else { return }
        if let value, value.count <= 4_096 { next.resume(returning: value) }
        else { next.resume(throwing: VPNError.providerUnavailable) }
    }
}
