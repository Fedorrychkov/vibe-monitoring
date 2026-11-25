import XCTest
@testable import VibeMonitoringCore

final class NetworkLockPolicyTests: XCTestCase {
    func testBindingIndexIsRequiredAndValidatedAfterDecoding() throws {
        let node = String(repeating: "a", count: 64)
        XCTAssertThrowsError(try NetworkLockBinding(nodeID: node, interface: "utun7", interfaceIndex: 0))
        let data = Data("{\"nodeID\":\"\(node)\",\"interface\":\"utun7\",\"interfaceIndex\":0}".utf8)
        let decoded = try JSONDecoder().decode(NetworkLockBinding.self, from: data)
        XCTAssertThrowsError(try decoded.applying(to: .init(mode: .protected, nodeID: node)))
    }
    private func packet(ip: [UInt8] = [192, 0, 2, 1], port: Int = 443, proto: UInt8 = 6, inbound: Bool = false) -> Data {
        var data = [UInt8](repeating: 0, count: 40)
        data[0] = 0x45; data[3] = 40; data[9] = proto
        data[32] = 0x50; data[25] = 20
        data.replaceSubrange((inbound ? 12 : 16)..<(inbound ? 16 : 20), with: ip)
        data[inbound ? 20 : 22] = UInt8(port >> 8); data[inbound ? 21 : 23] = UInt8(port & 255)
        return Data(data)
    }
    private func permits(_ rules: NetworkLockRules, _ packet: Data, interface: String = "en0", outbound: Bool = true) -> Bool {
        packet.withUnsafeBytes { rules.allows(interface: interface, outbound: outbound, bytes: $0) }
    }
    func testProtectedAllowsOnlyExactEndpointAndExactTunnel() throws {
        let rules = NetworkLockRules(try NetworkLockPolicy(mode: .protected, endpoints: [.init(ip: "192.0.2.1", port: 443)], tunnelInterface: "utun7"))
        XCTAssertTrue(permits(rules, packet()))
        XCTAssertTrue(permits(rules, packet(inbound: true), outbound: false))
        XCTAssertFalse(permits(rules, packet(ip: [192, 0, 2, 2])))
        XCTAssertFalse(permits(rules, packet(port: 80)))
        XCTAssertFalse(permits(rules, packet(proto: 17)))
        XCTAssertTrue(permits(rules, packet(ip: [1, 1, 1, 1], port: 53, proto: 17), interface: "utun7"))
        XCTAssertFalse(permits(rules, packet(ip: [1, 1, 1, 1], port: 53, proto: 17), interface: "utun8"))
        XCTAssertTrue(permits(rules, Data(), interface: "lo0"))
    }
    func testPauseDropsOldEndpointTunnelDNSAndQUIC() throws {
        let rules = NetworkLockRules(try NetworkLockPolicy(mode: .paused, endpoints: [.init(ip: "192.0.2.1", port: 443)], tunnelInterface: "utun7"))
        for interface in ["en0", "utun7"] {
            XCTAssertFalse(permits(rules, packet(), interface: interface))
            XCTAssertFalse(permits(rules, packet(port: 53, proto: 17), interface: interface))
            XCTAssertFalse(permits(rules, packet(proto: 17), interface: interface))
        }
        XCTAssertTrue(permits(NetworkLockRules(try .init(mode: .directAllowed)), packet()))
    }
    func testTruncatedFragmentedAndInvalidPoliciesFailClosed() throws {
        let rules = NetworkLockRules(try .init(mode: .protected, endpoints: [.init(ip: "192.0.2.1", port: 443)]))
        for length in 0..<40 { XCTAssertFalse(permits(rules, packet().prefix(length))) }
        var fragment = packet(); fragment[7] = 1
        XCTAssertFalse(permits(rules, fragment))
        XCTAssertThrowsError(try NetworkLockPolicy(mode: .protected, tunnelInterface: "en0"))
        XCTAssertThrowsError(try NetworkLockPolicy(mode: .protected, endpoints: [.init(ip: "vpn.example", port: 443)]))
        XCTAssertThrowsError(try NetworkLockPolicy.decode(Data(repeating: 0, count: 16_385)))
        let value = try NetworkLockPolicy(mode: .paused)
        XCTAssertEqual(try NetworkLockPolicy.decode(value.encoded()).revision, value.revision)
    }
    func testDHCPExceptionCannotSendToPublicInternet() throws {
        let rules = NetworkLockRules(try .init(mode: .paused))
        var data = packet(ip: [255, 255, 255, 255], port: 67, proto: 17)
        data[21] = 68
        XCTAssertTrue(permits(rules, data))
        data.replaceSubrange(16..<20, with: [192, 0, 2, 1])
        XCTAssertFalse(permits(rules, data))
    }
    func testIPv6EndpointUDPFragmentsAndNeighborDiscovery() throws {
        let rules = NetworkLockRules(try .init(mode: .protected, endpoints: [.init(ip: "2001:db8::1", port: 443)]))
        var data = Data(repeating: 0, count: 60)
        data[0] = 0x60; data[5] = 20; data[6] = 6; data[7] = 64
        data[24] = 0x20; data[25] = 1; data[26] = 0x0d; data[27] = 0xb8; data[39] = 1
        data[42] = 1; data[43] = 0xbb; data[52] = 0x50
        XCTAssertTrue(permits(rules, data))
        for prefix in 0..<60 { XCTAssertFalse(permits(rules, data.prefix(prefix))) }
        data[39] = 2; XCTAssertFalse(permits(rules, data)); data[39] = 1
        data[6] = 44; XCTAssertFalse(permits(rules, data)) // Fragment header never bypasses policy.
        data[6] = 0; XCTAssertFalse(permits(rules, data)) // Unparsed extension header.
        data[6] = 17; data[45] = 20; XCTAssertFalse(permits(rules, data)) // QUIC / DNS.
        let paused = NetworkLockRules(try .init(mode: .paused))
        data[6] = 58; data[7] = 255; data[40] = 133; data[41] = 0
        data[24] = 0xff; data[25] = 2
        XCTAssertTrue(permits(paused, data))
        data[7] = 64; XCTAssertFalse(permits(paused, data)); data[7] = 255
        data[40] = 128; XCTAssertFalse(permits(paused, data)) // Echo is not link maintenance.
        data[40] = 135; XCTAssertFalse(permits(paused, data)) // Truncated neighbor solicitation.
        data[40] = 133; data[24] = 0x20; data[25] = 1
        XCTAssertFalse(permits(paused, data)) // No Internet ICMP bypass.
    }

