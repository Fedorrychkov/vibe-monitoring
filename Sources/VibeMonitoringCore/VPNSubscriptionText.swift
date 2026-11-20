import Foundation

public enum VPNSubscriptionText {
    public static func normalize(_ data: Data) throws -> String {
        guard data.count <= 4 * 1024 * 1024, var text = String(data: data, encoding: .utf8) else { throw VPNError.invalidSubscription }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") {
            let compact = text.filter { !$0.isWhitespace }.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            let padded = compact + String(repeating: "=", count: (4 - compact.count % 4) % 4)
            guard let decoded = Data(base64Encoded: padded), let value = String(data: decoded, encoding: .utf8) else { throw VPNError.invalidSubscription }
            text = value
        }
        let lines = text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty, lines.count <= 200 else { throw VPNError.invalidSubscription }
        let supported = lines.filter { line in
            guard let url = URLComponents(string: line), let scheme = url.scheme, ["vless", "vmess", "trojan"].contains(scheme) else { return false }
            let items = url.queryItems ?? []
            if items.contains(where: { ["extra", "fm", "certificatefile", "keyfile", "keylog"].contains($0.name.lowercased()) }) { return false }
            let transport = items.first(where: { $0.name == "type" })?.value ?? "tcp"
            return ["tcp", "raw", "ws", "grpc", "httpupgrade"].contains(transport)
        }
        guard !supported.isEmpty else { throw VPNError.invalidSubscription }
        return supported.joined(separator: "\n")
    }
}
