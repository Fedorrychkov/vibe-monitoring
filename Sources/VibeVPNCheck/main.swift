import Foundation
import VibeXray
import VibeMonitoringCore

// Only fictional nodes are used. No runXray, live network probe or TUN is started.
do {
    let uuid = "11111111-1111-4111-8111-111111111111"
    let key = Data([9] + Array(repeating: UInt8(0), count: 31)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    let samples = [
        "vless://\(uuid)@vpn.example:443?type=tcp&security=tls&sni=vpn.example#TLS",
        "vless://\(uuid)@vpn.example:443?type=tcp&security=reality&sni=vpn.example&pbk=\(key)&fp=chrome&sid=abcd#Reality",
        "vmess://\(uuid)@vpn.example:443?encryption=auto&type=ws&security=tls&sni=vpn.example&path=%2Fw#VMess",
        "trojan://synthetic-password@vpn.example:443?type=tcp&security=tls&sni=vpn.example#Trojan",
    ]
    let nodes = try XrayCore.importSubscription(Data(samples.joined(separator: "\n").utf8))
    guard nodes.count == 4, Set(nodes.map(\.kind)) == ["vless", "vmess", "trojan"] else { throw VPNError.invalidSubscription }
    for node in nodes {
        let generated = try VPNTunnelConfiguration.build(node: node, descriptor: 7, addresses: ["192.0.2.10"])
        var config = try JSONSerialization.jsonObject(with: generated) as! [String: Any]
        // Constructor validation excludes TUN/env: upstream testXray is not a sandbox.
        config.removeValue(forKey: "inbounds")
        config.removeValue(forKey: "env")
        let safeFixture = String(data: try JSONSerialization.data(withJSONObject: config), encoding: .utf8)!
        _ = try XrayCore.invoke("testXray", payload: ["xrayJson": safeFixture])
    }
    guard try XrayCore.invoke("getXrayState")["running"] as? Bool == false else { throw VPNError.invalidConfiguration }
    print("Pinned core: VLESS/TLS, Reality, VMessAEAD and Trojan fixtures passed. No tunnel was started.")
} catch {
    fputs("VPN engine validation failed; no tunnel was started.\n", stderr)
    exit(1)
}
