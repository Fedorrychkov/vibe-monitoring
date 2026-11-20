import Foundation
import LocalAuthentication
import Security

public enum VPNKeychain {
    private static func query(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "configuration"]
    }

    private static func save(_ data: Data, query: [String: Any]) throws {
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
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

    public static func saveSelected(_ node: VPNNode, trustedExecutables: [URL]) throws -> Data {
        _ = try node.validatedOutbound()
        guard trustedExecutables.count == 2 else { throw VPNError.invalidConfiguration }
        var trusted: [SecTrustedApplication] = []
        for url in trustedExecutables {
            var application: SecTrustedApplication?
            guard SecTrustedApplicationCreateFromPath(url.path, &application) == errSecSuccess,
                  let application else { throw VPNError.keychainUnavailable }
            trusted.append(application)
        }
        var access: SecAccess?
        guard SecAccessCreate("VibeMonitoring selected VPN server" as CFString, trusted as CFArray, &access) == errSecSuccess,
              let access else { throw VPNError.keychainUnavailable }
        var keychain: SecKeychain?
        // A system extension runs outside the user context and cannot read the user's Data Protection Keychain (TN3137).
        guard SecKeychainOpen("/Library/Keychains/System.keychain", &keychain) == errSecSuccess,
              let keychain else { throw VPNError.keychainUnavailable }
        var base = query(service: "dev.vibemonitoring.app.active-vpn")
        base[kSecMatchSearchList as String] = [keychain]
        let data = try JSONEncoder().encode(node)
        let update: [String: Any] = [kSecValueData as String: data, kSecAttrAccess as String: access]
        var status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(service: "dev.vibemonitoring.app.active-vpn")
            item[kSecUseKeychain as String] = keychain
            item[kSecAttrAccess as String] = access
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw VPNError.keychainUnavailable }
        var request = base
        request[kSecReturnPersistentRef as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let reference = result as? Data else { throw VPNError.keychainUnavailable }
        guard try loadSelected(reference: reference).id == node.id else { throw VPNError.keychainUnavailable }
        return reference
    }

    public static func loadSelected(reference: Data) throws -> VPNNode {
        let request: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecValuePersistentRef as String: reference, kSecReturnData as String: true,
                                     kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count <= 256 * 1024 else { throw VPNError.keychainUnavailable }
        let node = try JSONDecoder().decode(VPNNode.self, from: data)
        _ = try node.validatedOutbound()
        return node
    }
}
