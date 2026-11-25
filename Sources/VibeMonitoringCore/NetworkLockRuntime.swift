import Foundation

/// The interface binding is runtime-only. Saved utun names cannot be trusted after a reboot or provider restart.
/// A binding is also a lease: the live provider renews it every few seconds. If our provider stops or crashes while
/// protection stays requested, the utun name it used can be reassigned to another tunnel; an expired lease ensures
/// that name is no longer allowed wholesale.
public final class NetworkLockRuntime: @unchecked Sendable {
    public static let defaultLease: UInt64 = 15_000_000_000

    private let lock = NSLock()
    private var rules = NetworkLockRules(try! NetworkLockPolicy(mode: .paused))
    private var active = false
    private var valid = false
    private var preservedPolicyReloads = 0
    private var expiredBindings = 0
    private var boundUntil: UInt64 = 0
    private let lease: UInt64
    private let clock: @Sendable () -> UInt64

    public init(lease: UInt64 = NetworkLockRuntime.defaultLease,
                clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.lease = lease
        self.clock = clock
    }

    public func install(_ policy: NetworkLockPolicy?, active: Bool) {
        lock.lock(); defer { lock.unlock() }
        expireBindingIfNeeded()
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
        if rules.policy.tunnelInterface == nil { boundUntil = 0 }
        self.active = active; valid = current != nil
    }

    public func allows(interface: String, outbound: Bool, packet: UnsafeRawBufferPointer,
                       linkLayer: NetworkLockLinkLayer) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if interface == rules.policy.tunnelInterface { expireBindingIfNeeded() }
        return rules.allows(interface: interface, outbound: outbound, bytes: packet, linkLayer: linkLayer)
    }

    /// Binds or renews the live tunnel interface for the selected node.
    @discardableResult
    public func bind(_ binding: NetworkLockBinding) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active, valid, let policy = try? binding.applying(to: rules.policy) else { return false }
        rules = NetworkLockRules(policy)
        boundUntil = clock() &+ lease
        return true
    }

    public func health() -> NetworkLockHealth {
        lock.lock(); defer { lock.unlock() }
        expireBindingIfNeeded()
        var health = NetworkLockHealth(active: active, policy: valid ? rules.policy : nil, validPolicy: valid)
        health.preservedPolicyReloads = preservedPolicyReloads
        health.expiredBindings = expiredBindings
        return health
    }

    /// Caller holds `lock`.
    private func expireBindingIfNeeded() {
        let policy = rules.policy
        guard policy.tunnelInterface != nil, clock() >= boundUntil,
              let unbound = try? NetworkLockPolicy(mode: policy.mode, endpoints: policy.endpoints,
                                                   revision: policy.revision, nodeID: policy.nodeID) else { return }
        rules = NetworkLockRules(unbound)
        boundUntil = 0
        expiredBindings += 1
    }
}
