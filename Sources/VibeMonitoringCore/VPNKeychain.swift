import Foundation
import LocalAuthentication
import Security
import Darwin

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

    public static func saveSelected(_ node: VPNNode) throws -> Data {
        _ = try node.validatedOutbound()
        return try writeSystemData(JSONEncoder().encode(node), service: "dev.vibemonitoring.app.active-vpn", account: "configuration")
    }

    public static func probeSelectedStorage() throws {
        let account = UUID().uuidString
        let reference = try writeSystemData(Data("VibeMonitoring storage probe".utf8),
                                            service: "dev.vibemonitoring.app.credential-probe", account: account)
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                                    kSecValuePersistentRef as String: reference] as CFDictionary)
        guard status == errSecSuccess else { throw VPNCredentialFailure(.cleanup, status) }
    }

    private static func writeSystemData(_ data: Data, service: String, account: String) throws -> Data {
        // Only the system extension may write here. The menu app uses authenticated XPC.
        guard geteuid() == 0 else { throw VPNCredentialFailure(.privileges, errSecAuthFailed) }
        guard let executable = Bundle.main.executableURL else { throw VPNCredentialFailure(.trust, errSecParam) }
        var trusted: SecTrustedApplication?
        var status = SecTrustedApplicationCreateFromPath(executable.path, &trusted)
        guard status == errSecSuccess, let trusted else { throw VPNCredentialFailure(.trust, status) }
        var access: SecAccess?
        status = SecAccessCreate("VibeMonitoring VPN credentials" as CFString, [trusted] as CFArray, &access)
        guard status == errSecSuccess, let access else { throw VPNCredentialFailure(.trust, status) }
        var keychain: SecKeychain?
        // A system extension runs outside the user context and cannot read the user's Data Protection Keychain (TN3137).
        status = SecKeychainOpen("/Library/Keychains/System.keychain", &keychain)
        guard status == errSecSuccess, let keychain else { throw VPNCredentialFailure(.open, status) }
        var base = query(service: service)
        base[kSecAttrAccount as String] = account
        base[kSecMatchSearchList as String] = [keychain]
        let update: [String: Any] = [kSecValueData as String: data, kSecAttrAccess as String: access]
        status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(service: service)
            item[kSecAttrAccount as String] = account
            item[kSecUseKeychain as String] = keychain
            item[kSecAttrAccess as String] = access
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw VPNCredentialFailure(.write, status) }
        var request = base
        request[kSecReturnPersistentRef as String] = true
        var result: CFTypeRef?
        status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess, let reference = result as? Data else { throw VPNCredentialFailure(.reference, status) }
        guard try readSystemData(reference: reference) == data else { throw VPNCredentialFailure(.read, errSecDecode) }
        return reference
    }

    public static func loadSelected(reference: Data) throws -> VPNNode {
        try VPNNode.decodeValidated(readSystemData(reference: reference))
    }

    private static func readSystemData(reference: Data) throws -> Data {
        let request: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecValuePersistentRef as String: reference, kSecReturnData as String: true,
                                     kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, data.count <= 256 * 1024 else {
            throw VPNCredentialFailure(.read, status == errSecSuccess ? errSecDecode : status)
        }
        return data
    }
}
