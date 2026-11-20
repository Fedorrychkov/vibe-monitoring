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
        }
    }
}
