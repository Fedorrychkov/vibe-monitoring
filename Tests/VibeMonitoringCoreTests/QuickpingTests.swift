import Foundation
import XCTest
@testable import VibeMonitoringCore

final class QuickpingTests: XCTestCase {
    func testAuthorizationBindsCallbackStateAndPKCE() throws {
        XCTAssertEqual(QuickpingAuthorization.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let authorization = QuickpingAuthorization()
        let server = try QuickpingServer("https://quickping.example")
        let url = authorization.url(server: server)
        XCTAssertEqual(url.host, "quickping.example")
        XCTAssertFalse(url.absoluteString.contains(authorization.verifier))
        XCTAssertNotEqual(authorization.state, QuickpingAuthorization().state)
        let callback = URL(string: "\(QuickpingAuthorization.callback)?state=\(authorization.state)&code=\(String(repeating: "c", count: 43))")!
        XCTAssertEqual(try authorization.code(from: callback).count, 43)
        XCTAssertThrowsError(try authorization.code(from: URL(string: callback.absoluteString + "&state=duplicate")!))
        XCTAssertThrowsError(try QuickpingAuthorization().code(from: callback))
        XCTAssertThrowsError(try authorization.code(from: URL(string: callback.absoluteString.replacingOccurrences(of: "/callback", with: "/wrong"))!))
    }

    func testServerRejectsCredentialsNonTLSAndPaths() throws {
        for value in ["https://user:secret@quickping.example", "http://quickping.example", "file:///tmp/test", "https://quickping.example/path", "https://quickping.example?token=secret"] {
            XCTAssertThrowsError(try QuickpingServer(value))
        }
        XCTAssertEqual(try QuickpingServer("http://127.0.0.1:3000").origin.port, 3000)
    }

    func testProfileWebsiteURLUsesTheSameAPIOriginAsTheDefault() throws {
        XCTAssertEqual(try QuickpingServer("https://quickping.tech/profile").origin,
                       try QuickpingServer(QuickpingServer.defaultOrigin).origin)
        XCTAssertEqual(try QuickpingServer("https://quickping.tech/profile/").endpoint("api/v1/integrations/monitoring").path,
                       "/api/v1/integrations/monitoring")
    }
}
