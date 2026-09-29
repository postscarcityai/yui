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
///
/// Presence (YUI-24): while the app is open it tells `yui-push` which thread
/// is on screen, once a minute and on every change, and clears it on the way
/// to the background. The server then skips this phone for answers in that
/// thread, so an answer you are watching arrive never buzzes too. A killed
/// app stops reporting and counts as closed after 90 seconds.
@MainActor @Observable
final class PushCenter: NSObject {
    static let shared = PushCenter()

    /// A thread to open, from a notification tap or a link. ChatView consumes it.
    var pendingAgentID: String?
    /// The chat a notification came from (YUI-169, the payload's `chat`): opened with the agent's thread.
    var pendingChatID: String?
    /// The message a notification is about (the payload's `message_id`, YUI-199): the thread opens on it, not on the home.
    var pendingMessageID: String?
    /// Settings to open from a link (`yui://settings/search`, YUI-142): the section, "" for the top. ChatView consumes it.
    var pendingSettings: String?
    /// `yui://snap` (YUI-166): hold to snap and say, in the thread on screen. ChatView consumes it.
    var pendingSnap = false
    /// Bumped by a silent push that says the agent list changed (a revoke, YUI-97).
    private(set) var listChanged = 0

    /// A silent push: `kind` says what changed. Nothing is shown.
    func silent(_ info: [AnyHashable: Any]) {
        if info["kind"] as? String == "revoked" { listChanged += 1 }
    }
    /// The thread on screen right now: its own pushes don't show a banner.
    var visibleAgentID: String? {
        didSet { if visibleAgentID != oldValue, foreground { Task { await reportPresence() } } }
    }
    /// The app is on screen (scene phase active).
    private(set) var foreground = false
    private var heartbeat: Task<Void, Never>?
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
                            "name": UIDevice.current.name, "build": Self.build], bearer: bearer)
            registeredFor = "\(user):\(token)"
            if foreground { await reportPresence() }
        } catch {
            // Next launch or sign-in tries again.
        }
    }

    /// Scene phase: open (with a heartbeat) or on the way to the background.
    func setForeground(_ on: Bool) {
        guard on != foreground else { return }
        foreground = on
        heartbeat?.cancel()
        if on {
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.reportPresence()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
        } else {
            // A few seconds of background time so "closed" reaches the server.
            let app = UIApplication.shared
            var bg = UIBackgroundTaskIdentifier.invalid
            bg = app.beginBackgroundTask { app.endBackgroundTask(bg) }
            Task {
                await reportPresence()
                app.endBackgroundTask(bg)
            }
        }
    }

    private func reportPresence() async {
        guard let token = deviceToken, registeredFor != nil, let account, account.isSignedIn,
              let bearer = try? await account.validAccessToken() else { return }
        var body: [String: Any] = ["action": "presence", "token": token, "active": foreground, "build": Self.build]
        if foreground, let agent = visibleAgentID { body["agent_id"] = agent }
        _ = try? await call(body, bearer: bearer)
    }

    /// This app's build ("112", a test build "112.1"): hosts send only the presets it can draw.
    static let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""

    /// `yui://agent/<id>/thread` (also `yui://agent/<id>` or `yui://agent/<handle>`), and `yui://settings[/<section>]`.
    @discardableResult
    func open(_ url: URL) -> Bool {
        if let section = Self.settingsSection(url) {
            pendingSettings = section
            return true
        }
        if Self.isSnap(url) {
            pendingSnap = true
            return true
        }
        guard let id = Self.agentTarget(url) else { return false }
        pendingAgentID = id
        return true
    }

    /// `yui://agent/<id or handle>[/thread]`: the agent to open. A hand-off card (YUI-144)
    /// names it by handle (`yui://agent/basil`); ChatView matches either. `/thread` only opens
    /// it (Yui's crew page, YUI-168) and never jumps on arrival: see `isHandOff`.
    nonisolated static func agentTarget(_ url: URL) -> String? {
        guard url.scheme == "yui", url.host() == "agent", let id = url.pathComponents.dropFirst().first,
              !id.isEmpty else { return nil }
        return id
    }

    /// A hand-off link jumps the phone when its card lands live; `yui://agent/<id>/thread` does not.
    nonisolated static func isHandOff(_ url: URL) -> Bool {
        agentTarget(url) != nil && url.pathComponents.dropFirst(2).first != "thread"
    }

    /// `yui://snap`: the camera that hears you (a shortcut like "Log a meal").
    nonisolated static func isSnap(_ url: URL) -> Bool { url.scheme == "yui" && url.host() == "snap" }

    /// `yui://settings` is "", `yui://settings/search` is "search"; anything else is nil.
    nonisolated static func settingsSection(_ url: URL) -> String? {
        guard url.scheme == "yui", url.host() == "settings" else { return nil }
        let section = url.pathComponents.dropFirst().first ?? ""
        return SettingsView.sections.contains(section) ? section : ""
    }

    private func call(_ body: [String: Any], bearer: String) async throws {
        var req = URLRequest(url: YuiBackend.function("yui-push"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(YuiBackend.publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
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
        // Only the words cross to the main thread: the payload dictionary itself is not Sendable.
        let info = response.notification.request.content.userInfo
        let words = ["url", "agent_id", "chat", "message_id"].reduce(into: [String: String]()) { $0[$1] = info[$1] as? String }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                PushCenter.shared.tapped(words)
                done()
            }
        }
    }
}

extension PushCenter {
    /// A tap on a notification (YUI-199): its agent's thread opens on the message that came,
    /// from a cold start and from the background alike. The payload names the agent
    /// (`agent_id`, or the `yui://agent/<id>/thread` link), the chat and the message.
    func tapped(_ info: [AnyHashable: Any]) {
        let link = (info["url"] as? String).flatMap(URL.init(string:))
        let chat = (info["chat"] as? String)?.lowercased()
        let message = info["message_id"] as? String
        // Before the agent, so the thread that opens is that chat and lands on that message.
        if chat != nil { pendingChatID = chat }
        if message != nil { pendingMessageID = message }
        if let link, open(link) {
        } else if let agent = info["agent_id"] as? String {
            pendingAgentID = agent
        }
    }
}

final class YuiAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Set before launch finishes so a tap that cold-starts the app is delivered.
        UNUserNotificationCenter.current().delegate = PushCenter.shared
        // Speed reporting (YUI-102): MetricKit, memory samples, the batches.
        PerfMonitor.shared.start()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushCenter.shared.didRegister(deviceToken)
    }

    /// Silent pushes (`content-available`, no alert): a revoked grant (YUI-97).
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler done: @escaping (UIBackgroundFetchResult) -> Void) {
        PushCenter.shared.silent(userInfo)
        done(.newData)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[yui] push registration failed: \(error.localizedDescription)")
    }
}
