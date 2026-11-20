import Foundation
import XCTest
@testable import VibeMonitoringCore

private final class QuickpingProtocol: URLProtocol {
    struct Stub { let status: Int; let data: Data }
    private static let lock = NSLock()
    private static var handlers: [String: (URLRequest) -> Stub] = [:]

    static func register(host: String, handler: @escaping (URLRequest) -> Stub) {
        lock.lock(); defer { lock.unlock() }
        handlers[host] = handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handlers[request.url?.host ?? ""]
        Self.lock.unlock()
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let stub = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class QuickpingClientTests: XCTestCase {
    private func fixture() -> Data {
        Data("""
        {"sampledAt":"2026-11-20T14:00:00.000Z","services":[
          {"id":"demo-api","name":"Orbit API","status":"operational","lastCheckedAt":"2026-11-20T13:59:55Z","latencyMs":142,"openIncidents":[]},
          {"id":"demo-worker","name":"Worker","status":"unknown","lastCheckedAt":null,"latencyMs":null,"openIncidents":[]}
        ],"truncated":false}
        """.utf8)
    }

    private func client() -> QuickpingClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QuickpingProtocol.self]
        return QuickpingClient(configuration: configuration)
    }

    func testSignInExchangeAndReadOnlySnapshotUseSeparateCredentials() async throws {
        let server = try QuickpingServer("https://\(UUID().uuidString.lowercased()).example")
        let token = "qp_desktop_" + String(repeating: "t", count: 43)
        let snapshot = fixture()
        QuickpingProtocol.register(host: server.origin.host!) { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            if request.url!.path.hasSuffix("/token") {
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertEqual(request.httpMethod, "POST")
                return .init(status: 200, data: Data("{\"access_token\":\"\(token)\",\"token_type\":\"Bearer\",\"scope\":\"monitoring:read\",\"expires_in\":3600}".utf8))
            }
            XCTAssertEqual(request.url!.path, "/api/v1/integrations/monitoring")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + token)
            return .init(status: 200, data: snapshot)
        }
        let client = client()
        let access = try await client.exchange(code: String(repeating: "c", count: 43), authorization: QuickpingAuthorization(), server: server)
        let result = try await client.snapshot(using: access)
        XCTAssertEqual(result.services.count, 2)
        XCTAssertEqual(result.services.last?.status, "unknown")
        XCTAssertFalse(result.isStale(at: result.sampledAt.addingTimeInterval(30)))
        XCTAssertTrue(result.isStale(at: result.sampledAt.addingTimeInterval(121)))
        XCTAssertTrue(result.isStale(at: result.sampledAt.addingTimeInterval(-61)))
    }

    func testRevokedAccessAndMissingServerAPIHaveDistinctErrors() async throws {
        for (status, expected) in [(401, QuickpingError.unauthorized), (404, .serverUpdateRequired), (503, .unavailable)] {
            let server = try QuickpingServer("https://\(UUID().uuidString.lowercased()).example")
            QuickpingProtocol.register(host: server.origin.host!) { _ in .init(status: status, data: Data()) }
            let access = QuickpingCredential(server: server.origin.absoluteString, accessToken: "test", expiresAt: .distantFuture)
            do {
                _ = try await client().snapshot(using: access)
                XCTFail("Unexpected successful request")
            } catch let error as QuickpingError {
                XCTAssertEqual(String(describing: error), String(describing: expected))
            }
        }
    }

    func testOversizedAndDuplicateServiceResponsesAreRejected() async throws {
        let duplicate = Data("""
        {"sampledAt":"2026-11-20T14:00:00Z","services":[
          {"id":"same","name":"A","status":"down","lastCheckedAt":null,"latencyMs":null,"openIncidents":[]},
          {"id":"same","name":"B","status":"down","lastCheckedAt":null,"latencyMs":null,"openIncidents":[]}
        ],"truncated":false}
        """.utf8)
        for body in [duplicate, Data(repeating: 32, count: 1_048_577)] {
            let server = try QuickpingServer("https://\(UUID().uuidString.lowercased()).example")
            QuickpingProtocol.register(host: server.origin.host!) { _ in .init(status: 200, data: body) }
            let access = QuickpingCredential(server: server.origin.absoluteString, accessToken: "test", expiresAt: .distantFuture)
            do {
                _ = try await client().snapshot(using: access)
                XCTFail("Untrusted response was accepted")
            } catch let error as QuickpingError {
                XCTAssertEqual(String(describing: error), String(describing: QuickpingError.invalidResponse))
            }
        }
    }
}
