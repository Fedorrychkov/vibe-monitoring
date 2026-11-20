import Foundation
import XCTest
import Security
import Darwin
@testable import VibeMonitoringCore

final class VPNTests: XCTestCase {
    func outbound(name: String = "Demo server") -> [String: Any] {
        ["tag": name, "protocol": "vless",
         "settings": ["vnext": [["address": "vpn.example", "port": 443,
                                  "users": [["id": "11111111-1111-4111-8111-111111111111", "encryption": "none"]]]]],
         "streamSettings": ["network": "tcp", "security": "tls", "tlsSettings": ["serverName": "vpn.example"]]]
    }

    func testStableNodeIdentityAndDeduplicationDoNotDependOnDisplayName() throws {
        let first = try VPNNode(outbound: outbound(), index: 0)
        let renamed = try VPNNode(outbound: outbound(name: "Renamed"), index: 9)
        XCTAssertEqual(first.id, renamed.id)
        XCTAssertEqual(renamed.name, "Renamed")
        XCTAssertEqual(try VPNNode.parse(outbounds: [outbound(), outbound(name: "Renamed")]).count, 1)
        XCTAssertEqual(try first.validatedOutbound()["protocol"] as? String, "vless")
    }

    func testUnsafeAndUnsupportedNodesAreRejected() throws {
        var insecure = outbound()
        insecure["streamSettings"] = ["network": "tcp", "security": "none"]
        XCTAssertThrowsError(try VPNNode(outbound: insecure, index: 0))
        insecure["streamSettings"] = ["security": "tls", "tlsSettings": ["allowInsecure": true]]
        XCTAssertThrowsError(try VPNNode(outbound: insecure, index: 0))
        insecure["streamSettings"] = ["security": "tls", "tlsSettings": ["certificates": [["keyFile": "/private/not-read"]]]]
        XCTAssertThrowsError(try VPNNode(outbound: insecure, index: 0))
        var direct = outbound(); direct["protocol"] = "freedom"
        XCTAssertThrowsError(try VPNNode(outbound: direct, index: 0))
        XCTAssertEqual(try VPNNode.parse(outbounds: [direct, outbound()]).count, 1)
        XCTAssertThrowsError(try VPNNode.parse(outbounds: [direct]))
    }

    func testCurrentCoreFlatSettingsAreAccepted() throws {
        var current = outbound()
        current["settings"] = ["address": "vpn.example", "port": 443,
                               "id": "11111111-1111-4111-8111-111111111111", "encryption": "none"]
        let node = try VPNNode(outbound: current, index: 0)
        XCTAssertEqual(node.host, "vpn.example")
        XCTAssertEqual(node.port, 443)
    }

    func testOnlyPlainOrBase64ShareLinksReachTheNativeConverter() throws {
        let uri = "vless://11111111-1111-4111-8111-111111111111@vpn.example:443?type=tcp&security=tls#Demo"
        XCTAssertEqual(try VPNSubscriptionText.normalize(Data(uri.utf8)), uri)
        XCTAssertEqual(try VPNSubscriptionText.normalize(Data(Data(uri.utf8).base64EncodedString().utf8)), uri)
        XCTAssertThrowsError(try VPNSubscriptionText.normalize(Data("{\"outbounds\":[]}".utf8)))
        XCTAssertThrowsError(try VPNSubscriptionText.normalize(Data("<html>not a subscription</html>".utf8)))
        XCTAssertThrowsError(try VPNSubscriptionText.normalize(Data(uri.replacingOccurrences(of: "type=tcp", with: "type=xhttp&extra=unsafe").utf8)))
        XCTAssertThrowsError(try VPNSubscriptionText.normalize(Data(repeating: 65, count: 4 * 1024 * 1024 + 1)))
    }

