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
    /// The refresh in flight. Every caller waits on it: spending one refresh
    /// token twice trips yui-auth's reuse check, which ends every session.
    private var refreshing: Task<String, Error>?
    /// Runs before sign out, while the session still works (push unregister).
    var willSignOut: (() async -> Void)?

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
        if let invite = pendingInviteCode { body["invite_code"] = invite }
        let reply: TokenReply = try await post("yui-auth", body)
        store(reply, appleUserID: credential.user)
        if reply.invite != nil || reply.invite_error != nil { pendingInviteCode = nil }
        if reply.invite_error != nil { inviteNotice = Self.inviteFailed(reply.invite_error!) }
    }

    // MARK: Invites (YUI-56)

    /// An invite code waiting for Sign in with Apple, from a yuigui.com/i/<code>
    /// link or typed on the sign-in screen. Kept across launches. Without one,
    /// the email on your Apple ID finds your invite on its own.
    var pendingInviteCode: String? = UserDefaults.standard.string(forKey: "yuiInviteCode") {
        didSet { UserDefaults.standard.set(pendingInviteCode, forKey: "yuiInviteCode") }
    }
    /// One line about the last invite that didn't work, shown for a moment.
    var inviteNotice: String?

    /// `https://www.yuigui.com/i/ABCDE-FGHJK` or `yui://invite/ABCDE-FGHJK`.
    static func inviteCode(in url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        let raw: String? = switch url.scheme {
        case "yui" where url.host() == "invite": parts.first
        case "https" where ["www.yuigui.com", "yuigui.com"].contains(url.host() ?? "") && parts.first == "i": parts.dropFirst().first
        default: nil
        }
        return raw.flatMap(normalizedInviteCode)
    }

    /// "abcde fghjk" -> "ABCDE-FGHJK". Nil when it can't be a code.
    static func normalizedInviteCode(_ s: String) -> String? {
        let n = s.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard (6...32).contains(n.count) else { return nil }
        return n.count == 10 ? "\(n.prefix(5))-\(n.suffix(5))" : n
    }

    /// An invite link opened. Signed out: it waits for Sign in with Apple.
    /// Signed in: it is claimed now. False when the URL is not an invite.
    func open(_ url: URL) -> Bool {
        guard let code = Self.inviteCode(in: url) else { return false }
        if isSignedIn { Task { await claimInvite(code) } } else { pendingInviteCode = code }
        return true
    }

    func claimInvite(_ code: String) async {
        do {
            let token = try await validAccessToken()
            let _: InviteReply = try await post("yui-auth", ["grant_type": "invite", "code": code], bearer: token)
            inviteNotice = nil
        } catch AccountError.server(let reason) {
            inviteNotice = Self.inviteFailed(reason)
        } catch {
            inviteNotice = "Couldn't open that invite. Check your connection and open the link again."
        }
    }

    private static func inviteFailed(_ reason: String) -> String {
        reason == "rate_limited"
            ? "Too many invite codes tried. Wait a few minutes and open the link again."
            : "That invite code didn't work. It may be used already. Ask for a new link."
    }

    /// App Review: the code in the review notes signs in to the one demo
    /// account, whose demo agent answers. No Apple ID behind it.
    func signIn(reviewCode: String) async throws {
        let reply: TokenReply = try await post("yui-auth", ["grant_type": "review", "code": reviewCode])
        store(reply, appleUserID: Self.reviewAppleID)
    }

    static let reviewAppleID = "review"
    var isReviewAccount: Bool { session?.appleUserID == Self.reviewAppleID }

    /// Apple can revoke Yui from Settings > Apple ID; check on launch.
    func checkAppleCredential() async {
        guard let appleID = session?.appleUserID, appleID != "demo", appleID != "debug",
              appleID != Self.reviewAppleID else { return }
        let state = try? await ASAuthorizationAppleIDProvider().credentialState(forUserID: appleID)
        if state == .revoked || state == .notFound { clear() }
    }

    // MARK: Session

    func validAccessToken() async throws -> String {
        guard let s = session else { throw AccountError.signedOut }
        if s.accessExpiry.timeIntervalSinceNow > 60 { return s.accessToken }
        if let refreshing { return try await refreshing.value }
        let task = Task { () async throws -> String in
            do {
                let reply: TokenReply = try await post("yui-auth", ["grant_type": "refresh", "refresh_token": s.refreshToken])
                store(reply, appleUserID: s.appleUserID)
                return reply.access_token
            } catch AccountError.server("invalid_grant") {
                clear()
                throw AccountError.signedOut
            }
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    func signOut() async {
        await willSignOut?()
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
        Outbox.shared.clear()  // unsent messages belonged to that account
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
        var invite: Invite?
        var invite_error: String?
    }
    private struct Invite: Decodable { let first_name: String?; let agent_template: String? }
    private struct InviteReply: Decodable { let invite: Invite }
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
