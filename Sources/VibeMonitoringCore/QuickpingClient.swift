import Foundation

private final class RejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct QuickpingClient: Sendable {
    private let session: URLSession

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
    }

    public func exchange(code: String, authorization: QuickpingAuthorization, server: QuickpingServer) async throws -> QuickpingCredential {
        let body = try JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code", "client_id": QuickpingAuthorization.clientID,
            "redirect_uri": QuickpingAuthorization.callback, "code": code, "code_verifier": authorization.verifier,
        ])
        let data = try await request(server.endpoint("api/v1/integrations/token"), method: "POST", body: body)
        struct Token: Decodable {
            let access_token: String
            let token_type: String
            let expires_in: Double
            let scope: String
        }
        guard let token = try? JSONDecoder().decode(Token.self, from: data),
              token.token_type == "Bearer", token.scope == QuickpingAuthorization.scope,
              token.expires_in.isFinite, token.expires_in > 0, token.expires_in <= 30 * 24 * 60 * 60,
              token.access_token.range(of: "^qp_desktop_[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else {
            throw QuickpingError.invalidResponse
        }
        return QuickpingCredential(server: server.origin.absoluteString, accessToken: token.access_token,
                                   expiresAt: Date().addingTimeInterval(token.expires_in))
    }

    public func snapshot(using credential: QuickpingCredential) async throws -> QuickpingSnapshot {
        guard credential.expiresAt > Date() else { throw QuickpingError.unauthorized }
        let server = try QuickpingServer(credential.server)
        let data = try await request(server.endpoint("api/v1/integrations/monitoring"), token: credential.accessToken)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: text) else { throw QuickpingError.invalidResponse }
            return date
        }
        guard let value = try? decoder.decode(QuickpingSnapshot.self, from: data), value.services.count <= 100,
              Set(value.services.map(\.id)).count == value.services.count,
              value.services.allSatisfy({ !$0.id.isEmpty && $0.name.count <= 500 && $0.openIncidents.count <= 5 }) else {
            throw QuickpingError.invalidResponse
        }
        return value
    }

    public func revoke(_ credential: QuickpingCredential) async throws {
        let server = try QuickpingServer(credential.server)
        _ = try await request(server.endpoint("api/v1/integrations/revoke"), method: "POST", token: credential.accessToken)
    }

    private func request(_ url: URL, method: String = "GET", token: String? = nil, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw QuickpingError.invalidResponse }
            switch http.statusCode {
            case 200: break
            case 401, 403: throw QuickpingError.unauthorized
            case 404: throw QuickpingError.serverUpdateRequired
            case 400: throw QuickpingError.authorizationFailed
            default: throw QuickpingError.unavailable
            }
            guard http.mimeType == "application/json", response.expectedContentLength <= 1_048_576 else {
                throw QuickpingError.invalidResponse
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 1_048_576 else { throw QuickpingError.invalidResponse }
                data.append(byte)
            }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as QuickpingError { throw error }
        catch { throw QuickpingError.unavailable }
    }
}
