import Foundation
import VibeMonitoringCore

final class LockStatusService: NSObject, NSXPCListenerDelegate, NetworkLockProtocol {
    static let shared = LockStatusService()
    private var listener: NSXPCListener?
    func start() throws {
        let team = try VPNCredentialIdentity.ownTeam()
        let name = try VPNCredentialIdentity.serviceName(team: team, build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, peer: .networkLock)
        let service = NSXPCListener(machServiceName: name)
        let app = try VPNCredentialIdentity.requirement(for: .app, team: team)
        let tunnel = try VPNCredentialIdentity.requirement(for: .provider, team: team)
        service.setConnectionCodeSigningRequirement("(\(app)) or (\(tunnel))")
        service.delegate = self; service.resume(); listener = service
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: NetworkLockProtocol.self)
        connection.exportedObject = self
        connection.resume(); return true
    }
    func bind(_ request: Data, reply: @escaping (Data?) -> Void) {
        guard request.count <= 1_024, let binding = try? JSONDecoder().decode(NetworkLockBinding.self, from: request),
              LockRuntime.shared.bind(binding) else { reply(nil); return }
        reply(try? JSONEncoder().encode(LockRuntime.shared.health()))
    }
    func status(_ reply: @escaping (Data?) -> Void) { reply(try? JSONEncoder().encode(LockRuntime.shared.health())) }
}
