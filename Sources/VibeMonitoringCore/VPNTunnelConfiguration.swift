import Foundation
import Darwin
import NetworkExtension

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

    public static func networkSettings(remoteAddress: String) throws -> NEPacketTunnelNetworkSettings {
        _ = try validatedAddresses([remoteAddress])
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remoteAddress)
        settings.mtu = 1_400
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        let ipv6 = NEIPv6Settings(addresses: ["fd74:7662:6500::1"], networkPrefixLengths: [64])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6
        // AAAA queries work over IPv4. An unreachable IPv6 resolver can stall otherwise healthy lookups.
        // shortcut: these resolvers require IPv4 egress; add per-node resolvers for IPv6-only exits.
        let dns = NEDNSSettings(servers: ["1.1.1.1", "1.0.0.1"])
        dns.matchDomains = [""]
        dns.matchDomainsNoSearch = true
        settings.dnsSettings = dns
        return settings
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
