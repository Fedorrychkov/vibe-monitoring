import XCTest
@testable import VibeMonitoringCore

final class NetworkLockRuntimeTests: XCTestCase {
    private let node = String(repeating: "a", count: 64)
    private func permits(_ runtime: NetworkLockRuntime, interface: String = "utun7") -> Bool {
        Data().withUnsafeBytes { runtime.allows(interface: interface, outbound: true, packet: $0, linkLayer: .ip) }
    }
    func testRestartDoesNotTrustSavedTunnelNameAndNeedsMatchingLiveBinding() throws {
        let policy = try NetworkLockPolicy(mode: .protected, tunnelInterface: "utun7", nodeID: node)
        let runtime = NetworkLockRuntime()
        runtime.install(policy, active: true)
        XCTAssertTrue(runtime.health().confirms(policy))
        XCTAssertNil(runtime.health().tunnelInterface)
        XCTAssertFalse(permits(runtime))
        XCTAssertFalse(runtime.bind(try .init(nodeID: String(repeating: "b", count: 64), interface: "utun7")))
        XCTAssertTrue(runtime.bind(try .init(nodeID: node, interface: "utun7")))
        XCTAssertTrue(permits(runtime))
        XCTAssertFalse(permits(runtime, interface: "utun8"))
        runtime.install(nil, active: false)
        runtime.install(policy, active: true)
        XCTAssertFalse(permits(runtime))
    }
    func testPauseAndInvalidPolicyDiscardBindingAndNeverPermitDirectTraffic() throws {
        let runtime = NetworkLockRuntime()
        runtime.install(try .init(mode: .directAllowed), active: true)
        XCTAssertTrue(permits(runtime, interface: "en0"))
        let paused = try NetworkLockPolicy(mode: .paused)
        runtime.install(paused, active: true)
        XCTAssertTrue(runtime.health().confirms(paused))
        XCTAssertFalse(permits(runtime))
        XCTAssertFalse(runtime.bind(try .init(nodeID: node, interface: "utun7")))
        runtime.install(nil, active: true)
        XCTAssertFalse(runtime.health().validPolicy)
        XCTAssertFalse(runtime.health().confirms(paused))
        XCTAssertFalse(permits(runtime, interface: "en0"))
    }
    func testTransitionKeepsOnlyExistingLiveInterfaceAndChangesAllowedNode() throws {
        let runtime = NetworkLockRuntime()
        runtime.install(try .init(mode: .protected, nodeID: node), active: true)
        XCTAssertTrue(runtime.bind(try .init(nodeID: node, interface: "utun7")))
        let next = String(repeating: "b", count: 64)
        let policy = try NetworkLockPolicy(mode: .protected, tunnelInterface: "utun7", nodeID: next)
        runtime.install(policy, active: true)
        XCTAssertTrue(permits(runtime))
        XCTAssertFalse(runtime.bind(try .init(nodeID: node, interface: "utun7")))
        XCTAssertTrue(runtime.bind(try .init(nodeID: next, interface: "utun7")))
        XCTAssertTrue(runtime.health().confirms(policy))
        XCTAssertFalse(runtime.health().confirms(try .init(mode: .protected, nodeID: next)))
        runtime.install(try .init(mode: .protected, tunnelInterface: "utun8", nodeID: next), active: true)
        XCTAssertFalse(permits(runtime, interface: "utun8"))
    }

    func testReloadOfSameUnboundSavedPolicyKeepsAuthenticatedLiveBinding() throws {
        let policy = try NetworkLockPolicy(mode: .protected,
                                          endpoints: [.init(ip: "192.0.2.1", port: 443)], nodeID: node)
        let runtime = NetworkLockRuntime()
        runtime.install(policy, active: true)
        XCTAssertNil(runtime.health().tunnelInterface)
        XCTAssertTrue(runtime.bind(try .init(nodeID: node, interface: "utun7")))

        let reloaded = try NetworkLockPolicy.decode(policy.encoded())
        runtime.install(reloaded, active: true)
        XCTAssertTrue(runtime.health().confirms(policy))
        XCTAssertEqual(runtime.health().tunnelInterface, "utun7")
        XCTAssertTrue(permits(runtime))
        XCTAssertFalse(permits(runtime, interface: "utun8"))
        XCTAssertFalse(permits(runtime, interface: "en0"))
        XCTAssertEqual(runtime.health().preservedPolicyReloads, 1)
        let health = try JSONDecoder().decode(NetworkLockHealth.self, from: JSONEncoder().encode(runtime.health()))
        XCTAssertEqual(health.preservedPolicyReloads, 1)

        runtime.install(nil, active: false)
        runtime.install(reloaded, active: true)
        XCTAssertNil(runtime.health().tunnelInterface)
        XCTAssertFalse(permits(runtime))
    }

    func testChangedOrInactiveSavedPolicyCannotReuseImplicitBinding() throws {
        let endpoint = try NetworkLockEndpoint(ip: "192.0.2.1", port: 443)
        let original = try NetworkLockPolicy(mode: .protected, endpoints: [endpoint], nodeID: node)
        let cases: [(NetworkLockPolicy, Bool)] = [
            (try .init(mode: .protected, endpoints: [endpoint], nodeID: node), true),
            (try .init(mode: .protected, endpoints: [endpoint], revision: original.revision,
                       nodeID: String(repeating: "b", count: 64)), true),
            (try .init(mode: .protected, endpoints: [.init(ip: "192.0.2.2", port: 443)],
                       revision: original.revision, nodeID: node), true),
            (try .init(mode: .protected, endpoints: [endpoint], tunnelInterface: "utun8",
                       revision: original.revision, nodeID: node), true),
            (original, false),
            (try .init(mode: .protected, endpoints: [endpoint], tunnelInterface: "utun7",
                       revision: original.revision, nodeID: node), false),
        ]
        for (policy, active) in cases {
            let runtime = NetworkLockRuntime()
            runtime.install(original, active: true)
            XCTAssertTrue(runtime.bind(try .init(nodeID: node, interface: "utun7")))
            runtime.install(policy, active: active)
            XCTAssertNil(runtime.health().tunnelInterface)
            XCTAssertFalse(permits(runtime))
            XCTAssertFalse(permits(runtime, interface: "utun8"))
            XCTAssertFalse(permits(runtime, interface: "en0"))
        }
    }
}
