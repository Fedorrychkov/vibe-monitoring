import Foundation
import Security

@objc public protocol VPNCredentialProtocol {
    func store(_ node: Data, reply: @escaping (Data?, String?, Int32) -> Void)
    func probe(_ reply: @escaping (Data?, String?, Int32) -> Void)
}

public struct VPNCredentialFailure: Error, LocalizedError, Equatable {
    public enum Step: String, Sendable { case connection, validation, privileges, trust, open, write, reference, read, cleanup }
    public let step: Step
    public let status: Int32
    public init(_ step: Step, _ status: Int32) { self.step = step; self.status = status }
    public var errorDescription: String? { "VPN credential preparation failed (\(step.rawValue), code \(status))." }
}

public enum VPNCredentialIdentity {
    public enum Peer: String { case app = "dev.vibemonitoring.app", provider = "dev.vibemonitoring.app.tunnel" }

    public static func requirement(for peer: Peer, team: String) throws -> String {
        guard team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
            throw VPNCredentialFailure(.trust, errSecParam)
        }
        return "anchor apple generic and identifier \"\(peer.rawValue)\" and certificate leaf[subject.OU] = \"\(team)\""
    }

    public static func serviceName(team: String, build: String?) throws -> String {
        _ = try requirement(for: .provider, team: team)
        guard let build, build.range(of: "^[0-9]{1,10}$", options: .regularExpression) != nil else {
            throw VPNCredentialFailure(.validation, errSecParam)
        }
        // A stable name can remain bound to a removed extension after upgrades (Apple FB17032197).
        return team + ".dev.vibemonitoring.app.tunnel." + build
    }

    public static func ownTeam() throws -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String else {
            throw VPNCredentialFailure(.trust, errSecCSUnsigned)
        }
        _ = try requirement(for: .app, team: team)
        return team
    }
}

public enum VPNCredentialClient {
    public static func store(_ node: VPNNode) async throws -> Data {
        _ = try node.validatedOutbound()
        let body = try JSONEncoder().encode(node)
        guard body.count <= 256 * 1024 else { throw VPNCredentialFailure(.validation, errSecParam) }
        let exchange = try VPNCredentialExchange()
        let reference = try await exchange.perform(body)
        guard !reference.isEmpty else { throw VPNCredentialFailure(.reference, errSecItemNotFound) }
        return reference
    }

    public static func probeStorage() async throws {
        let exchange = try VPNCredentialExchange()
        _ = try await exchange.perform(nil)
    }
}

private final class VPNCredentialExchange: @unchecked Sendable {
    private let connection: NSXPCConnection
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?

    init() throws {
        let team = try VPNCredentialIdentity.ownTeam()
        let name = try VPNCredentialIdentity.serviceName(team: team, build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        connection = NSXPCConnection(machServiceName: name, options: [])
        connection.setCodeSigningRequirement(try VPNCredentialIdentity.requirement(for: .provider, team: team))
        connection.remoteObjectInterface = NSXPCInterface(with: VPNCredentialProtocol.self)
    }

    func perform(_ body: Data?) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            connection.invalidationHandler = { [weak self] in self?.complete(.failure(VPNCredentialFailure(.connection, 4099))) }
            connection.interruptionHandler = { [weak self] in self?.complete(.failure(VPNCredentialFailure(.connection, 4097))) }
            connection.resume()
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.complete(.failure(VPNCredentialFailure(.connection, -1001)))
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
                self?.complete(.failure(VPNCredentialFailure(.connection, Int32(clamping: (error as NSError).code))))
            }) as? VPNCredentialProtocol else {
                complete(.failure(VPNCredentialFailure(.connection, 4099)))
                return
            }
            let reply: (Data?, String?, Int32) -> Void = { [weak self] data, step, status in
                if let step {
                    self?.complete(.failure(VPNCredentialFailure(VPNCredentialFailure.Step(rawValue: step) ?? .connection, status)))
                } else if status == 0, let data, data.count <= 8_192 {
                    self?.complete(.success(data))
                } else {
                    self?.complete(.failure(VPNCredentialFailure(.reference, errSecParam)))
                }
            }
            if let body { proxy.store(body, reply: reply) }
            else { proxy.probe(reply) }
        }
    }

    private func complete(_ result: Result<Data, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        connection.invalidate()
        pending.resume(with: result)
    }
}
