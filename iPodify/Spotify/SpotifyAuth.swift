import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

/// Spotify sign-in with Authorization Code + PKCE. Tokens live in the Keychain.
@MainActor
final class SpotifyAuth: NSObject, ObservableObject {
    @Published private(set) var isSignedIn: Bool

    private var tokens: Tokens? {
        didSet {
            Keychain.save(tokens)
            isSignedIn = tokens != nil
        }
    }
    private var refreshTask: Task<String, Error>?

    struct Tokens: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
    }

    enum AuthError: LocalizedError {
        case missingClientID, cancelled, badCallback, tokenRequestFailed(String)
        var errorDescription: String? {
            switch self {
            case .missingClientID: return "Add your Client ID in Config.swift"
            case .cancelled: return "Sign-in cancelled"
            case .badCallback: return "Spotify didn't return a code"
            case .tokenRequestFailed(let body): return "Token request failed: \(body)"
            }
        }
    }

    override init() {
        let stored = Keychain.load()
        tokens = stored
        isSignedIn = stored != nil
        super.init()
    }

    func signOut() {
        tokens = nil
    }

    func signIn() async throws {
        guard !Config.spotifyClientID.hasPrefix("PASTE_") else { throw AuthError.missingClientID }

        let verifier = Self.randomString(length: 64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        let state = Self.randomString(length: 16)

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: Config.spotifyClientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Config.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state),
            .init(name: "scope", value: Config.scopes.joined(separator: " ")),
        ]

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: components.url!,
                callbackURLScheme: Config.callbackScheme
            ) { url, error in
                if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: error.map { _ in AuthError.cancelled } ?? AuthError.badCallback) }
            }
            session.presentationContextProvider = self
            session.start()
        }

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value
        else { throw AuthError.badCallback }

        tokens = try await requestTokens([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Config.redirectURI,
            "client_id": Config.spotifyClientID,
            "code_verifier": verifier,
        ], previousRefreshToken: nil)
    }

    /// Returns a valid access token, refreshing it if it's about to expire.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let tokens else { throw AuthError.cancelled }
        if !forceRefresh, tokens.expiresAt.timeIntervalSinceNow > 60 { return tokens.accessToken }
        if let refreshTask { return try await refreshTask.value }

        let task = Task { () throws -> String in
            defer { self.refreshTask = nil }
            do {
                let fresh = try await requestTokens([
                    "grant_type": "refresh_token",
                    "refresh_token": tokens.refreshToken,
                    "client_id": Config.spotifyClientID,
                ], previousRefreshToken: tokens.refreshToken)
                self.tokens = fresh
                return fresh.accessToken
            } catch AuthError.tokenRequestFailed(let body) {
                // Refresh token revoked or expired: back to the sign-in screen.
                if body.contains("invalid_grant") { self.tokens = nil }
                throw AuthError.tokenRequestFailed(body)
            }
        }
        refreshTask = task
        return try await task.value
    }

    private func requestTokens(_ form: [String: String], previousRefreshToken: String?) async throws -> Tokens {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .formValue)!)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AuthError.tokenRequestFailed(String(decoding: data, as: UTF8.self))
        }

        struct Response: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let refresh = decoded.refresh_token ?? previousRefreshToken else {
            throw AuthError.tokenRequestFailed("No refresh token")
        }
        return Tokens(
            accessToken: decoded.access_token,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(decoded.expires_in)
        )
    }

    private static func randomString(length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in chars.randomElement(using: &generator)! })
    }
}

extension SpotifyAuth: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first ?? ASPresentationAnchor()
        }
    }
}

private enum Keychain {
    static let service = "ipodify.spotify"

    static func save(_ tokens: SpotifyAuth.Tokens?) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
        guard let tokens, let data = try? JSONEncoder().encode(tokens) else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> SpotifyAuth.Tokens? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(SpotifyAuth.Tokens.self, from: data)
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension CharacterSet {
    static let formValue: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
