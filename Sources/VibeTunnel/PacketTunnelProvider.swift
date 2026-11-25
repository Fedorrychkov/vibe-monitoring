import Darwin
import Foundation
import NetworkExtension
import os
import VibeMonitoringCore
import VibeXray

@objc(VibePacketTunnelProvider)
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let work = DispatchQueue(label: "dev.vibemonitoring.tunnel-core")
    private var node: VPNNode?
    private var resolvedAddresses: [String] = []
    private var stopping = false
    private var running = false
    private var issue: String?
    private var interfaceName: String?
    private var watchdog: DispatchSourceTimer?
    private var previousPath: NWPath?
    private var diagnostics = VPNProviderDiagnostics()
    private var pathObservation: NSKeyValueObservation?
    private var bindingInFlight = false
    private var retryDelay: Double = 1
    private var retryAt: Double = 0

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        Logger(subsystem: "dev.vibemonitoring.app.tunnel", category: "lifecycle").notice("Tunnel start requested")
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
                let settings = try VPNTunnelConfiguration.networkSettings(remoteAddress: addresses[0])
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
                            self.previousPath = self.defaultPath
                            self.pathObservation = self.observe(\.defaultPath, options: [.new]) { [weak self] _, _ in
                                self?.work.async { [weak self] in self?.pathChanged() }
                            }
                            completionHandler(nil)
                            Logger(subsystem: "dev.vibemonitoring.app.tunnel", category: "lifecycle").notice("Tunnel start completed")
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
        diagnostics.coreStarts += 1
        issue = nil
        retryDelay = 1
        reasserting = false
        bindNetworkLock()
    }

    private func bindNetworkLock() {
        guard !bindingInFlight, !stopping, let node, let interfaceName,
              let binding = try? NetworkLockClient.binding(nodeID: node.id, interface: interfaceName) else { return }
        bindingInFlight = true
        Task {
            let health = try? await NetworkLockClient.status(binding: binding)
            work.async { [self] in
                bindingInFlight = false
                guard self.node?.id == binding.nodeID, !stopping else { return }
                if health?.active != true || health?.tunnelInterface != binding.interface {
                    issue = "network-lock-unconfirmed"
                } else if issue == "network-lock-unconfirmed" { issue = nil }
            }
        }
    }

    private func installWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: work)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopping else { return }
            let alive = (try? XrayCore.invoke("getXrayState")["running"] as? Bool) == true
            if !alive || self.reasserting {
                if !alive && !self.reasserting { self.diagnostics.lastRestart = .coreStopped }
                self.recoverIfDue()
            }
            if self.running { self.bindNetworkLock() }
        }
        watchdog = timer
        timer.resume()
    }

    private func pathChanged() {
        let path = defaultPath
        if let path, let previousPath, previousPath.isEqual(to: path) { return }
        if path == nil && previousPath == nil { return }
        previousPath = path
        diagnostics.pathChanges += 1
        requestRestart(reason: .pathChanged)
    }

    private func requestRestart(reason: VPNProviderDiagnostics.RestartReason) {
        guard !stopping else { return }
        diagnostics.lastRestart = reason
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
        Logger(subsystem: "dev.vibemonitoring.app.tunnel", category: "lifecycle")
            .notice("Tunnel stop requested; reason \(reason.rawValue, privacy: .public)")
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

    override func wake() { work.async { self.requestRestart(reason: .wake) } }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        work.async {
            if messageData != Data("status".utf8) {
                do {
                    let change = try VPNServerChange.decode(messageData)
                    let node = try VPNKeychain.loadSelected(reference: change.reference)
                    guard !self.stopping, node.id == change.nodeID else { throw VPNError.invalidConfiguration }
                    // Keep the interface and full-tunnel policy installed throughout the core replacement.
                    self.reasserting = true
                    self.running = false
                    self.issue = "server-switching"
                    self.diagnostics.lastRestart = .serverSwitch
                    self.node = node
                    self.resolvedAddresses = change.addresses
                    self.retryAt = 0
                    self.recoverIfDue()
                } catch { completionHandler?(nil); return }
            }
            var health = VPNProviderHealth(nodeID: self.node?.id ?? "", running: self.running,
                                           reasserting: self.reasserting, issue: self.issue)
            health.interfaceName = self.interfaceName
            health.diagnostics = self.diagnostics
            completionHandler?(try? JSONEncoder().encode(health))
        }
    }

    private func tunnelDescriptor() throws -> Int32 {
        // Identify our process's utun socket through public Darwin socket APIs, not KVC on packetFlow.
        for fd: Int32 in 0..<min(getdtablesize(), 4_096) {
            var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
            var length = socklen_t(name.count)
            if getsockopt(fd, SYSPROTO_CONTROL, 2, &name, &length) == 0,
               String(cString: name).hasPrefix("utun") {
                interfaceName = String(cString: name)
                return fd
            }
        }
        throw VPNError.providerUnavailable
    }
}
