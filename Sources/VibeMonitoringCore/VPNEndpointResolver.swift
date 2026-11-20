import Darwin
import Foundation

public enum VPNEndpointResolver {
    public static func resolve(_ host: String) async throws -> [String] {
        guard !host.isEmpty, host.utf8.count <= 253, !host.contains("\0") else { throw VPNError.serverResolutionFailed }
        return try await resolve(timeout: 8) { try lookup(host) }
    }

    static func resolve(timeout: TimeInterval, lookup: @escaping @Sendable () throws -> [String]) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            let result = ResolutionResult(continuation)
            DispatchQueue.global(qos: .utility).async {
                do { result.finish(.success(try VPNTunnelConfiguration.validatedAddresses(lookup()))) }
                catch { result.finish(.failure(VPNError.serverResolutionFailed)) }
            }
            // getaddrinfo may outlive this deadline; a late result must not continue VPN setup.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                result.finish(.failure(VPNError.serverResolutionFailed))
            }
        }
    }

    private static func lookup(_ host: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var first: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &first) == 0 else { throw VPNError.serverResolutionFailed }
        defer { if let first { freeaddrinfo(first) } }
        var addresses: [String] = []
        var cursor = first
        while let current = cursor, addresses.count < 32 {
            let item = current.pointee
            if let address = item.ai_addr, item.ai_family == AF_INET || item.ai_family == AF_INET6 {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, item.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let value = String(cString: buffer)
                    if !addresses.contains(value) { addresses.append(value) }
                }
            }
            cursor = item.ai_next
        }
        return addresses
    }
}

private final class ResolutionResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String], Error>?
    init(_ continuation: CheckedContinuation<[String], Error>) { self.continuation = continuation }

    func finish(_ result: Result<[String], Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
