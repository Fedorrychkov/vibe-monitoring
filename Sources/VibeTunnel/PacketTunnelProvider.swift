import Darwin
import Foundation
import NetworkExtension
import os
import VibeMonitoringCore
import VibeXray

@objc(VibePacketTunnelProvider)
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let work = DispatchQueue(label: "dev.vibemonitoring.tunnel-core")
    private var node: VPNNode?
    private var resolvedAddresses: [String] = []
    private var stopping = false
    private var running = false
    private var issue: String?
    private var watchdog: DispatchSourceTimer?
    private var pathObservation: NSKeyValueObservation?
    private var retryDelay: Double = 1
    private var retryAt: Double = 0

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        work.async { [self] in
            var stage = "configuration"
            do {
                self.stopping = false
                self.running = false
                self.watchdog?.cancel()
                self.pathObservation = nil
                _ = try? XrayCore.invoke("stopXray")
                guard let configuration = self.protocolConfiguration as? NETunnelProviderProtocol,
                      configuration.includeAllNetworks, configuration.enforceRoutes, !configuration.excludeLocalNetworks,
                      let reference = configuration.passwordReference else { throw VPNError.invalidConfiguration }
                stage = "credential-read"
                let node = try VPNKeychain.loadSelected(reference: reference)
                guard configuration.providerConfiguration?["nodeID"] as? String == node.id else { throw VPNError.invalidConfiguration }
                self.node = node
                stage = "bootstrap-addresses"
                guard let saved = configuration.providerConfiguration?["bootstrapAddresses"] as? [String] else {
                    throw VPNError.invalidConfiguration
                }
                let addresses = try VPNTunnelConfiguration.validatedAddresses(saved)
                self.resolvedAddresses = addresses
                let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: addresses[0])
                settings.mtu = 1_400
                let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.0"])
                ipv4.includedRoutes = [NEIPv4Route.default()]
                settings.ipv4Settings = ipv4
                let ipv6 = NEIPv6Settings(addresses: ["fd74:7662:6500::1"], networkPrefixLengths: [64])
                ipv6.includedRoutes = [NEIPv6Route.default()]
                settings.ipv6Settings = ipv6
                let dns = NEDNSSettings(servers: ["1.1.1.1", "2606:4700:4700::1111"])
                dns.matchDomains = [""]
                dns.matchDomainsNoSearch = true
                settings.dnsSettings = dns
                self.setTunnelNetworkSettings(settings) { error in
                    self.work.async {
                        if let error {
                            self.failStartup(stage: "network-settings", error: error, completionHandler: completionHandler)
                            return
                        }
                        do {
                            guard !self.stopping else { throw VPNError.providerUnavailable }
                            try self.startCore(node, addresses: addresses)
                            self.installWatchdog()
                            self.pathObservation = self.observe(\.defaultPath, options: [.new]) { [weak self] _, _ in
                                self?.work.async { [weak self] in self?.requestRestart() }
                            }
                            completionHandler(nil)
                        } catch {
                            self.failStartup(stage: "core-startup", error: error, completionHandler: completionHandler)
                        }
                    }
                }
            } catch { self.failStartup(stage: stage, error: error, completionHandler: completionHandler) }
        }
    }

    private func failStartup(stage: String, error: Error, completionHandler: (Error?) -> Void) {
        // Fixed stages and numeric codes only; never log the selected node or configuration.
        let code = (error as? VPNCredentialFailure)?.status ?? Int32(clamping: (error as NSError).code)
        Logger(subsystem: "dev.vibemonitoring.app.tunnel", category: "startup")
            .error("Tunnel startup failed at \(stage, privacy: .public); code \(code, privacy: .public)")
        completionHandler(VPNError.invalidConfiguration)
    }

    private func startCore(_ node: VPNNode, addresses: [String]) throws {
        let fd = try tunnelDescriptor()
        let config = try VPNTunnelConfiguration.build(node: node, descriptor: fd, addresses: addresses)
        guard let json = String(data: config, encoding: .utf8) else { throw VPNError.invalidConfiguration }
        _ = try XrayCore.invoke("runXray", payload: ["xrayJson": json])
        guard try XrayCore.invoke("getXrayState")["running"] as? Bool == true else { throw VPNError.providerUnavailable }
        running = true
        issue = nil
        retryDelay = 1
        reasserting = false
    }

    private func installWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: work)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopping else { return }
            let alive = (try? XrayCore.invoke("getXrayState")["running"] as? Bool) == true
            if !alive || self.reasserting { self.recoverIfDue() }
        }
        watchdog = timer
        timer.resume()
    }

    private func requestRestart() {
        guard !stopping else { return }
        running = false
        reasserting = true
        issue = "network-reconnecting"
        retryAt = 0
        recoverIfDue()
    }

    private func recoverIfDue() {
        guard !stopping, let node else { return }
        running = false
        reasserting = true
        issue = "core-restarting"
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        guard now >= retryAt else { return }
        do {
            _ = try? XrayCore.invoke("stopXray")
            // Reuse bootstrap DNS while reasserting; resolving through the stopped tunnel can deadlock recovery.
            try startCore(node, addresses: resolvedAddresses)
        } catch {
            issue = "core-restart-failed"
            retryAt = now + retryDelay
            retryDelay = min(30, retryDelay * 2)
            // Keep the provider reasserting; never disable the VPN policy after a core failure.
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        work.async {
            self.stopping = true
            self.watchdog?.cancel()
            self.watchdog = nil
            self.pathObservation = nil
            _ = try? XrayCore.invoke("stopXray")
            self.running = false
            completionHandler()
        }
    }

    override func wake() { work.async { self.requestRestart() } }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard messageData == Data("status".utf8) else { completionHandler?(nil); return }
        work.async {
            let health = VPNProviderHealth(nodeID: self.node?.id ?? "", running: self.running,
                                           reasserting: self.reasserting, issue: self.issue)
            completionHandler?(try? JSONEncoder().encode(health))
        }
    }

    private func tunnelDescriptor() throws -> Int32 {
        // Identify our process's utun socket through public Darwin socket APIs, not KVC on packetFlow.
        for fd: Int32 in 0..<min(getdtablesize(), 4_096) {
            var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
            var length = socklen_t(name.count)
            if getsockopt(fd, SYSPROTO_CONTROL, 2, &name, &length) == 0,
               String(cString: name).hasPrefix("utun") { return fd }
        }
        throw VPNError.providerUnavailable
    }
}
