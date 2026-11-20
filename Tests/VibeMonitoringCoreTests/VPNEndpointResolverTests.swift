import Foundation
import XCTest
@testable import VibeMonitoringCore

final class VPNEndpointResolverTests: XCTestCase {
    func testNumericEndpointsResolveWithoutExternalDNS() async throws {
        for address in ["192.0.2.10", "2001:db8::10"] {
            let values = try await VPNEndpointResolver.resolve(address)
            XCTAssertTrue(values.contains(address))
        }
    }

    func testBootstrapRejectsDomainsMalformedIPsAndOversizedLists() throws {
        let valid = ["192.0.2.10", "2001:db8::10"]
        XCTAssertEqual(try VPNTunnelConfiguration.validatedAddresses(valid), valid)
        for values in [[], ["vpn.example"], ["192.0.2.10\0.other"], ["not-an-address"],
                       Array(repeating: "192.0.2.10", count: 33)] {
            XCTAssertThrowsError(try VPNTunnelConfiguration.validatedAddresses(values))
        }
    }

    func testLookupFailureAndEmptyResultsBecomeSafePreparationErrors() async {
        for empty in [false, true] {
            do {
                _ = try await VPNEndpointResolver.resolve(timeout: 1) {
                    if empty { return [] }
                    throw NSError(domain: "private-server-details", code: 99)
                }
                XCTFail("Invalid DNS preparation was accepted")
            } catch {
                guard case VPNError.serverResolutionFailed = error else { return XCTFail("Expected safe resolution failure") }
                XCTAssertFalse(error.localizedDescription.contains("private-server-details"))
            }
        }
    }

    func testDeadlineReturnsWhileTheSystemLookupIsStillBlocked() async {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        do {
            _ = try await VPNEndpointResolver.resolve(timeout: 0.02) {
                gate.wait()
                return ["192.0.2.10"]
            }
            XCTFail("The pending DNS lookup must not block preparation indefinitely")
        } catch {
            guard case VPNError.serverResolutionFailed = error else { return XCTFail("Expected resolution timeout") }
        }
    }

    func testEmbeddedNullHostnameIsRejectedBeforeLookup() async {
        do {
            _ = try await VPNEndpointResolver.resolve("vpn.example\0.other")
            XCTFail("Truncated hostname was accepted")
        } catch {
            guard case VPNError.serverResolutionFailed = error else { return XCTFail("Expected invalid hostname") }
        }
    }
}
