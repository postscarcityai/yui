import Foundation
import Security
import YuiLines

// What the widget and the App Intents say to Yui's relay (YUI-40 steps 3 and 4, spec WIDGETS.md
// sections 3 and 5). Compiled into the app and the widget extension. The widget never holds the
// person's session: it holds a widget token (yui-widgets register makes it) in the shared
// keychain, and the token can read the pinned agents' patch rows and send button events, nothing else.

enum WidgetBackend {
    static let url = URL(string: "https://txuibjxyfpalzvpneqgp.supabase.co")!
    /// The public client key: it only grants the anon role.
    static let publishableKey = "sb_publishable_9DhcBgazmSHaoOJChYtqwA_qyHvI_zc"
    static func function(_ name: String) -> URL { url.appending(path: "functions/v1/\(name)") }
}

// MARK: The widget token, in the shared keychain

enum WidgetSecrets {
    /// `$(AppIdentifierPrefix)com.yuigui.shared`, put in both Info.plists by project.yml.
    static var group: String? { Bundle.main.object(forInfoDictionaryKey: "YuiKeychainGroup") as? String }

    private static func query() -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "com.yuigui.widget",
                                kSecAttrAccount as String: "token"]
        if let group { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    static var token: String? {
        get {
            var q = query()
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
            return String(data: d, encoding: .utf8)
        }
        set {
            guard let newValue else { SecItemDelete(query() as CFDictionary); return }
            let attrs: [String: Any] = [kSecValueData as String: Data(newValue.utf8),
                                        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            if SecItemUpdate(query() as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
                SecItemAdd(query().merging(attrs) { $1 } as CFDictionary, nil)
            }
        }
    }

    // The WidgetKit push token (WidgetPushHandler runs in the extension): the app reads it on its next
    // foreground and registers it with the pins.
    static var pushToken: String? {
        get { WidgetGroup.defaults.string(forKey: "widgetPushToken") }
        set { WidgetGroup.defaults.set(newValue, forKey: "widgetPushToken") }
    }
}

// MARK: Events

/// One button on a widget, as the event row the agent receives.
struct WidgetEvent: Codable, Equatable, Sendable {
    var id: String
    var agentID: String
    var body: String
    var meta: YLValue
    var at: Date

    /// The same event a tap in the thread sends, plus `via: widget` (spec section 5).
    static func make(screen: WidgetScreen, part: WidgetPart, value: [String: YLValue], at: Date = .now) -> WidgetEvent {
        var value = value
        value["saved"] = .string(screen.name)
        value["via"] = .string("widget")
        let meta = YLValue.object(["id": .string(part.ylID), "preset": .string(part.preset), "value": .object(value)])
        return WidgetEvent(id: UUID().uuidString.lowercased(), agentID: screen.agentID,
                           body: line(id: part.ylID, preset: part.preset, value: value), meta: meta, at: at)
    }

    /// `[yui] <id> <preset> key=value ...` exactly as the app's `YLEvent.line` writes it (a unit test holds them together).
    static func line(id: String, preset: String, value: [String: YLValue]) -> String {
        var parts = ["[yui]", id, preset]
        func add(_ key: String, _ v: YLValue) {
            switch v {
            case .bool(true): parts.append(key)
            case .object(let o): for k in o.keys.sorted() { add("\(key).\(k)", o[k]!) }
            default: parts.append("\(key)=\(format(v))")
            }
        }
        for k in value.keys.sorted() { add(k, value[k]!) }
        return parts.joined(separator: " ")
    }

    private static func format(_ v: YLValue) -> String {
        switch v {
        case .string(let s): return quote(s)
        case .number(let n): return n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .array(let a): return a.map(format).joined(separator: "|")
        case .null: return "null"
        case .object: return quote(v.jsonText)
        }
    }

    private static func quote(_ s: String) -> String {
        let plain = !s.isEmpty && s.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\"|="))) == nil
        if plain { return s }
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}

private extension YLValue {
    var jsonText: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

// MARK: The offline queue

/// Events that have not reached the relay yet, in order, in the app group. A widget button writes here
/// first and tries the network once; whatever is left goes out at the next widget button or app launch.
enum WidgetQueue {
    private static var file: URL? { WidgetGroup.url?.appending(path: "yui-widget-queue.json") }
    private static var lockFile: URL? { WidgetGroup.url?.appending(path: "yui-widget-queue.lock") }

