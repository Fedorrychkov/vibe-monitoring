import Foundation
import LibXray
import VibeMonitoringCore

public enum XrayCore {
    private static let lock = NSLock()

    public static func invoke(_ method: String, payload: [String: Any] = [:]) throws -> [String: Any] {
        let input = try JSONSerialization.data(withJSONObject: ["apiVersion": 3, "method": method, "payload": payload])
        guard input.count <= 16 * 1024 * 1024, let text = String(data: input, encoding: .utf8) else { throw VPNError.invalidConfiguration }
        lock.lock()
        defer { lock.unlock() }
        let response = text.withCString { CGoInvoke(UnsafeMutablePointer(mutating: $0)) }
        guard let response else { throw VPNError.invalidConfiguration }
        defer { CGoFree(response) }
        let output = Data(String(cString: response).utf8)
        guard output.count <= 16 * 1024 * 1024,
              let result = try JSONSerialization.jsonObject(with: output) as? [String: Any],
              result["success"] as? Bool == true else { throw VPNError.invalidConfiguration }
        return result["data"] as? [String: Any] ?? [:]
    }

    public static func importSubscription(_ data: Data) throws -> [VPNNode] {
        let text = try VPNSubscriptionText.normalize(data)
        let result = try invoke("convertShareLinksToXrayJson", payload: ["text": text])
        guard let outbounds = result["outbounds"] as? [[String: Any]] else { throw VPNError.invalidSubscription }
        return try VPNNode.parse(outbounds: outbounds)
    }
}
