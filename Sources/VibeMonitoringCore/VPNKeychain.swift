import Foundation
import LocalAuthentication
import Security

public enum VPNKeychain {
    private static func query(service: String, group: String? = nil) -> [String: Any] {
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: "configuration"]
        if let group {
            result[kSecAttrAccessGroup as String] = group
            result[kSecUseDataProtectionKeychain as String] = true
        }
        return result
    }

    private static func save(_ data: Data, query: [String: Any]) throws {
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw VPNError.keychainUnavailable }
    }

    public static func saveSubscription(_ value: VPNSubscription) throws {
        try save(JSONEncoder().encode(value), query: query(service: "dev.vibemonitoring.app.subscription"))
    }

    public static func loadSubscription() throws -> VPNSubscription? {
        var request = query(service: "dev.vibemonitoring.app.subscription")
        request[kSecReturnData as String] = true
        let context = LAContext(); context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw VPNError.keychainUnavailable }
        return try JSONDecoder().decode(VPNSubscription.self, from: data)
    }

    public static func saveSelected(_ node: VPNNode, group: String) throws -> Data {
        _ = try node.validatedOutbound()
        let base = query(service: "dev.vibemonitoring.app.active-vpn", group: group)
        try save(JSONEncoder().encode(node), query: base)
        var request = base
        request[kSecReturnPersistentRef as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let reference = result as? Data else { throw VPNError.keychainUnavailable }
        return reference
    }

    public static func loadSelected(reference: Data) throws -> VPNNode {
        let request: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecValuePersistentRef as String: reference, kSecReturnData as String: true,
                                     kSecUseDataProtectionKeychain as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count <= 256 * 1024 else { throw VPNError.keychainUnavailable }
        let node = try JSONDecoder().decode(VPNNode.self, from: data)
        _ = try node.validatedOutbound()
        return node
    }
}
