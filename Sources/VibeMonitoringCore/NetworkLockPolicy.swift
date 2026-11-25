import Darwin
import Foundation

public enum NetworkLockMode: String, Codable, Sendable {
    case protected, paused, directAllowed
}

public enum NetworkLockLinkLayer: Sendable { case ip, ethernet }

public struct NetworkLockEndpoint: Codable, Equatable, Sendable {
    public let ip: String
    public let port: Int
    public init(ip: String, port: Int) throws {
        _ = try VPNTunnelConfiguration.validatedAddresses([ip])
        guard (1...65_535).contains(port) else { throw VPNError.invalidConfiguration }
        self.ip = ip; self.port = port
    }
}

public struct NetworkLockPolicy: Codable, Sendable {
    public let revision: UUID
    public let mode: NetworkLockMode
    public let endpoints: [NetworkLockEndpoint]
    public let tunnelInterface: String?
    public let nodeID: String?

    public init(mode: NetworkLockMode, endpoints: [NetworkLockEndpoint] = [], tunnelInterface: String? = nil,
                revision: UUID = UUID(), nodeID: String? = nil) throws {
        guard endpoints.count <= 32 else { throw VPNError.invalidConfiguration }
        for endpoint in endpoints { _ = try NetworkLockEndpoint(ip: endpoint.ip, port: endpoint.port) }
        if let name = tunnelInterface {
            guard name.range(of: "^utun[0-9]{1,6}$", options: .regularExpression) != nil else { throw VPNError.invalidConfiguration }
        }
        if let nodeID, nodeID.range(of: "^[a-f0-9]{64}$", options: .regularExpression) == nil { throw VPNError.invalidConfiguration }
        self.nodeID = mode == .protected ? nodeID : nil
        self.revision = revision; self.mode = mode
        self.endpoints = mode == .protected ? endpoints : []
        self.tunnelInterface = mode == .protected ? tunnelInterface : nil
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16_384 else { throw VPNError.invalidConfiguration }
        let value = try JSONDecoder().decode(Self.self, from: data)
        return try Self(mode: value.mode, endpoints: value.endpoints, tunnelInterface: value.tunnelInterface, revision: value.revision, nodeID: value.nodeID)
    }
}

/// Rules are compiled once per policy change; packet decisions allocate no packet buffers.
public struct NetworkLockRules: Sendable {
    public let policy: NetworkLockPolicy
    private let endpoints: [([UInt8], Int)]

    public init(_ policy: NetworkLockPolicy) {
        self.policy = policy
        endpoints = policy.endpoints.map { endpoint in
            var storage = [UInt8](repeating: 0, count: endpoint.ip.contains(":") ? 16 : 4)
            let family = storage.count == 4 ? AF_INET : AF_INET6
            _ = storage.withUnsafeMutableBytes { target in endpoint.ip.withCString { inet_pton(family, $0, target.baseAddress) } }
            return (storage, endpoint.port)
        }
    }