    /// A test or an offline check swaps this; the widget and the app use the shared session.
    nonisolated(unsafe) static var session: URLSession = .shared

    static func pending() -> [WidgetEvent] { locked { read() } ?? [] }

    static func add(_ e: WidgetEvent) {
        _ = locked {
            var all = read()
            guard !all.contains(where: { $0.id == e.id }) else { return }
            all.append(e)
            write(Array(all.suffix(200)))
        }
    }

    /// Oldest first. A refusal (the pin is gone, the row is bad) drops the event; the network being
    /// down or the token missing stops and keeps the rest in order. Returns how many went out.
    @discardableResult
    static func flush() async -> Int {
        var sent = 0
        while let e = pending().first {
            switch await WidgetRelay.send(e, session: session) {
            case .sent, .drop:
                _ = locked { write(read().filter { $0.id != e.id }) }
                sent += 1
            case .retry:
                return sent
            }
        }
        return sent
    }

    private static func read() -> [WidgetEvent] {
        guard let file, let data = try? Data(contentsOf: file) else { return [] }
        let dec = JSONDecoder()
        return (try? dec.decode([WidgetEvent].self, from: data)) ?? []
    }

    private static func write(_ all: [WidgetEvent]) {
        guard let file, let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// The app and the widget extension are two processes: one flock around every read and write.
    private static func locked<T>(_ body: () -> T) -> T? {
        guard let lockFile else { return nil }
        let fd = open(lockFile.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN); close(fd) }
        return body()
    }
}

// MARK: The relay calls

enum WidgetRelay {
    enum Outcome { case sent, drop, retry }

    struct Row: Decodable, Sendable {
        let id: String
        let body: String
        let created_at: String
    }

    static func send(_ e: WidgetEvent, session: URLSession = .shared) async -> Outcome {
        guard let token = WidgetSecrets.token else { return .retry }
        let body: [String: YLValue] = ["action": .string("event"), "agent_id": .string(e.agentID), "id": .string(e.id),
                                       "body": .string(e.body), "meta": e.meta]
        switch await call(body, token: token, session: session) {
        case (200, _): return .sent
        case (400, _), (404, _), (401, _), (403, _), (422, _): return .drop
        default: return .retry
        }
    }

    /// Patch and save rows newer than `since`, oldest first. Nil when the relay could not be asked.
    static func read(agentID: String, since: Date, session: URLSession = .shared) async -> [Row]? {
        guard let token = WidgetSecrets.token else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let body: [String: YLValue] = ["action": .string("read"), "agent_id": .string(agentID), "since": .string(iso.string(from: since))]
        let (status, data) = await call(body, token: token, session: session)
        struct Reply: Decodable { let rows: [Row] }
        guard status == 200, let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return nil }
        return reply.rows
    }

    /// The widget's own push token changed (a widget was added or removed): only rows that already exist take it.
    static func pushToken(_ token: String, environment: String, session: URLSession = .shared) async {
        guard let widget = WidgetSecrets.token else { return }
        _ = await call(["action": .string("push_token"), "push_token": .string(token), "environment": .string(environment)],
                       token: widget, session: session)
    }

    private static func call(_ body: [String: YLValue], token: String, session: URLSession) async -> (Int, Data) {
        var req = URLRequest(url: WidgetBackend.function("yui-widgets"), timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(WidgetBackend.publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONEncoder().encode(YLValue.object(body))
        guard let (data, response) = try? await session.data(for: req), let http = response as? HTTPURLResponse else { return (0, Data()) }
        return (http.statusCode, data)
    }
}

// MARK: Catching up after a push

/// The widget's timeline asks for the rows newer than its copy and applies them with the same parser the
/// app uses (spec section 3, step 4). A patch to a lasting id changes that part's props; a save of the same
/// name replaces the copy with what the reply put on that screen.
enum WidgetCatchUp {
    /// Lines inside the ```yui fences of a reply (an unclosed fence counts: the reply may be cut off).
    static func lines(in body: String) -> [String] {
        var out: [String] = []
        var inside = false
        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                inside = !inside && line.hasPrefix("```yui")
                continue
            }
            if inside, !line.isEmpty, !line.hasPrefix("#") { out.append(String(raw)) }
        }
        return out
    }

