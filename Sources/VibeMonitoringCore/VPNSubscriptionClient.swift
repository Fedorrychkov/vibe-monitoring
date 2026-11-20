import Foundation

private final class SubscriptionRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct VPNSubscriptionClient: Sendable {
    private let session: URLSession

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: SubscriptionRedirects(), delegateQueue: nil)
    }

    public static func url(_ text: String) throws -> URL {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil, let url = parts.url else {
            throw VPNError.invalidSubscription
        }
        return url
    }

    public func fetch(_ url: URL) async throws -> Data {
        _ = try Self.url(url.absoluteString)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("text/plain, application/json", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  response.expectedContentLength <= 4 * 1024 * 1024 else { throw VPNError.invalidSubscription }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 4 * 1024 * 1024 else { throw VPNError.invalidSubscription }
                data.append(byte)
            }
            guard !data.isEmpty else { throw VPNError.invalidSubscription }
            return data
        } catch { throw VPNError.invalidSubscription }
    }
}
