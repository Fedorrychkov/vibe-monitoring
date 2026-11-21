import Foundation

/// The interface binding is runtime-only. Saved utun names cannot be trusted after a reboot or provider restart.
public final class NetworkLockRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private var rules = NetworkLockRules(try! NetworkLockPolicy(mode: .paused))
    private var active = false
    private var valid = false
    private var preservedPolicyReloads = 0

    public init() {}

    public func install(_ policy: NetworkLockPolicy?, active: Bool) {
        lock.lock(); defer { lock.unlock() }
        let previous = rules.policy
        let sameSavedPolicy = policy?.tunnelInterface == nil && policy?.revision == previous.revision
            && policy?.nodeID == previous.nodeID && policy?.endpoints == previous.endpoints
        // A repeated saved policy has no interface; keep its already authenticated runtime binding.
        let preserve = active && self.active && valid && policy?.mode == .protected && previous.mode == .protected
            && (policy?.tunnelInterface == previous.tunnelInterface || sameSavedPolicy)
        if preserve && sameSavedPolicy && previous.tunnelInterface != nil { preservedPolicyReloads += 1 }
        let current = policy.flatMap {
            try? NetworkLockPolicy(mode: $0.mode, endpoints: $0.endpoints,
                                   tunnelInterface: preserve ? rules.policy.tunnelInterface : nil,
                                   revision: $0.revision, nodeID: $0.nodeID)
        }
        rules = NetworkLockRules(current ?? (try! NetworkLockPolicy(mode: .paused)))
        self.active = active; valid = current != nil
    }

    public func allows(interface: String, outbound: Bool, packet: UnsafeRawBufferPointer,
                       linkLayer: NetworkLockLinkLayer) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return rules.allows(interface: interface, outbound: outbound, bytes: packet, linkLayer: linkLayer)
    }

    @discardableResult
    public func bind(_ binding: NetworkLockBinding) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active, valid, let policy = try? binding.applying(to: rules.policy) else { return false }
        rules = NetworkLockRules(policy)
        return true
    }

    public func health() -> NetworkLockHealth {
        lock.lock(); defer { lock.unlock() }
        var health = NetworkLockHealth(active: active, policy: valid ? rules.policy : nil, validPolicy: valid)
        health.preservedPolicyReloads = preservedPolicyReloads
        return health
    }
}