    /// `screen` with one reply's lines applied, or nil when nothing in it touched this screen.
    static func apply(body: String, at date: Date, to screen: WidgetScreen) -> WidgetScreen? {
        // A patch to an id that lasts needs to know what the id is (its preset), like the thread's parser does.
        let known = Dictionary(screen.parts.map { ($0.ylID, $0.preset) }) { a, _ in a }
        let nodes = YuiLines.parse(lines(in: body).joined(separator: "\n"), known: known)
        var s = screen
        var changed = false
        // What this reply has put on each page so far, for a `save` of this screen's name.
        var page: [String: [WidgetPart]] = [:]
        for n in nodes {
            switch n.op {
            case .add:
                guard let preset = n.preset else { continue }
                let id = n.id ?? "n\(page.values.reduce(0) { $0 + $1.count } + 1)"
                page[n.screen, default: []].append(WidgetPart(ylID: id, preset: preset, props: n.props ?? [:]))
            case .clear:
                page[n.screen] = []
            case .patch:
                guard let target = n.target else { continue }
                if let i = page[n.screen]?.lastIndex(where: { $0.ylID == target }) {
                    page[n.screen]?[i].props.merge(n.props ?? [:]) { $1 }
                }
                if date >= s.at, let i = s.parts.lastIndex(where: { $0.ylID == target }) {
                    s.parts[i].patch(n.props ?? [:])
                    changed = true
                }
            case .save where n.name == s.name:
                let parts = page[n.screen] ?? []
                guard !parts.isEmpty, date >= s.at else { continue }
                // The phone's own ticks and a running timer belong to the phone: a new save starts fresh.
                s.parts = parts
                changed = true
            default:
                continue
            }
        }
        guard changed else { return nil }
        s.at = max(s.at, date)
        return s
    }

    /// Asks the relay what is new for this screen's agent, applies it, saves the copy. The saved copy is
    /// returned (the widget draws it); with no network it is the copy as it was.
    static func refresh(_ screen: WidgetScreen, session: URLSession = .shared) async -> WidgetScreen {
        guard let rows = await WidgetRelay.read(agentID: screen.agentID, since: screen.at, session: session), !rows.isEmpty else { return screen }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var s = screen
        for r in rows {
            let date = iso.date(from: r.created_at) ?? .now
            if let next = apply(body: r.body, at: date, to: s) { s = next }
        }
        guard s != screen else { return screen }
        WidgetStore.update { snap in
            // Keep what the phone changed meanwhile (a tick, a running timer): only the parts this catch-up changed move.
            if let i = snap.screens.firstIndex(where: { $0.id == s.id }) {
                var merged = s
                merged.parts = s.parts.map { p in
                    guard let old = snap.screens[i].parts.first(where: { $0.ylID == p.ylID }) else { return p }
                    var q = p
                    q.ticked = old.ticked.filter { p.list("items").contains($0) }
                    q.liveKey = old.liveKey
                    q.endsAt = old.endsAt
                    return q
                }
                snap.screens[i] = merged
                s = merged
            }
        }
        return s
    }
}

extension WidgetPart {
    /// A patch's props merged in; `kind=` on a timeline row re-kinds it (YUI-111).
    mutating func patch(_ new: [String: YLValue]) {
        var new = new
        if let kind = rowKind(of: preset, patch: new) { preset = kind; new["kind"] = nil }
        props.merge(new) { $1 }
    }
}

// MARK: The reload budget log (spec section 10: a budget log in the Speed panel)

enum WidgetBudget {
    /// One line per timeline the widget was asked for: day -> screen -> count, kept for two weeks.
    static func log(screen: String) {
        let day = dayKey(.now)
        var all = WidgetGroup.defaults.dictionary(forKey: "widgetReloads") as? [String: [String: Int]] ?? [:]
        all[day, default: [:]][screen, default: 0] += 1
        for old in all.keys.sorted().dropLast(14) { all[old] = nil }
        WidgetGroup.defaults.set(all, forKey: "widgetReloads")
    }

    static func today() -> [String: Int] {
        let all = WidgetGroup.defaults.dictionary(forKey: "widgetReloads") as? [String: [String: Int]] ?? [:]
        return all[dayKey(.now)] ?? [:]
    }

    static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
