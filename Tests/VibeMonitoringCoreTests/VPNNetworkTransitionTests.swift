import XCTest
@testable import VibeMonitoringCore

final class VPNNetworkTransitionTests: XCTestCase {
    @MainActor
    func testDirectAccessRetiresTunnelBeforeRemovingLock() async throws {
        var events: [String] = []
        try await VPNNetworkTransition.perform(mode: .directAllowed,
            stopTunnel: { events.append("stop") },
            applyLock: { events.append($0.rawValue) })
        XCTAssertEqual(events, ["stop", "directAllowed"])
    }

    @MainActor
    func testPauseEstablishesLockBeforeStoppingTunnel() async throws {
        var events: [String] = []
        try await VPNNetworkTransition.perform(mode: .paused,
            stopTunnel: { events.append("stop") },
            applyLock: { events.append($0.rawValue) })
        XCTAssertEqual(events, ["paused", "stop"])
    }

    @MainActor
    func testFailedTunnelRetirementDoesNotUnlockOrReportSuccess() async {
        var unlocked = false
        do {
            try await VPNNetworkTransition.perform(mode: .directAllowed,
                stopTunnel: { throw VPNError.providerUnavailable },
                applyLock: { _ in unlocked = true })
            XCTFail("A failed retirement must be reported")
        } catch { XCTAssertFalse(unlocked) }
    }

    @MainActor
    func testFailedPauseDoesNotStopExistingTunnel() async {
        var stopped = false
        do {
            try await VPNNetworkTransition.perform(mode: .paused,
                stopTunnel: { stopped = true },
                applyLock: { _ in throw VPNError.providerUnavailable })
            XCTFail("A failed deny acknowledgement must be reported")
        } catch { XCTAssertFalse(stopped) }
    }

    @MainActor
    func testFailedFilterRemovalDoesNotReportSuccessfulDirectAccess() async {
        var stopped = false
        do {
            try await VPNNetworkTransition.perform(mode: .directAllowed,
                stopTunnel: { stopped = true },
                applyLock: { _ in throw VPNError.providerUnavailable })
            XCTFail("A failed filter removal must be reported")
        } catch { XCTAssertTrue(stopped) }
    }
}
