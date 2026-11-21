import Foundation
import Network

public struct VPNServerProbeResult: Sendable {
    public let milliseconds: Int
    public let reachable: Bool
}

/// TCP socket readiness only: a local TUN can acknowledge before contacting the destination.
/// This never authenticates a proxy or starts a VPN.
public enum VPNServerProbe {
    public static func measure(host: String, port: Int) async -> VPNServerProbeResult {
        guard !host.isEmpty, !host.contains("\0"), (1...65_535).contains(port) else {
            return .init(milliseconds: 0, reachable: false)
        }
        return await TCPProbe(host: host, port: UInt16(port)).run()
    }
}

private final class TCPProbe: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.vibemonitoring.server-probe")
    private var continuation: CheckedContinuation<VPNServerProbeResult, Never>?
    private var start: Double = 0
    init(host: String, port: UInt16) {
        connection = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: .tcp)
    }
    func run() async -> VPNServerProbeResult {
        await withCheckedContinuation { next in
            queue.async { [self] in
                continuation = next; start = ProcessInfo.processInfo.systemUptime
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready: self?.finish(true)
                    case .failed, .cancelled: self?.finish(false)
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 4) { [self] in finish(false) }
            }
        }
    }
    private func finish(_ passed: Bool) {
        guard let next = continuation else { return }
        continuation = nil; connection.stateUpdateHandler = nil; connection.cancel()
        next.resume(returning: .init(milliseconds: Int((ProcessInfo.processInfo.systemUptime - start) * 1_000), reachable: passed))
    }
}
