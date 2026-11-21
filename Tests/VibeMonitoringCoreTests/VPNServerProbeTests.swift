import Darwin
import XCTest
@testable import VibeMonitoringCore

final class VPNServerProbeTests: XCTestCase {
    func testTCPHandshakeUsesOnlyLocalListenerAndRejectsClosedPort() async throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { XCTFail("Local socket creation failed"); return }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { value in
            value.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 1) == 0 else { close(fd); XCTFail("Local listener failed"); return }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { value in
            value.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))
        let success = await VPNServerProbe.measure(host: "127.0.0.1", port: port)
        close(fd)
        XCTAssertTrue(success.reachable)
        let refused = await VPNServerProbe.measure(host: "127.0.0.1", port: port)
        XCTAssertFalse(refused.reachable)
        let invalid = await VPNServerProbe.measure(host: "127.0.0.1", port: 65_536)
        XCTAssertFalse(invalid.reachable)
        XCTAssertEqual(invalid.milliseconds, 0)
    }
}
