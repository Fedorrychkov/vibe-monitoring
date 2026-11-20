import Foundation
import Security

enum VPNInstallation {
    static let providerID = "dev.vibemonitoring.app.tunnel"

    static var signingReady: Bool {
        let extensionURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(providerID).systemextension")
        guard let main = signingInfo(Bundle.main.bundleURL),
              let team = main[kSecCodeInfoTeamIdentifier as String] as? String,
              let appEntitlements = main[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              appEntitlements["com.apple.developer.system-extension.install"] as? Bool == true,
              validEntitlements(appEntitlements, team: team),
              let ext = signingInfo(extensionURL), ext[kSecCodeInfoTeamIdentifier as String] as? String == team,
              let entitlements = ext[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              validEntitlements(entitlements, team: team) else { return false }
        return true
    }

    private static func validEntitlements(_ values: [String: Any], team: String) -> Bool {
        (values["com.apple.developer.networking.networkextension"] as? [String])?.contains("packet-tunnel-provider-systemextension") == true
            && (values["com.apple.security.application-groups"] as? [String])?.contains(team + ".dev.vibemonitoring.app") == true
    }

    private static func signingInfo(_ url: URL) -> [String: Any]? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return info as? [String: Any]
    }
}
