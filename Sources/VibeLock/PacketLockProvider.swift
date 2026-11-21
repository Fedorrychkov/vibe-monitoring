import Foundation
import Network
import NetworkExtension
import VibeMonitoringCore

enum LockRuntime { static let shared = NetworkLockRuntime() }

@objc(VibePacketLockProvider)
final class PacketLockProvider: NEFilterPacketProvider {
    private var observation: NSKeyValueObservation?
    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        LockRuntime.shared.install(nil, active: false)
        func reload() {
            let data = filterConfiguration.vendorConfiguration?["policy"] as? Data
            let policy = data.flatMap { try? NetworkLockPolicy.decode($0) }
            // Invalid or missing policy stays deny-by-default; no direct fallback.
            LockRuntime.shared.install(policy, active: true)
        }
        reload()
        packetHandler = { _, interface, direction, pointer, length in
            let name = String(cString: nw_interface_get_name(interface))
            return LockRuntime.shared.allows(interface: name, outbound: direction == .outbound,
                packet: UnsafeRawBufferPointer(start: pointer, count: length),
                linkLayer: name.hasPrefix("utun") || name == "lo0" ? .ip : .ethernet) ? .allow : .drop
        }
        observation = observe(\.filterConfiguration, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            let data = self.filterConfiguration.vendorConfiguration?["policy"] as? Data
            LockRuntime.shared.install(data.flatMap { try? NetworkLockPolicy.decode($0) }, active: true)
        }
        completionHandler(nil)
    }
    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        observation = nil
        LockRuntime.shared.install(nil, active: false)
        completionHandler()
    }
}
