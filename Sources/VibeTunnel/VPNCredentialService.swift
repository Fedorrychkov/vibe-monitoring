import Foundation
import Security
import VibeMonitoringCore

final class VPNCredentialService: NSObject, NSXPCListenerDelegate, VPNCredentialProtocol {
    static let shared = VPNCredentialService()
    private var listener: NSXPCListener?
    private let work = DispatchQueue(label: "dev.vibemonitoring.credential-storage")

    func start() throws {
        let team = try VPNCredentialIdentity.ownTeam()
        let name = try VPNCredentialIdentity.serviceName(team: team, build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        let service = NSXPCListener(machServiceName: name)
        service.setConnectionCodeSigningRequirement(try VPNCredentialIdentity.requirement(for: .app, team: team))
        service.delegate = self
        service.resume()
        listener = service
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: VPNCredentialProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func store(_ data: Data, reply: @escaping (Data?, String?, Int32) -> Void) {
        work.async {
            do {
                let node = try VPNNode.decodeValidated(data)
                reply(try VPNKeychain.saveSelected(node), nil, 0)
            } catch let error as VPNCredentialFailure { reply(nil, error.step.rawValue, error.status) }
            catch { reply(nil, VPNCredentialFailure.Step.validation.rawValue, errSecParam) }
        }
    }

    func probe(_ reply: @escaping (Data?, String?, Int32) -> Void) {
        work.async {
            do {
                try VPNKeychain.probeSelectedStorage()
                reply(Data(), nil, 0)
            } catch let error as VPNCredentialFailure { reply(nil, error.step.rawValue, error.status) }
            catch { reply(nil, VPNCredentialFailure.Step.validation.rawValue, errSecParam) }
        }
    }
}
