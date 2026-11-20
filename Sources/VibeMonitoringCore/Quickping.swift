import CryptoKit
import Foundation

public enum QuickpingError: Error, LocalizedError {
    case invalidServer, invalidCallback, invalidResponse, authorizationFailed, unauthorized, serverUpdateRequired, unavailable

    public var errorDescription: String? {
        switch self {
        case .invalidServer: return "Enter an HTTPS server origin, without a path, credentials or query. HTTP is allowed only on loopback."
        case .invalidCallback: return "The sign-in response did not match this connection attempt. Please try again."
        case .invalidResponse: return "Quickping returned an unsupported response."
        case .authorizationFailed: return "Quickping sign-in was not approved or the authorization code expired."
        case .unauthorized: return "Quickping access expired or was revoked. Connect again in Settings."
        case .serverUpdateRequired: return "This Quickping server does not have the desktop integration API yet."
        case .unavailable: return "Quickping could not be reached. Previous results may be stale."
        }
    }
}

public struct QuickpingServer: Sendable, Equatable {
    public let origin: URL

    public init(_ text: String) throws {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host)),
              let url = parts.url else { throw QuickpingError.invalidServer }
        origin = url
    }

    public func endpoint(_ path: String) -> URL { origin.appendingPathComponent(path) }
}

public struct QuickpingAuthorization: Sendable {
    public static let clientID = "vibe-monitoring"
    public static let callback = "dev.vibemonitoring.app://quickping/callback"
    public static let scope = "monitoring:read"
    public let verifier: String
    public let state: String

    public init() {
        verifier = Self.randomSecret()
        state = Self.randomSecret()
    }

    public static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
    }

    public func url(server: QuickpingServer) -> URL {
        var parts = URLComponents(url: server.endpoint("integrations/vibe-monitoring"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.callback),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
            URLQueryItem(name: "state", value: state),
        ]
        return parts.url!
    }

    public func code(from url: URL) throws -> String {
        guard url.scheme == "dev.vibemonitoring.app", url.host == "quickping", url.path == "/callback",
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state else { throw QuickpingError.invalidCallback }
        if items.contains(where: { $0.name == "error" }) { throw QuickpingError.authorizationFailed }
        guard items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value,
              code.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else { throw QuickpingError.invalidCallback }
        return code
    }

    private static func randomSecret() -> String {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64URL
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public struct QuickpingCredential: Codable, Sendable {
    public let server: String
    public let accessToken: String
    public let expiresAt: Date

    public init(server: String, accessToken: String, expiresAt: Date) {
        self.server = server
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }
}

public struct QuickpingIncident: Decodable, Identifiable, Sendable {
    public let id: String
    public let reason: String
    public let openedAt: Date
}

public struct QuickpingService: Decodable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let status: String
    public let lastCheckedAt: Date?
    public let latencyMs: Double?
    public let openIncidents: [QuickpingIncident]
}

public struct QuickpingSnapshot: Decodable, Sendable {
    public let sampledAt: Date
    public let services: [QuickpingService]
    public let truncated: Bool

    public func isStale(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(sampledAt) > 120 || sampledAt.timeIntervalSince(now) > 60
    }
}
