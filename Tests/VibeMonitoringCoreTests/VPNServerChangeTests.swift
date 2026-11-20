import Foundation
import XCTest
@testable import VibeMonitoringCore

final class VPNServerChangeTests: XCTestCase {
    func testSwitchPayloadRoundTripsOnlyReferencesAndValidatedAddresses() throws {
        let value = try VPNServerChange(nodeID: String(repeating: "a", count: 64), reference: Data([1, 2]), addresses: ["192.0.2.1"])
        let decoded = try VPNServerChange.decode(JSONEncoder().encode(value))
        XCTAssertEqual(decoded.nodeID, value.nodeID)
        XCTAssertEqual(decoded.reference, value.reference)
        XCTAssertEqual(decoded.addresses, value.addresses)
    }

    func testTamperedOversizedAndUnboundedSwitchRequestsFail() throws {
        for payload: [String: Any] in [
            ["nodeID": "wrong", "reference": "AQI=", "addresses": ["192.0.2.1"]],
            ["nodeID": String(repeating: "a", count: 64), "reference": "", "addresses": ["192.0.2.1"]],
            ["nodeID": String(repeating: "a", count: 64), "reference": "AQI=", "addresses": ["vpn.example"]],
        ] {
            XCTAssertThrowsError(try VPNServerChange.decode(JSONSerialization.data(withJSONObject: payload)))
        }
        XCTAssertThrowsError(try VPNServerChange.decode(Data(repeating: 32, count: 16_385)))
        XCTAssertThrowsError(try VPNServerChange(nodeID: String(repeating: "a", count: 64), reference: Data(repeating: 1, count: 8_193), addresses: ["192.0.2.1"]))
    }
}
