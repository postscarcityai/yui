import Foundation
import UserNotifications
import YuiLines

/// Reminders an agent keeps (YUI-185, Penny): a reply that changes them carries the whole
/// set in `meta.native.reminders` as `[{key, text, at}]`, `at` in the person's local time
/// ("2026-09-29T08:50"). The phone turns them into local notifications, so Penny's
/// "Call the dentist, 9:00 am" goes off at 8:50 with no server and no network.
///
/// Each set replaces the last one for that agent: every pending reminder of the agent is
/// taken off and the new ones go on, an empty set clears them. The set is kept in
/// UserDefaults per agent with the time of the reply it came in, so an older reply read
/// on a thread's open never undoes a newer one, and a relaunch knows what is scheduled.
/// Permission is asked once, the first time a live reply carries a reminder, never at launch.
@MainActor
final class Reminders {
    static let shared = Reminders()

    struct Item: Equatable, Sendable {
        let key: String
        let text: String
        /// Local wall-clock time, "yyyy-MM-ddTHH:mm".
        let at: String
    }

    /// Where notifications go. The real one is UNUserNotificationCenter; tests use a fake.
    @MainActor protocol Center: AnyObject {
        func status() async -> UNAuthorizationStatus
        func ask() async -> Bool
        func pending() async -> [String]
        func remove(_ ids: [String])
        func add(_ request: UNNotificationRequest) async
    }

    private let defaults: UserDefaults
    private let center: Center
    /// Waits in line: a newer set never lands before an older one is done.
    private var last: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, center: Center = SystemCenter()) {
        self.defaults = defaults
        self.center = center
        Self.resetIfAsked(defaults)
    }

    /// The set in an agent row's meta, or nil when the row says nothing about reminders.
    nonisolated static func items(meta: YLValue?) -> [Item]? {
        guard let list = meta?.object?["native"]?.object?["reminders"]?.array else { return nil }
        return list.compactMap { v in
            guard let o = v.object, let key = o["key"]?.string, !key.isEmpty, let at = o["at"]?.string,
                  date(at) != nil else { return nil }
            return Item(key: key, text: o["text"]?.string ?? "", at: at)
        }
    }

    /// "2026-09-29T08:50" as a moment in `zone` (the phone's own, the one the runtime was told).
    nonisolated static func date(_ at: String, zone: TimeZone = .current) -> Date? {
        comps(at).flatMap { c in
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = zone
            return cal.date(from: c)
        }
    }

    nonisolated static func comps(_ at: String) -> DateComponents? {
        let parts = at.split(whereSeparator: { "-T:".contains($0) }).compactMap { Int($0) }
        guard parts.count >= 5, (1...12).contains(parts[1]), (1...31).contains(parts[2]),
              (0...23).contains(parts[3]), (0...59).contains(parts[4]) else { return nil }
        return DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4])
    }

    nonisolated static func prefix(_ agent: String) -> String { "yui.reminder.\(agent)." }
    nonisolated static func key(_ agent: String) -> String { "yui.reminders.\(agent)" }
    nonisolated static let askedKey = "yui.reminders.asked"

    /// What the phone holds for an agent: the last set it took, oldest first.
    func saved(_ agent: String) -> [Item] {
        (defaults.array(forKey: Self.key(agent)) as? [[String: String]] ?? []).compactMap { d in
            guard let key = d["key"], let at = d["at"] else { return nil }
            return Item(key: key, text: d["text"] ?? "", at: at)
        }
    }

    /// An agent row arrived. `live`: it came in while the thread was open (not history on open),
    /// so it may ask for permission. Returns false when the row was older than the set kept.
    @discardableResult
    func take(meta: YLValue?, agent: String, name: String, createdAt: String, live: Bool, now: Date = .now) -> Bool {
        guard !agent.isEmpty, let items = Self.items(meta: meta) else { return false }
        let when = YuiTime.date(createdAt) ?? now
        if let had = defaults.object(forKey: Self.key(agent) + ".at") as? Date, had > when { return false }
        defaults.set(items.map { ["key": $0.key, "text": $0.text, "at": $0.at] }, forKey: Self.key(agent))
        defaults.set(when, forKey: Self.key(agent) + ".at")
        let ask = live && !items.isEmpty && !defaults.bool(forKey: Self.askedKey)
        if ask { defaults.set(true, forKey: Self.askedKey) }
        let before = last
        last = Task { [center] in
            await before?.value
            await Self.schedule(items, agent: agent, name: name, ask: ask, center: center, now: now)
        }
        return true
    }

    /// Waits for the scheduling in flight (tests).
    func settle() async { await last?.value }

    private static func schedule(_ items: [Item], agent: String, name: String, ask: Bool, center: Center, now: Date) async {
        let prefix = prefix(agent)
        let old = await center.pending().filter { $0.hasPrefix(prefix) }
        if !old.isEmpty { center.remove(old) }
        let future = items.filter { (date($0.at) ?? .distantPast) > now }
        guard !future.isEmpty else { log(agent, asked: false, ids: []); return }
        var status = await center.status()
        if status == .notDetermined, ask {
            _ = await center.ask()
            status = await center.status()
        }
        guard status == .authorized || status == .provisional || status == .ephemeral else {
            log(agent, asked: ask, ids: [])
            return
        }
        defer { log(agent, asked: ask, ids: future.map { prefix + $0.key }) }
        for item in future {
            guard let c = comps(item.at) else { continue }
            let content = UNMutableNotificationContent()
            content.title = name
            content.body = item.text
            content.sound = .default
            // A tap opens the agent's thread (PushCenter reads agent_id).
            content.userInfo = ["agent_id": agent, "reminder": item.key]
            content.threadIdentifier = "yui.reminders.\(agent)"
            let trigger = UNCalendarNotificationTrigger(dateMatching: c, repeats: false)
            await center.add(UNNotificationRequest(identifier: prefix + item.key, content: content, trigger: trigger))
        }
    }

    /// `-yuiRemindersLog <path>` (UI tests): a line per set, what went on the clock and whether it asked.
    private static func log(_ agent: String, asked: Bool, ids: [String]) {
        #if DEBUG
        guard let path = UserDefaults.standard.string(forKey: "yuiRemindersLog") else { return }
        let line = (try? JSONSerialization.data(withJSONObject: ["agent": agent, "asked": asked, "scheduled": ids], options: .sortedKeys))
            .map { String(decoding: $0, as: UTF8.self) + "\n" } ?? ""
        if let out = FileHandle(forWritingAtPath: path) {
            out.seekToEndOfFile()
            out.write(Data(line.utf8))
            try? out.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
        #endif
    }

    /// `-yuiRemindersReset` (UI tests): nothing kept and nothing asked, once per launch.
    private static func resetIfAsked(_ d: UserDefaults) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-yuiRemindersReset") else { return }
        for k in d.dictionaryRepresentation().keys where k.hasPrefix("yui.reminders.") { d.removeObject(forKey: k) }
        #endif
    }

    @MainActor final class SystemCenter: Center {
        private var c: UNUserNotificationCenter { .current() }
        func status() async -> UNAuthorizationStatus { await c.notificationSettings().authorizationStatus }
        func ask() async -> Bool { (try? await c.requestAuthorization(options: [.alert, .sound, .badge])) ?? false }
        func pending() async -> [String] { await c.pendingNotificationRequests().map(\.identifier) }
        func remove(_ ids: [String]) { c.removePendingNotificationRequests(withIdentifiers: ids) }
        func add(_ request: UNNotificationRequest) async { try? await c.add(request) }
    }
}
