import CryptoKit
import Foundation

public enum VPNError: Error, LocalizedError {
    case engineMissing, invalidSubscription, unsupportedNode, insecureNode, invalidConfiguration, keychainUnavailable, signingRequired, providerUnavailable, serverResolutionFailed

    public var errorDescription: String? {
        switch self {
        case .engineMissing: return "This build does not contain the VPN engine. Use the VPN build."
        case .invalidSubscription: return "No supported servers were found. Existing subscription data was kept."
        case .unsupportedNode: return "This server uses an unsupported protocol or transport configuration."
        case .insecureNode: return "This server disables TLS verification or uses VLESS without TLS/Reality."
        case .invalidConfiguration: return "The VPN configuration could not be validated."
        case .keychainUnavailable: return "VPN credentials could not be accessed in macOS Keychain."
        case .signingRequired: return "VPN installation requires a signed Network Extension build and matching provisioning profiles."
        case .providerUnavailable: return "The VPN provider did not report a valid current state. Protection cannot be confirmed."
        case .serverResolutionFailed: return "Could not resolve the selected VPN server before enabling protection. Check connectivity and try again."
        }
    }
}

public struct VPNNode: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let kind: String
    public let host: String
    public let port: Int
    public let outboundJSON: Data

    public init(outbound: [String: Any], index: Int) throws {
        guard let kind = outbound["protocol"] as? String, ["vless", "vmess", "trojan"].contains(kind),
              let settings = outbound["settings"] as? [String: Any] else { throw VPNError.unsupportedNode }
        let destination: [String: Any]
        if settings["address"] is String { destination = settings }
        else {
            guard let destinations = settings[kind == "trojan" ? "servers" : "vnext"] as? [[String: Any]],
                  destinations.count == 1, let first = destinations.first else { throw VPNError.unsupportedNode }
            destination = first
        }
        guard let host = destination["address"] as? String,
              !host.isEmpty, host.count <= 253, !host.contains("\0"), !host.contains(where: { $0.isWhitespace || $0.isNewline }),
              let port = destination["port"] as? Int, (1...65_535).contains(port),
              outbound["proxySettings"] == nil else { throw VPNError.unsupportedNode }
        let stream = outbound["streamSettings"] as? [String: Any] ?? [:]
        let security = stream["security"] as? String ?? "none"
        let sockopt = stream["sockopt"] as? [String: Any] ?? [:]
        guard sockopt["dialerProxy"] == nil else { throw VPNError.unsupportedNode }
        let network = stream["network"] as? String ?? "tcp"
        guard ["tcp", "raw", "ws", "grpc", "httpupgrade"].contains(network) else { throw VPNError.unsupportedNode }
        if kind == "vless" || kind == "trojan" {
            guard ["tls", "reality"].contains(security) else { throw VPNError.insecureNode }
        }
        for key in ["tlsSettings", "realitySettings"] {
            let options = stream[key] as? [String: Any] ?? [:]
            if options["allowInsecure"] as? Bool == true { throw VPNError.insecureNode }
            guard options["certificates"] == nil, options["keyLog"] == nil, options["masterKeyLog"] == nil else { throw VPNError.unsupportedNode }
        }
        var clean = outbound
        let title = (clean.removeValue(forKey: "tag") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = try JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys])
        id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        name = title.flatMap { $0.isEmpty ? nil : String($0.prefix(100)) } ?? "\(kind.uppercased()) · \(index + 1)"
        self.kind = kind
        self.host = host
        self.port = port
        outboundJSON = data
    }

    public static func parse(outbounds: [[String: Any]]) throws -> [VPNNode] {
        guard !outbounds.isEmpty, outbounds.count <= 200 else { throw VPNError.invalidSubscription }
        var seen = Set<String>()
        let nodes = outbounds.enumerated().compactMap { index, outbound -> VPNNode? in
            guard let node = try? VPNNode(outbound: outbound, index: index), seen.insert(node.id).inserted else { return nil }
            return node
        }
        guard !nodes.isEmpty else { throw VPNError.invalidSubscription }
        return nodes
    }

    public func validatedOutbound() throws -> [String: Any] {
        guard let outbound = try JSONSerialization.jsonObject(with: outboundJSON) as? [String: Any] else { throw VPNError.invalidConfiguration }
        let validated = try VPNNode(outbound: outbound, index: 0)
        guard validated.id == id, validated.host == host, validated.port == port, validated.kind == kind else { throw VPNError.invalidConfiguration }
        return outbound
    }

    public static func decodeValidated(_ data: Data) throws -> VPNNode {
        guard data.count <= 256 * 1024 else { throw VPNError.invalidConfiguration }
        let node = try JSONDecoder().decode(VPNNode.self, from: data)
        _ = try node.validatedOutbound()
        return node
    }
}

public struct VPNSubscription: Codable, Sendable {
    public let sourceURL: String
    public let importedAt: Date
    public let nodes: [VPNNode]
    public var selectedID: String

    public init(sourceURL: String, nodes: [VPNNode], selectedID: String? = nil) throws {
        guard let first = nodes.first else { throw VPNError.invalidSubscription }
        self.sourceURL = sourceURL
        self.nodes = nodes
        self.selectedID = selectedID.flatMap { id in nodes.contains(where: { $0.id == id }) ? id : nil } ?? first.id
        importedAt = Date()
    }

    public var selected: VPNNode? { nodes.first { $0.id == selectedID } }
}

public struct VPNProviderDiagnostics: Codable, Sendable {
    public enum RestartReason: String, Codable, Sendable { case pathChanged, wake, coreStopped, serverSwitch }
    public var coreStarts = 0
    public var pathChanges = 0
    public var lastRestart: RestartReason?
    public init() {}
}

public struct VPNProviderHealth: Codable, Sendable {
    public let nodeID: String
    public let running: Bool
    public let reasserting: Bool
    public let issue: String?
    public var interfaceName: String? = nil
    public var diagnostics: VPNProviderDiagnostics? = nil

    public init(nodeID: String, running: Bool, reasserting: Bool, issue: String?) {
        self.nodeID = nodeID
        self.running = running
        self.reasserting = reasserting
        self.issue = issue
    }
}

public enum VPNProtectionState: String, Sendable {
    case unavailable, off, connecting, connected, blocked, unverified

    public static func evaluate(requested: Bool, policyValid: Bool, system: String, health: VPNProviderHealth?,
                                healthAge: TimeInterval?, expectedNodeID: String?) -> Self {
        guard requested else { return .off }
        guard policyValid else { return .unverified }
        if system == "connecting" { return .connecting }
        guard let health, let age = healthAge, age >= 0, age <= 8,
              health.nodeID == expectedNodeID else { return .unverified }
        if system == "reasserting" && health.reasserting && !health.running { return .blocked }
        if system == "connected" && health.running && !health.reasserting && health.issue == nil { return .connected }
        return .unverified
    }
}