    func testProviderBindingRequiresSelectedNodeAndPreservesPolicyRevision() throws {
        let node = String(repeating: "a", count: 64)
        let policy = try NetworkLockPolicy(mode: .protected, endpoints: [.init(ip: "192.0.2.1", port: 443)], nodeID: node)
        let binding = try NetworkLockBinding(nodeID: node, interface: "utun7", interfaceIndex: 7)
        let updated = try binding.applying(to: policy)
        XCTAssertEqual(updated.revision, policy.revision)
        XCTAssertEqual(updated.tunnelInterface, "utun7")
        XCTAssertThrowsError(try binding.applying(to: .init(mode: .paused)))
        XCTAssertThrowsError(try binding.applying(to: .init(mode: .protected, nodeID: String(repeating: "b", count: 64))))
        XCTAssertThrowsError(try NetworkLockBinding(nodeID: node, interface: "en0", interfaceIndex: 7))
        XCTAssertThrowsError(try NetworkLockBinding(nodeID: "wrong", interface: "utun7", interfaceIndex: 7))
        XCTAssertThrowsError(try NetworkLockPolicy(mode: .protected, endpoints: Array(repeating: .init(ip: "192.0.2.1", port: 443), count: 33)))
        let malformed = Data("{\"mode\":\"protected\",\"endpoints\":[],\"revision\":\"\(UUID())\",\"tunnelInterface\":\"en0\"}".utf8)
        XCTAssertThrowsError(try NetworkLockPolicy.decode(malformed))
    }

