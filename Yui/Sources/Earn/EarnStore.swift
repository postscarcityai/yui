import Foundation
import Observation

/// What `yui_my_u()` returns for the signed-in person: their own $U and nothing else (OSS-7).
struct EarnSummary: Equatable {
    struct Day: Equatable, Identifiable {
        let day: String
        let messages, screens, jobs, earned: Int
        var id: String { day }
    }
    /// A shipped feedback, an accepted issue or a merged pull request, in plain words.
    struct Built: Equatable, Identifiable {
        let day: String
        let words: String
        var id: String { day + words }
    }
    var total = 0
    var today = 0
    var softCap = 150
    var streak = 0
    var mult = 1.0
    var days: [Day] = []
    var built: [Built] = []

    init() {}

    init?(json: Data, built rows: Data? = nil) {
        guard let o = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        total = o["total"] as? Int ?? 0
        today = o["today"] as? Int ?? 0
        softCap = o["soft_cap"] as? Int ?? 150
        streak = o["streak"] as? Int ?? 0
        mult = (o["mult"] as? NSNumber)?.doubleValue ?? 1
        days = (o["history"] as? [[String: Any]] ?? []).compactMap { h in
            guard let d = h["day"] as? String else { return nil }
            return Day(day: d, messages: h["messages"] as? Int ?? 0, screens: h["screens"] as? Int ?? 0,
                       jobs: h["jobs"] as? Int ?? 0, earned: h["earned"] as? Int ?? 0)
        }
        if let rows, let list = try? JSONSerialization.jsonObject(with: rows) as? [[String: Any]] {
            built = list.compactMap { r in
                guard let d = r["day"] as? String, let k = r["kind"] as? String, let w = Self.words(k) else { return nil }
                return Built(day: d, words: w)
            }
        }
    }

    static func words(_ kind: String) -> String? {
        switch kind {
        case "feedback_shipped": "Your feedback shipped"
        case "issue_accepted": "Your idea was accepted"
        case "issue_shipped": "Your idea shipped"
        case "pr_merged": "Your code was added"
        default: nil
        }
    }

    /// "Sep 29" from "2026-09-29".
    static func shortDay(_ day: String) -> String {
        guard let d = try? Date(day + "T12:00:00Z", strategy: .iso8601) else { return day }
        return d.formatted(.dateTime.month(.abbreviated).day().locale(Locale(identifier: "en_US")))
    }

    /// What the demo account shows: no network, a stable story.
    static let demo: EarnSummary = {
        var s = EarnSummary()
        s.total = 1284; s.today = 82; s.streak = 6; s.mult = 1.1
        s.days = [Day(day: "2026-09-30", messages: 34, screens: 9, jobs: 4, earned: 82),
                  Day(day: "2026-09-29", messages: 21, screens: 6, jobs: 2, earned: 61),
                  Day(day: "2026-09-28", messages: 12, screens: 3, jobs: 0, earned: 38)]
        s.built = [Built(day: "2026-09-27", words: "Your feedback shipped")]
        return s
    }()
}

/// The $U in the left drawer (YUI-210). The total shows only there, never on the chat. Opening the
/// drawer after it grew counts the number up once from what the person last saw; only the new $U
/// animates, so nothing counts twice. No coins fly, no push, no sound.
@MainActor @Observable
final class EarnStore {
    private(set) var summary = EarnSummary()
    /// The number on screen, which climbs while it counts.
    private(set) var shown = 0
    /// True while it climbs: the pill fades to green and back.
    private(set) var climbing = false
    private var animation: Task<Void, Never>?

    private static func seenKey(_ user: String) -> String { "yuiUSeen.\(user)" }

    /// Reads the summary. `animate`: count up from the last seen total (the drawer was just opened).
    func refresh(_ account: Account, animate: Bool, reduceMotion: Bool) async {
        guard let user = account.session?.userID else { return }
        let next: EarnSummary
        if user == "demo" {
            next = .demo
        } else {
            guard let fetched = await Self.fetch(account) else { return }
            next = fetched
        }
        summary = next
        let defaults = UserDefaults.standard
        let key = Self.seenKey(user)
        let args = ProcessInfo.processInfo.arguments
        // -yuiEarnSeen <n>: the total the person last saw (UI tests).
        let seen = (args.contains("-yuiEarnSeen") ? defaults.string(forKey: "yuiEarnSeen").flatMap(Int.init) : nil)
            ?? defaults.object(forKey: key) as? Int
        defaults.set(next.total, forKey: key)
        if animate, let seen, seen < next.total {
            count(from: seen, to: next.total, reduceMotion: reduceMotion)
        } else {
            // Nothing new since the person last looked, or a move while the drawer is open: the number just changes.
            animation?.cancel(); climbing = false
            shown = next.total
        }
    }

    private func count(from: Int, to: Int, reduceMotion: Bool) {
        animation?.cancel()
        shown = from
        if reduceMotion { shown = to; return }
        animation = Task { [weak self] in
            // The drawer takes about half a second to settle; the count starts once it is in.
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self else { return }
            climbing = true
            let ms = min(1600.0, 500 + log10(Double(to - from) + 1) * 350)
            let t0 = Date()
            while !Task.isCancelled {
                let k = min(1, Date().timeIntervalSince(t0) * 1000 / ms)
                shown = from + Int(Double(to - from) * (1 - pow(1 - k, 3)))
                if k >= 1 { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
            if !Task.isCancelled { shown = to; climbing = false }
        }
    }

    private static func fetch(_ account: Account) async -> EarnSummary? {
        var rpc = URLRequest(url: YuiBackend.url.appending(path: "rest/v1/rpc/yui_my_u"))
        rpc.httpMethod = "POST"
        rpc.setValue("application/json", forHTTPHeaderField: "Content-Type")
        rpc.httpBody = Data(#"{"p_days":30}"#.utf8)
        guard let json = try? await YuiRelay.data(account, rpc) else { return nil }
        var c = URLComponents(url: YuiBackend.url.appending(path: "rest/v1/yui_ledger"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "select", value: "kind,day"),
                        URLQueryItem(name: "kind", value: "in.(feedback_shipped,issue_accepted,issue_shipped,pr_merged)"),
                        URLQueryItem(name: "order", value: "day.desc"),
                        URLQueryItem(name: "limit", value: "20")]
        let rows = try? await YuiRelay.data(account, URLRequest(url: c.url!))
        return EarnSummary(json: json, built: rows)
    }
}
