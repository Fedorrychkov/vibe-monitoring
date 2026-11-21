import Foundation

@objc public protocol NetworkLockProtocol {
    func bind(_ request: Data, reply: @escaping (Data?) -> Void)
    func status(_ reply: @escaping (Data?) -> Void)
}

public enum NetworkLockClient {
    public static func status(binding: NetworkLockBinding? = nil) async throws -> NetworkLockHealth {
        let team = try VPNCredentialIdentity.ownTeam()
        let name = try VPNCredentialIdentity.serviceName(team: team, build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, peer: .networkLock)
        let call = LockStatusCall(name: name)
        call.connection.setCodeSigningRequirement(try VPNCredentialIdentity.requirement(for: .networkLock, team: team))
        return try await call.perform(binding: binding)
    }
}

private final class LockStatusCall: @unchecked Sendable {
    let connection: NSXPCConnection
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NetworkLockHealth, Error>?
    init(name: String) {
        connection = NSXPCConnection(machServiceName: name)
        connection.remoteObjectInterface = NSXPCInterface(with: NetworkLockProtocol.self)
    }
    func perform(binding: NetworkLockBinding?) async throws -> NetworkLockHealth {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            connection.invalidationHandler = { [weak self] in self?.finish(.failure(VPNError.providerUnavailable)) }
            connection.interruptionHandler = { [weak self] in self?.finish(.failure(VPNError.providerUnavailable)) }
            connection.resume()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in finish(.failure(VPNError.providerUnavailable)) }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in self?.finish(.failure(VPNError.providerUnavailable)) }) as? NetworkLockProtocol else {
                finish(.failure(VPNError.providerUnavailable)); return
            }
            let reply: (Data?) -> Void = { [self] data in
                guard let data, data.count <= 4_096, let health = try? JSONDecoder().decode(NetworkLockHealth.self, from: data) else {
                    finish(.failure(VPNError.providerUnavailable)); return
                }
                finish(.success(health))
            }
            if let binding, let data = try? JSONEncoder().encode(binding) { proxy.bind(data, reply: reply) }
            else { proxy.status(reply) }
        }
    }
    private func finish(_ result: Result<NetworkLockHealth, Error>) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        guard let pending else { return }
        connection.invalidate(); pending.resume(with: result)
    }
}
