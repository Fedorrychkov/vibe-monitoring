import AppKit
import AuthenticationServices
import SwiftUI
import VibeMonitoringCore

@MainActor
final class QuickpingStore: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var snapshot: QuickpingSnapshot?
    @Published private(set) var issue: String?
    @Published private(set) var serverText: String
    @Published private(set) var expiresAt: Date?
    @Published private(set) var isConnecting = false
    @Published private(set) var isRefreshing = false
    private let demo: Bool
    private let client = QuickpingClient()
    private var credential: QuickpingCredential?
    private var polling: Task<Void, Never>?
    private var connecting: Task<Void, Never>?
    private var authentication: ASWebAuthenticationSession?
    private let anchor = NSWindow()

    var hasAccess: Bool { credential != nil || demo }
    var stale: Bool { issue != nil || snapshot?.isStale() != false }

    init(demo: Bool) {
        self.demo = demo
        let savedServer = UserDefaults.standard.string(forKey: "quickpingServer")?.trimmingCharacters(in: .whitespacesAndNewlines)
        serverText = demo ? "https://quickping.example" : savedServer.flatMap { $0.isEmpty ? nil : $0 } ?? QuickpingServer.defaultOrigin
        super.init()
        if demo { snapshot = DemoData.quickpingSnapshot(); return }
        do {
            credential = try QuickpingKeychain.load()
            if let credential {
                _ = try QuickpingServer(credential.server)
                serverText = credential.server
                expiresAt = credential.expiresAt
                startPolling()
            }
        } catch { issue = "Saved Quickping access is unavailable. Connect again or unlock Keychain." }
    }

    deinit { polling?.cancel(); connecting?.cancel() }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) ?? anchor
    }

    func connect(to text: String) {
        guard !demo, !isConnecting, credential == nil else { return }
        issue = nil
        let server: QuickpingServer
        do { server = try QuickpingServer(text) } catch { issue = error.localizedDescription; return }
        isConnecting = true
        connecting = Task { [weak self] in
            guard let self else { return }
            defer { self.isConnecting = false; self.authentication = nil }
            do {
                let attempt = QuickpingAuthorization()
                let callback = try await self.authenticate(attempt.url(server: server))
                try Task.checkCancellation()
                let code = try attempt.code(from: callback)
                let access = try await self.client.exchange(code: code, authorization: attempt, server: server)
                try Task.checkCancellation()
                do { try QuickpingKeychain.save(access) }
                catch {
                    try? await self.client.revoke(access)
                    throw error
                }
                self.credential = access
                self.serverText = access.server
                self.expiresAt = access.expiresAt
                UserDefaults.standard.set(access.server, forKey: "quickpingServer")
                self.startPolling()
            } catch {
                if !Task.isCancelled { self.issue = error.localizedDescription }
            }
        }
    }

    private func authenticate(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "dev.vibemonitoring.app") { callback, error in
                if let callback { continuation.resume(returning: callback) }
                else { continuation.resume(throwing: error ?? QuickpingError.authorizationFailed) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            authentication = session
            NSApp.activate(ignoringOtherApps: true)
            if !session.start() { continuation.resume(throwing: QuickpingError.authorizationFailed) }
        }
    }

    func cancelConnection() {
        connecting?.cancel()
        authentication?.cancel()
    }

    private func startPolling() {
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    func refresh() async {
        guard !demo, let credential, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let next = try await client.snapshot(using: credential)
            guard !Task.isCancelled, self.credential?.accessToken == credential.accessToken else { return }
            snapshot = next
            issue = nil
        } catch {
            guard !Task.isCancelled, self.credential?.accessToken == credential.accessToken else { return }
            issue = error.localizedDescription
        }
    }

    func disconnect() {
        guard !demo else { return }
        do { try QuickpingKeychain.delete() } catch { issue = error.localizedDescription; return }
        let previous = credential
        polling?.cancel()
        credential = nil
        expiresAt = nil
        snapshot = nil
        issue = nil
        if let previous {
            Task {
                do { try await client.revoke(previous) }
                catch {
                    if credential == nil {
                        issue = "Disconnected locally. Server revocation could not be confirmed; revoke access on Quickping's Connected apps page."
                    }
                }
            }
        }
    }
}
