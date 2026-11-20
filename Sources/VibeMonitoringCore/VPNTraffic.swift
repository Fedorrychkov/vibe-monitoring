import Darwin
import Foundation

public struct VPNTrafficSample {
    public let interface: String
    public let received: UInt32
    public let sent: UInt32
    public let time: TimeInterval

    public init(interface: String, received: UInt32, sent: UInt32, time: TimeInterval) {
        self.interface = interface; self.received = received; self.sent = sent; self.time = time
    }

    public static func read(_ name: String) -> Self? {
        guard name.range(of: "^utun[0-9]{1,6}$", options: .regularExpression) != nil else { return nil }
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return nil }
        defer { freeifaddrs(first) }
        var cursor = first
        while let current = cursor {
            let entry = current.pointee
            if String(cString: entry.ifa_name) == name, entry.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
               let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self).pointee {
                return Self(interface: name, received: data.ifi_ibytes, sent: data.ifi_obytes,
                            time: ProcessInfo.processInfo.systemUptime)
            }
            cursor = entry.ifa_next
        }
        return nil
    }
}

public struct VPNTrafficRate {
    public let received: Double
    public let sent: Double

    public static func between(_ previous: VPNTrafficSample?, _ current: VPNTrafficSample) -> Self? {
        guard let previous, previous.interface == current.interface else { return nil }
        let seconds = current.time - previous.time
        guard seconds >= 0.1, seconds <= 10 else { return nil }
        func delta(_ before: UInt32, _ after: UInt32) -> Double? {
            if after >= before { return Double(after - before) }
            guard before > 0xf0000000, after < 0x0fffffff else { return nil }
            return Double(after &- before)
        }
        guard let received = delta(previous.received, current.received), let sent = delta(previous.sent, current.sent) else { return nil }
        return Self(received: received / seconds, sent: sent / seconds)
    }

    public static func formatted(_ bytes: Double) -> String {
        if bytes >= 1_048_576 { return String(format: "%.1fM", bytes / 1_048_576) }
        return String(format: "%.0fK", bytes / 1_024)
    }

    public var title: String { "↓\(Self.formatted(received)) ↑\(Self.formatted(sent))" }
}
