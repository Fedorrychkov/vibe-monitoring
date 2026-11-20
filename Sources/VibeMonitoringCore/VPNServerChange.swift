import Foundation

public struct VPNServerChange: Codable {
    public let nodeID: String
    public let reference: Data
    public let addresses: [String]

    public init(nodeID: String, reference: Data, addresses: [String]) throws {
        guard nodeID.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              !reference.isEmpty, reference.count <= 8_192 else { throw VPNError.invalidConfiguration }
        self.nodeID = nodeID
        self.reference = reference
        self.addresses = try VPNTunnelConfiguration.validatedAddresses(addresses)
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16_384 else { throw VPNError.invalidConfiguration }
        let value = try JSONDecoder().decode(Self.self, from: data)
        return try Self(nodeID: value.nodeID, reference: value.reference, addresses: value.addresses)
    }
}
