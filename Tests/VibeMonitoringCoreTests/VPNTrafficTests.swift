import XCTest
@testable import VibeMonitoringCore

final class VPNTrafficTests: XCTestCase {
    func testRatesUseInterfaceByteDeltasAndMonotonicTime() throws {
        let first = VPNTrafficSample(interface: "utun1", received: 100, sent: 100, time: 10)
        let next = VPNTrafficSample(interface: "utun1", received: 2_148, sent: 1_124, time: 12)
        let rate = try XCTUnwrap(VPNTrafficRate.between(first, next))
        XCTAssertEqual(rate.received, 1_024)
        XCTAssertEqual(rate.sent, 512)
        XCTAssertEqual(rate.title, "↓1K ↑0K")
        XCTAssertNil(VPNTrafficRate.between(nil, next))
        XCTAssertNil(VPNTrafficRate.between(first, .init(interface: "utun2", received: 200, sent: 200, time: 12)))
        XCTAssertNil(VPNTrafficRate.between(first, .init(interface: "utun1", received: 20, sent: 20, time: 12)))
        XCTAssertNil(VPNTrafficRate.between(first, .init(interface: "utun1", received: 200, sent: 200, time: 30)))
    }

    func testCounterWrapDoesNotLoseTrafficOrInventAResetSpike() throws {
        let first = VPNTrafficSample(interface: "utun1", received: UInt32.max - 100, sent: 0, time: 10)
        let next = VPNTrafficSample(interface: "utun1", received: 99, sent: 0, time: 12)
        XCTAssertEqual(try XCTUnwrap(VPNTrafficRate.between(first, next)).received, 100)
        XCTAssertNil(VPNTrafficSample.read("en0"))
        XCTAssertNil(VPNTrafficSample.read("utun1\0en0"))
    }

    func testOldProviderHealthDoesNotInventAnInterfaceName() throws {
        let data = Data("{\"nodeID\":\"demo\",\"running\":true,\"reasserting\":false}".utf8)
        let health = try JSONDecoder().decode(VPNProviderHealth.self, from: data)
        XCTAssertNil(health.interfaceName)
    }
}
