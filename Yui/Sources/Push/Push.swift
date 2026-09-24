import Foundation
import Observation
import UIKit
import UserNotifications

/// Push notifications and the `yui://` deep link (YUI-8).
///
/// Any agent can hand the user something from another channel ("send it to
/// Yui" on Telegram): its host writes into that agent's thread and asks
/// `yui-push` to notify this phone. Tapping the notification, or opening
/// `yui://agent/<agent id>/thread`, lands in that thread.
@MainActor @Observable
final class PushCenter: NSObject {
    static let shared = PushCenter()

    /// A thread to open, from a notification tap or a link. ChatView consumes it.
    var pendingAgentID: String?
    /// The thread on screen right now: its own pushes don't show a banner.
    var visibleAgentID: String?
    private(set) var deviceToken: String?
    private weak var account: Account?
    private var registeredFor: String?

    /// TestFlight and App Store builds talk to production APNs, Xcode builds to the sandbox.
    static var environment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    /// Signed in: ask once for permission, then hand the device token to Yui.
    func start(account: Account) async {
        self.account = account
        UNUserNotificationCenter.current().delegate = self
        let center = UNUserNotificationCenter.current()
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            status = await center.notificationSettings().authorizationStatus
        }
        guard status == .authorized || status == .provisional || status == .ephemeral else { return }
        UIApplication.shared.registerForRemoteNotifications()
        await upload()
    }

    func didRegister(_ token: Data) {
        deviceToken = token.map { String(format: "%02x", $0) }.joined()
        Task { await upload() }
    }

    /// Sign out: this phone stops getting that account's pushes.
    func stop() async {
        defer { registeredFor = nil }
        guard let token = deviceToken, let account, account.isSignedIn,
              let bearer = try? await account.validAccessToken() else { return }
        _ = try? await call(["action": "unregister", "token": token], bearer: bearer)
    }

    private func upload() async {
        guard let token = deviceToken, let account, let user = account.session?.userID, user != "demo",
              registeredFor != "\(user):\(token)" else { return }
        do {
            let bearer = try await account.validAccessToken()
            try await call(["action": "register", "token": token, "environment": Self.environment,
                            "name": UIDevice.current.name], bearer: bearer)
            registeredFor = "\(user):\(token)"
        } catch {
            // Next launch or sign-in tries again.
        }
    }

    /// `yui://agent/<id>/thread` (also `yui://agent/<id>`).
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard url.scheme == "yui", url.host() == "agent", let id = url.pathComponents.dropFirst().first,
              !id.isEmpty else { return false }
        pendingAgentID = id
        return true
    }

    private func call(_ body: [String: String], bearer: String) async throws {
        var req = URLRequest(url: YuiBackend.function("yui-push"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(YuiBackend.publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(body)
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AccountError.server("push_\((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
    }
}

extension PushCenter: UNUserNotificationCenterDelegate {
    // Completion-handler forms on purpose: with the async forms, UIKit's
    // handler runs off the main thread and asserts when the tap opens the app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        let agent = notification.request.content.userInfo["agent_id"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // Already looking at that thread: the message just appears in it.
                done(agent != nil && agent == PushCenter.shared.visibleAgentID ? [] : [.banner, .list, .sound])
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping @Sendable () -> Void) {
        let info = response.notification.request.content.userInfo
        let link = (info["url"] as? String).flatMap(URL.init(string:))
        let agent = info["agent_id"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let link, PushCenter.shared.open(link) {
                } else if let agent {
                    PushCenter.shared.pendingAgentID = agent
                }
                done()
            }
        }
    }
}

final class YuiAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Set before launch finishes so a tap that cold-starts the app is delivered.
        UNUserNotificationCenter.current().delegate = PushCenter.shared
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushCenter.shared.didRegister(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[yui] push registration failed: \(error.localizedDescription)")
    }
}
