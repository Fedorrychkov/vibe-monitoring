import Foundation
import XCTest
@testable import VibeMonitoringCore

private final class VPNProbeProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.httpMethod == "HEAD", request.value(forHTTPHeaderField: "Cookie") == nil,
              request.value(forHTTPHeaderField: "Authorization") == nil else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        if request.url!.path == "/timeout" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
        }
        let status = request.url!.path == "/blocked" ? 403 : 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class VPNConnectivityCheckTests: XCTestCase {
    func testHEADChecksSeparateSuccessHTTPFailureAndTimeout() async {
        for (path, expected, code) in [("/ok", true, 200 as Int?), ("/blocked", false, 403), ("/timeout", false, nil)] {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [VPNProbeProtocol.self]
            let result = await VPNConnectivityCheck.checkHTTPS("Synthetic check", url: "https://probe.example" + path, config: config)
            XCTAssertEqual(result.passed, expected)
            XCTAssertEqual(result.status, code)
            XCTAssertGreaterThanOrEqual(result.milliseconds, 0)
            if path == "/timeout" { XCTAssertTrue(result.detail?.contains("Timeout") == true) }
        }
    }
    func testTimingDistinguishesIncompleteDNSConnectTLSAndResponseWait() {
        let start = Date(timeIntervalSince1970: 1_000)
        var timing = VPNConnectionTiming()
        XCTAssertEqual(timing.phase, "unavailable")
        timing.dnsStart = start
        XCTAssertEqual(timing.phase, "DNS lookup")
        timing.dnsEnd = start.addingTimeInterval(0.1); timing.connectStart = timing.dnsEnd
        XCTAssertEqual(timing.phase, "connection establishment")
        timing.tlsStart = start.addingTimeInterval(0.2)
        XCTAssertEqual(timing.phase, "TLS handshake")
        timing.tlsEnd = start.addingTimeInterval(0.4); timing.connectEnd = timing.tlsEnd
        timing.requestStart = timing.tlsEnd
        XCTAssertEqual(timing.phase, "waiting for HTTP response")
        timing.responseStart = start.addingTimeInterval(0.6)
        XCTAssertEqual(timing.phase, "HTTP response")
        XCTAssertTrue(timing.summary.contains("DNS"))
        XCTAssertTrue(timing.summary.contains("TLS"))
        timing.dnsEnd = start.addingTimeInterval(-1)
        XCTAssertFalse(timing.summary.contains("DNS"))
    }

    func testConnectionTimingLabelsOverlappingTLSInterval() {
        let start = Date(timeIntervalSince1970: 1_000)
        var timing = VPNConnectionTiming(connectStart: start, connectEnd: start.addingTimeInterval(0.375),
                                         tlsStart: start.addingTimeInterval(0.125), tlsEnd: start.addingTimeInterval(0.375))
        XCTAssertEqual(timing.summary, "Connect incl. TLS 375 ms · TLS 250 ms")
        timing.tlsStart = nil; timing.tlsEnd = nil
        XCTAssertEqual(timing.summary, "Connect 375 ms")
    }

}
