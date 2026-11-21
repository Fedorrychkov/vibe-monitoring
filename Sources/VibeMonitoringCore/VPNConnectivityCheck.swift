import Foundation

public struct VPNConnectivityResult: Identifiable {
    public let id: String
    public let passed: Bool
    public let milliseconds: Int
    public let status: Int?
    public var detail: String? = nil
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
        let addresses = try? await VPNEndpointResolver.resolve("www.apple.com")
        return VPNConnectivityResult(id: "DNS lookup", passed: addresses != nil,
                                     milliseconds: Int((ProcessInfo.processInfo.systemUptime - start) * 1_000), status: nil,
                                     detail: addresses.map { values in
                                         "IPv4: \(values.filter { !$0.contains(":") }.count) · IPv6: \(values.filter { $0.contains(":") }.count)"
                                     })
    }

    static func checkHTTPS(_ name: String, url: String, config: URLSessionConfiguration = .ephemeral) async -> VPNConnectivityResult {
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForResource = 6
        config.waitsForConnectivity = false
        let metrics = ProbeMetrics()
        let session = URLSession(configuration: config, delegate: metrics, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 6
        let start = ProcessInfo.processInfo.systemUptime
        var status: Int?
        var failure: String?
        do {
            let (_, response) = try await session.data(for: request)
            status = (response as? HTTPURLResponse)?.statusCode
        } catch {
            switch (error as? URLError)?.code {
            case .timedOut: failure = "Timeout"
            case .cannotFindHost, .dnsLookupFailed: failure = "DNS failure"
            case .cannotConnectToHost: failure = "Connection failed"
            case .networkConnectionLost, .notConnectedToInternet: failure = "Network unavailable"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid: failure = "TLS failure"
            default: failure = "Request failed"
            }
        }
        let timing = metrics.snapshot()
        let detail = [failure.map { "\($0) · last observed phase: \(timing.phase)" }, timing.summary]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". ")
        return VPNConnectivityResult(id: name, passed: status.map { (200..<400).contains($0) } ?? false,
                                     milliseconds: Int((ProcessInfo.processInfo.systemUptime - start) * 1_000), status: status,
                                     detail: detail.isEmpty ? nil : detail)
    }
}

struct VPNConnectionTiming {
    var dnsStart: Date?, dnsEnd: Date?, connectStart: Date?, connectEnd: Date?
    var tlsStart: Date?, tlsEnd: Date?, requestStart: Date?, responseStart: Date?
    var protocolName: String?
    var phase: String {
        if responseStart != nil { return "HTTP response" }
        if requestStart != nil { return "waiting for HTTP response" }
        if tlsStart != nil && tlsEnd == nil { return "TLS handshake" }
        if connectStart != nil && connectEnd == nil { return "connection establishment" }
        if dnsStart != nil && dnsEnd == nil { return "DNS lookup" }
        return "unavailable"
    }
    var summary: String {
        func interval(_ name: String, _ start: Date?, _ end: Date?) -> String? {
            guard let start, let end, end >= start else { return nil }
            return "\(name) \(Int(end.timeIntervalSince(start) * 1_000)) ms"
        }
        // URLSession's connectEnd includes security handshakes; these intervals overlap.
        let parts = [interval("DNS", dnsStart, dnsEnd), interval(tlsStart == nil ? "Connect" : "Connect incl. TLS", connectStart, connectEnd),
                     interval("TLS", tlsStart, tlsEnd), interval("Response wait", requestStart, responseStart), protocolName]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
}

private final class ProbeMetrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var timing = VPNConnectionTiming()
    func snapshot() -> VPNConnectionTiming { lock.lock(); defer { lock.unlock() }; return timing }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let value = metrics.transactionMetrics.last else { return }
        lock.lock(); defer { lock.unlock() }
        timing = VPNConnectionTiming(dnsStart: value.domainLookupStartDate, dnsEnd: value.domainLookupEndDate,
            connectStart: value.connectStartDate, connectEnd: value.connectEndDate,
            tlsStart: value.secureConnectionStartDate, tlsEnd: value.secureConnectionEndDate,
            requestStart: value.requestStartDate, responseStart: value.responseStartDate,
            protocolName: ["h2", "h3", "http/1.1"].contains(value.networkProtocolName) ? value.networkProtocolName : nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
