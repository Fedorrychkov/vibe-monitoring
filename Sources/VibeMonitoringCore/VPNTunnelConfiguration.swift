import Foundation
import Darwin

public enum VPNTunnelConfiguration {
    public static func validatedAddresses(_ addresses: [String]) throws -> [String] {
        guard !addresses.isEmpty, addresses.count <= 32,
              addresses.allSatisfy({ address in
                  guard !address.contains("\0") else { return false }
                  var v4 = in_addr(); var v6 = in6_addr()
                  return address.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
              }) else { throw VPNError.invalidConfiguration }
        return addresses
    }

    public static func build(node: VPNNode, descriptor: Int32, addresses: [String]) throws -> Data {
        guard descriptor >= 0 else { throw VPNError.invalidConfiguration }
        _ = try validatedAddresses(addresses)
        var outbound = try node.validatedOutbound()
        outbound["tag"] = "proxy"
        var stream = outbound["streamSettings"] as? [String: Any] ?? [:]
        var sockopt = stream["sockopt"] as? [String: Any] ?? [:]
        sockopt["domainStrategy"] = "UseIP"
        stream["sockopt"] = sockopt
        outbound["streamSettings"] = stream
        let config: [String: Any] = [
            "env": ["xray.tun.fd": String(descriptor)],
            "log": ["loglevel": "none"],
            "dns": ["hosts": [node.host: addresses], "servers": []],
            "inbounds": [["tag": "vibe-tun", "protocol": "tun", "port": 0,
                          "settings": ["name": "vibe", "mtu": 1_400]]],
            "outbounds": [outbound],
            "routing": ["domainStrategy": "AsIs", "rules": [["type": "field", "inboundTag": ["vibe-tun"], "outboundTag": "proxy"]]],
        ]
        return try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
    }
}
