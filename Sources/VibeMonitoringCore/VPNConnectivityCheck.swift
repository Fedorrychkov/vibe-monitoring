import Foundation

public struct VPNConnectivityResult: Identifiable {
    public let id: String
    public let passed: Bool
    public let milliseconds: Int
    public let status: Int?
}

public struct VPNConnectivityReport {
    public let time: Date
    public let results: [VPNConnectivityResult]
}

public enum VPNConnectivityCheck {
    public static func run() async -> VPNConnectivityReport {
        async let dns = checkDNS()
        async let apple = checkHTTPS("HTTPS · Apple", url: "https://www.apple.com/")
        async let github = checkHTTPS("HTTPS · GitHub", url: "https://github.com/")
        return await VPNConnectivityReport(time: Date(), results: [dns, apple, github])
    }

    private static func checkDNS() async -> VPNConnectivityResult {
        let start = ProcessInfo.processInfo.systemUptime
        let passed = (try? await VPNEndpointResolver.resolve("www.apple.com")) != nil
        return VPNConnectivityResult(id: "DNS lookup", passed: passed,
                                     milliseconds: Int((ProcessInfo.processInfo.systemUptime - start) * 1_000), status: nil)
    }

    static func checkHTTPS(_ name: String, url: String, config: URLSessionConfiguration = .ephemeral) async -> VPNConnectivityResult {
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForResource = 6
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 6
        let start = ProcessInfo.processInfo.systemUptime
        var status: Int?
        do {
            let (_, response) = try await session.data(for: request)
            status = (response as? HTTPURLResponse)?.statusCode
        } catch { /* Only the result is reported; raw errors may contain network details. */ }
        return VPNConnectivityResult(id: name, passed: status.map { (200..<400).contains($0) } ?? false,
                                     milliseconds: Int((ProcessInfo.processInfo.systemUptime - start) * 1_000), status: status)
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
