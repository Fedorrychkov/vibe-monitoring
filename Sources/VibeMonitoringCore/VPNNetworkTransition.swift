import Foundation

/// Direct access first retires our tunnel; locked pause first establishes the deny policy.
public enum VPNNetworkTransition {
    @MainActor
    public static func perform(mode: NetworkLockMode,
                               stopTunnel: () async throws -> Void,
                               applyLock: (NetworkLockMode) async throws -> Void) async throws {
        switch mode {
        case .directAllowed:
            try await stopTunnel()
            try await applyLock(.directAllowed)
        case .paused:
            try await applyLock(.paused)
            try await stopTunnel()
        case .protected:
            throw VPNError.invalidConfiguration
        }
    }
}
