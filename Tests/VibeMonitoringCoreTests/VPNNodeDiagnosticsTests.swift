import Foundation
import XCTest
@testable import VibeMonitoringCore

final class VPNNodeDiagnosticsTests: XCTestCase {
    func testDiagnosticProjectionPreservesTransportFlagsWithoutSecrets() throws {
        var outbound: [String: Any] = [
            "tag": "private-node-name", "protocol": "vless",
            "settings": ["address": "private-host.example", "port": 443,
                         "id": "11111111-1111-4111-8111-111111111111", "encryption": "none", "flow": "xtls-rprx-vision"],
            "streamSettings": ["network": "tcp", "security": "tls",
                               "tlsSettings": ["serverName": "private-sni.example", "fingerprint": "chrome"]],
            "mux": ["enabled": false]
        ]
        var result = try VPNNodeDiagnostics(VPNNode(outbound: outbound, index: 0))
        XCTAssertTrue(result.vision)
        XCTAssertEqual(result.fingerprint, "chrome")
        XCTAssertTrue(result.serverNameConfigured)
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        for secret in ["private-node-name", "private-host.example", "private-sni.example", "11111111-1111-4111-8111-111111111111"] {
            XCTAssertFalse(json.contains(secret))
        }
        outbound["settings"] = ["vnext": [["address": "private-host.example", "port": 443,
            "users": [["id": "11111111-1111-4111-8111-111111111111", "encryption": "none", "flow": "xtls-rprx-vision"]]]]]
        outbound["streamSettings"] = ["network": "tcp", "security": "tls", "tlsSettings": ["fingerprint": "secret-value"]]
        result = try VPNNodeDiagnostics(VPNNode(outbound: outbound, index: 0))
        XCTAssertTrue(result.vision)
        XCTAssertEqual(result.fingerprint, "custom")
        XCTAssertFalse(result.serverNameConfigured)
    }
}
