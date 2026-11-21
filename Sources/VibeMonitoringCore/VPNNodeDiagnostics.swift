import Foundation

/// An allowlist projection: no hostnames, node names, subscription URLs or credential fields.
public struct VPNNodeDiagnostics: Codable, Sendable {
    public let protocolName: String
    public let transport: String
    public let security: String
    public let fingerprint: String
    public let vision: Bool
    public let muxEnabled: Bool
    public let serverNameConfigured: Bool

    public init(_ node: VPNNode) throws {
        let outbound = try node.validatedOutbound()
        let stream = outbound["streamSettings"] as? [String: Any] ?? [:]
        let security = stream["security"] as? String ?? "none"
        let tls = stream[security == "reality" ? "realitySettings" : "tlsSettings"] as? [String: Any] ?? [:]
        let fp = tls["fingerprint"] as? String
        let known = ["chrome", "firefox", "safari", "ios", "android", "edge", "random", "randomized"]
        protocolName = node.kind
        transport = stream["network"] as? String ?? "tcp"
        self.security = ["none", "tls", "reality"].contains(security) ? security : "custom"
        fingerprint = fp.map { known.contains($0) ? $0 : "custom" } ?? "core default"
        let settings = outbound["settings"] as? [String: Any] ?? [:]
        let peer = (settings["vnext"] as? [[String: Any]])?.first
        let user = (peer?["users"] as? [[String: Any]])?.first
        let flow = settings["flow"] as? String ?? user?["flow"] as? String
        vision = flow == "xtls-rprx-vision" || flow == "xtls-rprx-vision-udp443"
        muxEnabled = (outbound["mux"] as? [String: Any])?["enabled"] as? Bool ?? false
        serverNameConfigured = (tls["serverName"] as? String)?.isEmpty == false
    }
}