    public func allows(interface: String, outbound: Bool, bytes: UnsafeRawBufferPointer,
                       linkLayer: NetworkLockLinkLayer = .ip) -> Bool {
        if policy.mode == .directAllowed || interface == "lo0" { return true }
        if policy.mode == .protected, interface == policy.tunnelInterface { return true }
        if linkLayer == .ethernet {
            guard bytes.count >= 14 else { return false }
            var offset = 14
            var type = Int(bytes[12]) << 8 | Int(bytes[13])
            for _ in 0..<2 where type == 0x8100 || type == 0x88a8 {
                guard bytes.count >= offset + 4 else { return false }
                type = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3]); offset += 4
            }
            // 802.1X/WPA EAPOL key exchange keeps Wi-Fi associated (e.g. periodic group-key rekeys).
            // It is not routable beyond the access point and carries no IP payload.
            if type == 0x888e { return bytes.count >= offset + 4 && (1...3).contains(bytes[offset]) }
            if type == 0x0806 {
                // ARP only resolves local-link IPv4 neighbors, including networks with public addressing.
                guard bytes.count >= offset + 28 else { return false }
                return bytes[offset] == 0 && bytes[offset + 1] == 1
                    && bytes[offset + 2] == 8 && bytes[offset + 3] == 0
                    && bytes[offset + 4] == 6 && bytes[offset + 5] == 4
                    && bytes[offset + 6] == 0 && (1...2).contains(bytes[offset + 7])
            }
            guard type == 0x0800 || type == 0x86dd, bytes.count > offset,
                  bytes[offset] >> 4 == (type == 0x0800 ? 4 : 6) else { return false }
            return allows(interface: interface, outbound: outbound,
                          bytes: UnsafeRawBufferPointer(rebasing: bytes[offset...]), linkLayer: .ip)
        }
        guard bytes.count >= 20 else { return false }
        func word(_ offset: Int) -> Int { Int(bytes[offset]) << 8 | Int(bytes[offset + 1]) }
        let version = bytes[0] >> 4
        let source: Int, destination: Int, size: Int, transport: Int, length: Int, protocolID: UInt8
        if version == 4 {
            transport = Int(bytes[0] & 15) * 4
            guard transport >= 20, bytes.count >= transport + 4, word(2) >= transport + 4, word(2) <= bytes.count,
                  word(6) & 0xbfff == 0 else { return false }
            length = word(2)
            source = 12; destination = 16; size = 4; protocolID = bytes[9]
        } else if version == 6 {
            guard bytes.count >= 44, word(4) >= 4, word(4) + 40 <= bytes.count else { return false }
            length = word(4) + 40
            source = 8; destination = 24; size = 16; transport = 40; protocolID = bytes[6]
            // Neighbor/router discovery is link maintenance, not ordinary Internet access.
            if protocolID == 58, bytes[7] == 255, bytes[41] == 0, (133...136).contains(bytes[40]),
               (bytes[24] == 0xff && bytes[25] == 2 || bytes[24] == 0xfe && bytes[25] & 0xc0 == 0x80) {
                let minimum = bytes[40] == 133 ? 8 : (bytes[40] == 134 ? 16 : 24)
                return length >= 40 + minimum
            }
        } else { return false }
        if policy.mode == .protected, !outbound,
           (version == 4 && protocolID == 1 || version == 6 && protocolID == 58) {
            guard length >= transport + 8 else { return false }
            let type = bytes[transport], code = bytes[transport + 1]
            let error = version == 4
                ? (type == 3 && code <= 15 || type == 11 && code <= 1 || type == 12 && code <= 2)
                : (type == 1 && code <= 7 || type == 2 && code == 0 || type == 3 && code <= 1 || type == 4 && code <= 2)
            guard error else { return false }
            // PMTU/error replies quote only the original IP header and a few transport bytes.
            // Accept them only for a TCP packet addressed to the selected VPN endpoint.
            let quote = transport + 8
            guard length > quote else { return false }
            let quotedVersion = bytes[quote] >> 4
            let address: Int, quotedSize: Int, tcp: Int
            if quotedVersion == 4 {
                guard length >= quote + 20, bytes[quote + 9] == 6 else { return false }
                let header = Int(bytes[quote] & 15) * 4
                guard header >= 20, Int(bytes[quote + 6]) & 0x9f == 0, bytes[quote + 7] == 0 else { return false }
                address = quote + 16; quotedSize = 4; tcp = quote + header
            } else if quotedVersion == 6 {
                guard length >= quote + 40, bytes[quote + 6] == 6 else { return false }
                address = quote + 24; quotedSize = 16; tcp = quote + 40
            } else { return false }
            guard length >= tcp + 4 else { return false }
            let quotedPort = word(tcp + 2)
            return endpoints.contains { ip, port in
                ip.count == quotedSize && port == quotedPort && ip.indices.allSatisfy { ip[$0] == bytes[address + $0] }
            }
        }
        if protocolID == 6 {
            guard length >= transport + 20, Int(bytes[transport + 12] >> 4) * 4 >= 20,
                  transport + Int(bytes[transport + 12] >> 4) * 4 <= length else { return false }
        } else if protocolID == 17 {
            guard length >= transport + 8, word(transport + 4) >= 8,
                  transport + word(transport + 4) <= length else { return false }
        } else { return false }
        let sourcePort = word(transport), destinationPort = word(transport + 2)
        if protocolID == 17 {
            // DHCPv4/v6 exceptions only. No global DNS/QUIC bypass is allowed.
            func localV4(_ offset: Int) -> Bool {
                bytes[offset] == 10 || bytes[offset] == 192 && bytes[offset + 1] == 168
                    || bytes[offset] == 172 && (16...31).contains(bytes[offset + 1])
                    || (0..<4).allSatisfy { bytes[offset + $0] == 0 }
                    || (0..<4).allSatisfy { bytes[offset + $0] == 255 }
            }
            if version == 4, localV4(source), localV4(destination),
               (sourcePort == 68 && destinationPort == 67 || sourcePort == 67 && destinationPort == 68) { return true }
            if version == 6, (sourcePort == 546 && destinationPort == 547 || sourcePort == 547 && destinationPort == 546),
               (bytes[destination] == 0xff && bytes[destination + 1] == 2 || bytes[destination] == 0xfe && bytes[destination + 1] & 0xc0 == 0x80) { return true }
        }
        guard policy.mode == .protected, protocolID == 6 else { return false }
        let offset = outbound ? destination : source
        let port = outbound ? destinationPort : sourcePort
        return endpoints.contains { address, expectedPort in
            guard address.count == size, expectedPort == port else { return false }
            return address.indices.allSatisfy { address[$0] == bytes[offset + $0] }
        }
    }
}