    func testGeneratedConfigHasOnlyTheSelectedProxyAndNoDirectFallback() throws {
        let node = try VPNNode(outbound: outbound(), index: 0)
        let data = try VPNTunnelConfiguration.build(node: node, descriptor: 9, addresses: ["192.0.2.10", "2001:db8::1"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let outbounds = try XCTUnwrap(json["outbounds"] as? [[String: Any]])
        XCTAssertEqual(outbounds.count, 1)
        XCTAssertEqual(outbounds[0]["protocol"] as? String, "vless")
        XCTAssertEqual((json["env"] as? [String: String])?["xray.tun.fd"], "9")
        XCTAssertEqual((json["log"] as? [String: String])?["loglevel"], "none")
        XCTAssertThrowsError(try VPNTunnelConfiguration.build(node: node, descriptor: -1, addresses: ["192.0.2.10"]))
        XCTAssertThrowsError(try VPNTunnelConfiguration.build(node: node, descriptor: 9, addresses: ["not-an-address"]))
    }

    func testMenuProcessCannotWriteSystemCredentialsOrProbeStorage() throws {
        guard geteuid() != 0 else { throw XCTSkip("This check must run as an ordinary user") }
        let node = try VPNNode(outbound: outbound(), index: 0)
        XCTAssertThrowsError(try VPNKeychain.saveSelected(node)) { error in
            XCTAssertEqual(error as? VPNCredentialFailure, VPNCredentialFailure(.privileges, errSecAuthFailed))
        }
        XCTAssertThrowsError(try VPNKeychain.probeSelectedStorage()) { error in
            XCTAssertEqual(error as? VPNCredentialFailure, VPNCredentialFailure(.privileges, errSecAuthFailed))
        }
    }

    func testProvisioningPayloadIsBoundedAndRevalidated() throws {
        let node = try VPNNode(outbound: outbound(), index: 0)
        let data = try JSONEncoder().encode(node)
        XCTAssertEqual(try VPNNode.decodeValidated(data), node)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["host"] = "changed.example"
        XCTAssertThrowsError(try VPNNode.decodeValidated(JSONSerialization.data(withJSONObject: json)))
        XCTAssertThrowsError(try VPNNode.decodeValidated(Data(repeating: 65, count: 256 * 1024 + 1)))
    }

    func testXPCRequirementsBindBothPeersToTheirTeamAndExactBundleID() throws {
        for peer in [VPNCredentialIdentity.Peer.app, .provider] {
            let text = try VPNCredentialIdentity.requirement(for: peer, team: "ABCDE12345")
            XCTAssertTrue(text.contains("identifier \"\(peer.rawValue)\""))
            XCTAssertTrue(text.contains("certificate leaf[subject.OU] = \"ABCDE12345\""))
            var requirement: SecRequirement?
            XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &requirement), errSecSuccess)
        }
        XCTAssertThrowsError(try VPNCredentialIdentity.requirement(for: .app, team: "ABCDE12345\" or true"))
    }

    func testUnverifiedOrStaleProviderStateNeverTurnsTheShieldGreen() {
        let health = VPNProviderHealth(nodeID: "demo", running: true, reasserting: false, issue: nil)
        XCTAssertEqual(VPNProtectionState.evaluate(requested: true, policyValid: true, system: "connected", health: health, healthAge: 1, expectedNodeID: "demo"), .connected)
        XCTAssertEqual(VPNProtectionState.evaluate(requested: true, policyValid: true, system: "connected", health: health, healthAge: 9, expectedNodeID: "demo"), .unverified)
        XCTAssertEqual(VPNProtectionState.evaluate(requested: true, policyValid: false, system: "connected", health: health, healthAge: 1, expectedNodeID: "demo"), .unverified)
        XCTAssertEqual(VPNProtectionState.evaluate(requested: true, policyValid: true, system: "disconnected", health: health, healthAge: 1, expectedNodeID: "demo"), .unverified)
        XCTAssertEqual(VPNProtectionState.evaluate(requested: true, policyValid: true, system: "connected", health: health, healthAge: 1, expectedNodeID: "other"), .unverified)
        let reconnecting = VPNProviderHealth(nodeID: "demo", running: false, reasserting: true, issue: "core-restarting")
        XCTAssertEqual(VPNProtectionState.evaluate(requested: true, policyValid: true, system: "reasserting", health: reconnecting, healthAge: 1, expectedNodeID: "demo"), .blocked)
        XCTAssertEqual(VPNProtectionState.evaluate(requested: false, policyValid: false, system: "disconnected", health: nil, healthAge: nil, expectedNodeID: nil), .off)
        let contradictory = VPNProviderHealth(nodeID: "demo", running: true, reasserting: false, issue: "core-restart-failed")
        XCTAssertEqual(VPNProtectionState.evaluate(requested: true, policyValid: true, system: "connected", health: contradictory, healthAge: 1, expectedNodeID: "demo"), .unverified)
    }
}
