// Signing in to Spotify from the phone, for the wall.
//
// Spotify is the one big service with a real "what is playing right now"
// API, and it works for any device the account plays on: this phone, a
// laptop, a speaker. The sign-in happens here, in the system web sheet, with
// PKCE, so no secret exists anywhere. The tokens go straight to the wall,
// which polls Spotify from then on. No Mac, no server, nothing in between.
//
// The wall says which client id to use (Settings on the wall hold it), so
// the app never carries one of its own.

import AuthenticationServices
import CryptoKit
import Foundation
import SwiftUI
import UIKit

@MainActor
@Observable
final class SpotifyLink: NSObject {
    private(set) var busy = false
    private(set) var problem: String?
    @ObservationIgnored private var session: ASWebAuthenticationSession?

    static let scopes = "user-read-currently-playing user-read-playback-state user-modify-playback-state"
    static let redirect = "tessera://spotify"

    /// Runs the sign-in, exchanges the code, hands the wall the tokens.
    /// Returns true when the wall has them.
    func connect(clientID: String, wall: String) async -> Bool {
        busy = true
        defer { busy = false }
        problem = nil

        let verifier = Self.random(64)
        let challenge = Self.challenge(verifier)
        let state = Self.random(16)
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirect),
            .init(name: "scope", value: Self.scopes),
            .init(name: "state", value: state),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
        ]
        guard let url = c.url else { return false }

        let callback: URL
        do {
            callback = try await withCheckedThrowingContinuation { cont in
                let s = ASWebAuthenticationSession(url: url, callbackURLScheme: "tessera") { url, error in
                    if let url { cont.resume(returning: url) }
                    else { cont.resume(throwing: error ?? URLError(.cancelled)) }
                }
                s.presentationContextProvider = self
                s.prefersEphemeralWebBrowserSession = false
                self.session = s
                s.start()
            }
        } catch {
            let code = (error as? ASWebAuthenticationSessionError)?.code
            problem = code == .canceledLogin ? nil : "Spotify sign-in did not finish."
            return false
        }
        session = nil

        let q = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ n: String) -> String? { q.first { $0.name == n }?.value }
        guard value("state") == state, let code = value("code") else {
            problem = value("error").map { "Spotify said: \($0)" } ?? "Spotify sent nothing back."
            return false
        }

        // The exchange: code plus the verifier, nothing else.
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.form([
            "client_id": clientID, "grant_type": "authorization_code", "code": code,
            "redirect_uri": Self.redirect, "code_verifier": verifier,
        ])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let tokens = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              tokens["access_token"] != nil, tokens["refresh_token"] != nil else {
            problem = "Spotify would not issue tokens. Check the client id and the tessera://spotify redirect in the Spotify dashboard."
            return false
        }

        // To the wall, with the app id they belong to: the wall refreshes
        // them with it, so it must have the same one. From here on the wall
        // does the polling.
        var forWall = tokens
        forWall["client_id"] = clientID
        guard let wurl = URL(string: "http://\(wall)/spotify/tokens"),
              let body = try? JSONSerialization.data(withJSONObject: forWall) else { return false }
        var wreq = URLRequest(url: wurl)
        wreq.httpMethod = "POST"
        wreq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        wreq.httpBody = body
        wreq.timeoutInterval = 6
        guard let (_, wresp) = try? await URLSession.shared.data(for: wreq),
              (wresp as? HTTPURLResponse)?.statusCode == 200 else {
            problem = "Signed in, but the wall did not take the tokens. Is it on?"
            return false
        }
        return true
    }

    // MARK: - PKCE bits

    private static func random(_ n: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func challenge(_ verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func form(_ kv: [String: String]) -> Data {
        var c = URLComponents()
        c.queryItems = kv.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((c.percentEncodedQuery ?? "").utf8)
    }
}

extension SpotifyLink: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}