    func testEthernetVLANAndARPFramesAreParsedBeforeIPRules() throws {
        let rules = NetworkLockRules(try .init(mode: .protected, endpoints: [.init(ip: "192.0.2.1", port: 443)]))
        func ethernet(_ payload: Data, type: Int = 0x0800) -> Data {
            var header = Data(repeating: 0, count: 14)
            header[12] = UInt8(type >> 8); header[13] = UInt8(type & 255)
            return header + payload
        }
        func frameAllowed(_ data: Data, rules: NetworkLockRules) -> Bool {
            data.withUnsafeBytes { rules.allows(interface: "en0", outbound: true, bytes: $0, linkLayer: .ethernet) }
        }
        let frame = ethernet(packet())
        XCTAssertTrue(frameAllowed(frame, rules: rules))
        for size in 0..<frame.count { XCTAssertFalse(frameAllowed(frame.prefix(size), rules: rules)) }
        XCTAssertFalse(frameAllowed(ethernet(packet(port: 80)), rules: rules))
        XCTAssertFalse(frameAllowed(packet(), rules: rules)) // Physical interfaces require a link header.
        let vlan = ethernet(Data([0, 1, 8, 0]) + packet(), type: 0x8100)
        XCTAssertTrue(frameAllowed(vlan, rules: rules))
        let doubleVLAN = ethernet(Data([0, 1, 0x81, 0, 0, 2, 8, 0]) + packet(), type: 0x88a8)
        XCTAssertTrue(frameAllowed(doubleVLAN, rules: rules))
        XCTAssertFalse(frameAllowed(ethernet(packet(), type: 0x86dd), rules: rules))
        var arp = Data(repeating: 0, count: 28)
        arp[1] = 1; arp[2] = 8; arp[4] = 6; arp[5] = 4; arp[7] = 1
        let paused = NetworkLockRules(try .init(mode: .paused))
        XCTAssertTrue(frameAllowed(ethernet(arp, type: 0x0806), rules: paused))
        arp[7] = 3
        XCTAssertFalse(frameAllowed(ethernet(arp, type: 0x0806), rules: paused))
        XCTAssertFalse(frameAllowed(ethernet(packet()), rules: paused))
    }

    func testMTUErrorsMustQuoteTheApprovedVPNEndpoint() throws {
        let protected = NetworkLockRules(try .init(mode: .protected, endpoints: [.init(ip: "192.0.2.1", port: 443)]))
        var error = Data(repeating: 0, count: 28)
        error[0] = 0x45; error[3] = 56; error[9] = 1; error[20] = 3; error[21] = 4
        error += packet().prefix(28) // ICMP typically quotes only eight TCP bytes.
        XCTAssertTrue(permits(protected, error, outbound: false))
        XCTAssertFalse(permits(protected, error, outbound: true))
        XCTAssertFalse(permits(NetworkLockRules(try .init(mode: .paused)), error, outbound: false))
        error[47] = 2
        XCTAssertFalse(permits(protected, error, outbound: false))
        error[47] = 1; error[51] = 80
        XCTAssertFalse(permits(protected, error, outbound: false))
        error[51] = 0xbb
        for size in 0..<error.count { XCTAssertFalse(permits(protected, error.prefix(size), outbound: false)) }
        let v6 = NetworkLockRules(try .init(mode: .protected, endpoints: [.init(ip: "2001:db8::1", port: 443)]))
        var packet6 = Data(repeating: 0, count: 96)
        packet6[0] = 0x60; packet6[5] = 56; packet6[6] = 58; packet6[40] = 2
        packet6[48] = 0x60; packet6[54] = 6
        packet6[72] = 0x20; packet6[73] = 1; packet6[74] = 0x0d; packet6[75] = 0xb8; packet6[87] = 1
        packet6[90] = 1; packet6[91] = 0xbb
        XCTAssertTrue(permits(v6, packet6, outbound: false))
        packet6[40] = 128
        XCTAssertFalse(permits(v6, packet6, outbound: false))
    }


    func testEAPOLLinkMaintenanceIsAllowedButNotOtherLinkProtocols() throws {
        let rules = NetworkLockRules(try .init(mode: .paused))
        func frame(_ type: [UInt8], _ payload: [UInt8]) -> Data { Data([UInt8](repeating: 0, count: 12) + type + payload) }
        func ethernet(_ data: Data) -> Bool { data.withUnsafeBytes { rules.allows(interface: "en0", outbound: true, bytes: $0, linkLayer: .ethernet) } }
        XCTAssertTrue(ethernet(frame([0x88, 0x8e], [2, 3, 0, 95])))
        XCTAssertTrue(ethernet(frame([0x81, 0x00, 0, 1, 0x88, 0x8e], [1, 0, 0, 0])))
        XCTAssertFalse(ethernet(frame([0x88, 0x8e], [2, 3, 0])))      // Truncated.
        XCTAssertFalse(ethernet(frame([0x88, 0x8e], [9, 3, 0, 95])))  // Unknown 802.1X version.
        XCTAssertFalse(ethernet(frame([0x88, 0xcc], [2, 3, 0, 95])))  // LLDP and other ethertypes stay blocked.
        XCTAssertFalse(ethernet(frame([0x88, 0x64], [0x11, 0, 0, 1]))) // PPPoE session cannot carry IP around the lock.
    }
}
