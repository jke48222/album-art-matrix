import AuthenticationServices
import CryptoKit
import Foundation
import SwiftUI
import UIKit

/// PKCE credentials exist in memory until the wall acknowledges their receipt.
@MainActor
@Observable
final class SpotifyLink: NSObject {
    enum Phase { case idle, authorizing, exchanging, saving, connected, cancelled, refused, failed }
    private(set) var busy = false
    private(set) var phase: Phase = .idle
    private(set) var problem: String?
    @ObservationIgnored private var session: ASWebAuthenticationSession?
    @ObservationIgnored private var callback: CheckedContinuation<URL, Error>?
    @ObservationIgnored private var operation = UUID()
    @ObservationIgnored private var pending: Receipt?

    /// Read-only, matching the wall's own SCOPES (brain/nowplaying/spotify.py).
    /// The wall keeps this token behind its LAN API, so it must not be able
    /// to control playback.
    static let scopes = "user-read-currently-playing user-read-playback-state"
    static let redirect = "tessera://spotify"
    var canRetryDelivery: Bool { pending != nil && !busy }

    private struct Tokens: Decodable {
        let access_token: String
        let refresh_token: String
        let expires_in: Double
        let scope: String?
    }
    private struct Receipt {
        let tokens: Tokens
        let clientID: String
        let host: String
        let expiresAt: Date
        let accountName: String?
    }

    func cancel() {
        operation = UUID()
        let continuation = callback; callback = nil
        session?.cancel(); session = nil
        continuation?.resume(throwing: CancellationError())
        pending = nil; busy = false; problem = nil; phase = .cancelled
    }

    func connect(clientID: String, wall: String) async -> Bool {
        guard !busy else { return false }
        pending = nil; busy = true; problem = nil; phase = .authorizing
        let id = UUID(); operation = id
        defer { if operation == id { busy = false; session = nil } }
        do {
            let verifier = try Self.random(64), state = try Self.random(24)
            var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
            components.queryItems = [
                .init(name: "client_id", value: clientID), .init(name: "response_type", value: "code"),
                .init(name: "redirect_uri", value: Self.redirect), .init(name: "scope", value: Self.scopes),
                .init(name: "state", value: state), .init(name: "code_challenge_method", value: "S256"),
                .init(name: "code_challenge", value: Self.challenge(verifier)),
            ]
            guard let url = components.url else { throw URLError(.badURL) }
            let returned: URL = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    callback = continuation
                    let browser = ASWebAuthenticationSession(url: url, callbackURLScheme: "tessera") { [weak self] url, error in
                        Task { @MainActor [weak self] in
                            guard let self, self.operation == id, let continuation = self.callback else { return }
                            self.callback = nil; self.session = nil
                            if let url { continuation.resume(returning: url) }
                            else { continuation.resume(throwing: error ?? URLError(.cancelled)) }
                        }
                    }
                    browser.presentationContextProvider = self
                    browser.prefersEphemeralWebBrowserSession = false
                    session = browser
                    if !browser.start(), let continuation = callback {
                        callback = nil; session = nil
                        continuation.resume(throwing: URLError(.cannotOpenFile))
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in if self?.operation == id { self?.cancel() } }
            }
            guard operation == id, !Task.isCancelled else { return false }
            let query = URLComponents(url: returned, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? {
                let matches = query.filter { $0.name == name }
                return matches.count == 1 ? matches[0].value : nil
            }
            guard returned.scheme == "tessera", returned.host == "spotify", returned.path.isEmpty,
                  value("state") == state else {
                phase = .failed; problem = "This sign-in has expired. Start again from this page."; return false
            }
            if value("error") != nil {
                phase = .refused; problem = "Spotify was not connected. Allow access when you're ready to try again."; return false
            }
            guard let code = value("code"), !code.isEmpty else {
                phase = .failed; problem = "Spotify did not complete sign-in. Please try again."; return false
            }
            phase = .exchanging
            var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
            request.httpMethod = "POST"; request.timeoutInterval = 20
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.form(["client_id": clientID, "grant_type": "authorization_code", "code": code,
                                        "redirect_uri": Self.redirect, "code_verifier": verifier])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard operation == id, !Task.isCancelled else { return false }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let tokens = try? JSONDecoder().decode(Tokens.self, from: data),
                  !tokens.access_token.isEmpty, !tokens.refresh_token.isEmpty,
                  tokens.expires_in.isFinite, (1...86400).contains(tokens.expires_in) else {
                phase = .failed
                problem = "Spotify could not finish sign-in. Check your Client ID and the redirect address in Spotify's dashboard, then try again."
                return false
            }
            let expires = Date().addingTimeInterval(tokens.expires_in)
            let name = await accountName(token: tokens.access_token)
            guard operation == id, !Task.isCancelled else { return false }
            pending = Receipt(tokens: tokens, clientID: clientID, host: wall, expiresAt: expires, accountName: name)
            return await deliver(id: id)
        } catch {
            guard operation == id else { return false }
            let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled || (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
            phase = cancelled ? .cancelled : .failed
            problem = cancelled ? nil : "Sign-in could not finish. Check your connection and try again."
            return false
        }
    }

    func retryDelivery(host: String, clientID: String) async -> Bool {
        guard !busy, let pending else { return false }
        guard pending.host == host, pending.clientID == clientID else {
            self.pending = nil; phase = .failed; problem = "The Spotify connection changed. Sign in again for this wall."; return false
        }
        busy = true; problem = nil
        let id = UUID(); operation = id
        defer { if operation == id { busy = false } }
        return await deliver(id: id)
    }

    private func deliver(id: UUID) async -> Bool {
        guard let receipt = pending else { return false }
        let remaining = receipt.expiresAt.timeIntervalSinceNow
        guard remaining > 60 else {
            pending = nil; phase = .failed; problem = "This sign-in has expired. Sign in again to connect the wall."; return false
        }
        phase = .saving
        guard let url = URL(string: "http://\(receipt.host)/spotify/tokens") else { return false }
        var body: [String: Any] = ["access_token": receipt.tokens.access_token, "refresh_token": receipt.tokens.refresh_token,
                                   "expires_in": remaining, "client_id": receipt.clientID]
        if let scope = receipt.tokens.scope { body["scope"] = scope }
        if let name = receipt.accountName { body["account_name"] = name }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard operation == id, !Task.isCancelled else { return false }
            if (response as? HTTPURLResponse)?.statusCode == 409 {
                pending = nil; phase = .failed; problem = "The wall's Spotify app changed. Refresh this page and sign in again."; return false
            }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let fresh = try? JSONDecoder().decode(WallServices.self, from: data),
                  fresh.spotify.linked, fresh.spotify.client_id == receipt.clientID else {
                phase = .failed; problem = "Signed in to Spotify. The wall hasn't confirmed it yet. Retry sending when it reconnects."; return false
            }
            pending = nil; phase = .connected; problem = nil
            return true
        } catch {
            guard operation == id else { return false }
            phase = .failed; problem = "Signed in to Spotify. The wall hasn't confirmed it yet. Retry sending when it reconnects."
            return false
        }
    }

    private func accountName(token: String) async -> String? {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); request.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let profile = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (profile["display_name"] as? String ?? profile["id"] as? String).map { String($0.prefix(120)) }
    }

    private static func random(_ count: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw URLError(.cannotCreateFile) }
        return base64(Data(bytes))
    }
    private static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func challenge(_ verifier: String) -> String { base64(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    private static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(values.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").utf8)
    }
}

extension SpotifyLink: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}