public struct NetworkLockHealth: Codable, Sendable {
    public let active: Bool
    public let revision: UUID?
    public let mode: NetworkLockMode?
    public let validPolicy: Bool
    public let tunnelInterface: String?
    public let nodeID: String?
    public var preservedPolicyReloads: Int? = nil
    /// Process-lifetime count of tunnel bindings dropped because the provider stopped renewing them.
    public var expiredBindings: Int? = nil
    public func confirms(_ policy: NetworkLockPolicy) -> Bool {
        active && validPolicy && revision == policy.revision && mode == policy.mode && nodeID == policy.nodeID
    }
    public init(active: Bool, policy: NetworkLockPolicy?, validPolicy: Bool) {
        self.active = active; revision = policy?.revision; mode = policy?.mode; self.validPolicy = validPolicy
        tunnelInterface = policy?.tunnelInterface; nodeID = policy?.nodeID
    }
}

public struct NetworkLockBinding: Codable, Sendable {
    public let nodeID: String
    public let interface: String
    public let interfaceIndex: UInt32
    public init(nodeID: String, interface: String, interfaceIndex: UInt32) throws {
        _ = try NetworkLockPolicy(mode: .protected, tunnelInterface: interface, nodeID: nodeID)
        guard interfaceIndex > 0 else { throw VPNError.invalidConfiguration }
        self.nodeID = nodeID; self.interface = interface; self.interfaceIndex = interfaceIndex
    }
    public func applying(to policy: NetworkLockPolicy) throws -> NetworkLockPolicy {
        _ = try Self(nodeID: nodeID, interface: interface, interfaceIndex: interfaceIndex)
        guard policy.mode == .protected, policy.nodeID == nodeID else { throw VPNError.invalidConfiguration }
        return try .init(mode: .protected, endpoints: policy.endpoints, tunnelInterface: interface,
                         revision: policy.revision, nodeID: nodeID)
    }
}
