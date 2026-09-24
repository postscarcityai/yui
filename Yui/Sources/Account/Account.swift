import AuthenticationServices
import CryptoKit
import Foundation
import Observation

/// A signed-in Yui session. Kept in the keychain; the access token is a
/// short-lived yui_user JWT from the `yui-auth` edge function.
struct YuiSession: Codable, Equatable {
    var userID: String
    var appleUserID: String
    var email: String?
    var accessToken: String
    var accessExpiry: Date
    var refreshToken: String
}

enum AccountError: LocalizedError {
    case server(String)
    case signedOut

    var errorDescription: String? {
        switch self {
        case .server(let code): "Yui's server said \(code). Try again in a moment."
        case .signedOut: "Your session ended. Sign in again."
        }
    }
}

/// Sign in with Apple, session refresh, sign out and account deletion.
@MainActor @Observable
final class Account {
    private(set) var session: YuiSession?
    var isSignedIn: Bool { session != nil }

    private static let keychainKey = "session"
    /// Raw nonce for the Apple request in flight; Apple only sees its SHA-256.
    private var pendingNonce: String?

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-yuiDemoAccount") {
            session = YuiSession(userID: "demo", appleUserID: "demo", email: "chris@privaterelay.appleid.com",
                                 accessToken: "", accessExpiry: .distantFuture, refreshToken: "")
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-yuiSignedOut") { return }
        // Simulator runs against the live backend: `-yuiRefreshToken <token> -yuiUserID <uuid>`
        // (a yui_sessions row made server-side). Sign in with Apple can't be driven headless.
        if let rt = UserDefaults.standard.string(forKey: "yuiRefreshToken"),
           let uid = UserDefaults.standard.string(forKey: "yuiUserID") {
            session = YuiSession(userID: uid, appleUserID: "debug", email: nil,
                                 accessToken: "", accessExpiry: .distantPast, refreshToken: rt)
            return
        }
        #endif
        session = Keychain.load(YuiSession.self, key: Self.keychainKey)
        NotificationCenter.default.addObserver(
            forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.clear() }
        }
    }

    // MARK: Sign in with Apple

    func prepare(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonce()
        pendingNonce = nonce
        request.requestedScopes = [.email]
        request.nonce = Self.sha256(nonce)
    }

    func complete(_ result: Result<ASAuthorization, Error>) async throws {
        let authorization = try result.get()
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8),
              let nonce = pendingNonce
        else { throw AccountError.server("invalid_credential") }
        pendingNonce = nil

        var body = ["grant_type": "apple", "identity_token": identityToken, "nonce": nonce]
        if let code = credential.authorizationCode.flatMap({ String(data: $0, encoding: .utf8) }) {
            body["authorization_code"] = code
        }
        let reply: TokenReply = try await post("yui-auth", body)
        store(reply, appleUserID: credential.user)
    }

    /// Apple can revoke Yui from Settings > Apple ID; check on launch.
    func checkAppleCredential() async {
        guard let appleID = session?.appleUserID, appleID != "demo", appleID != "debug" else { return }
        let state = try? await ASAuthorizationAppleIDProvider().credentialState(forUserID: appleID)
        if state == .revoked || state == .notFound { clear() }
    }

    // MARK: Session

    func validAccessToken() async throws -> String {
        guard let s = session else { throw AccountError.signedOut }
        if s.accessExpiry.timeIntervalSinceNow > 60 { return s.accessToken }
        do {
            let reply: TokenReply = try await post("yui-auth", ["grant_type": "refresh", "refresh_token": s.refreshToken])
            store(reply, appleUserID: s.appleUserID)
            return reply.access_token
        } catch AccountError.server("invalid_grant") {
            clear()
            throw AccountError.signedOut
        }
    }

    func signOut() async {
        if let token = session?.refreshToken, !token.isEmpty {
            let _: OKReply? = try? await post("yui-auth", ["grant_type": "sign_out", "refresh_token": token])
        }
        clear()
    }

    /// Deletes the account and everything Yui stores for it, and revokes
    /// Yui's Sign in with Apple token. App Store Review Guideline 5.1.1(v).
    func deleteAccount() async throws {
        #if DEBUG
        if session?.userID == "demo" { clear(); return }
        #endif
        let token = try await validAccessToken()
        let _: DeleteReply = try await post("yui-delete", [String: String](), bearer: token)
        clear()
    }

    private func clear() {
        Keychain.delete(key: Self.keychainKey)
        session = nil
    }

    private func store(_ reply: TokenReply, appleUserID: String) {
        let s = YuiSession(userID: reply.user.id, appleUserID: appleUserID,
                           email: reply.user.email ?? session?.email,
                           accessToken: reply.access_token,
                           accessExpiry: Date().addingTimeInterval(TimeInterval(reply.expires_in)),
                           refreshToken: reply.refresh_token)
        Keychain.save(s, key: Self.keychainKey)
        session = s
    }

    // MARK: Network

    private struct TokenReply: Decodable {
        struct User: Decodable { let id: String; let email: String? }
        let access_token: String
        let expires_in: Int
        let refresh_token: String
        let user: User
    }
    private struct DeleteReply: Decodable { let deleted: Bool }
    private struct OKReply: Decodable { let ok: Bool }
    private struct ErrorReply: Decodable { let error: String }

    private func post<T: Decodable>(_ function: String, _ body: [String: String], bearer: String? = nil) async throws -> T {
        var req = URLRequest(url: YuiBackend.function(function))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(YuiBackend.publishableKey, forHTTPHeaderField: "apikey")
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(ErrorReply.self, from: data))?.error ?? "error"
            throw AccountError.server(code)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
