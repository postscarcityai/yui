import Foundation
import YuiLines

// Agent controls (YUI-70, spec yuigui spec/CONTROLS.md): the drawer's Controls tab
// reads and changes what the agent is made of, straight on its host. A request is
// one `yui_messages` row with kind 'control'; the host's plugin answers with one
// row of its own (same `req`) within 5 seconds. No turn, no push, never in the thread.

/// What the host says it can do (`yui_agents.controls`): section -> "r", "rw" or "rwd".
struct AgentControls: Codable, Equatable, Hashable, Sendable {
    var v: Int
    var sections: [String: String]

    func can(_ s: ControlSection, _ mode: Character) -> Bool { sections[s.rawValue]?.contains(mode) ?? false }
    /// The areas to show, in the drawer's order.
    var shown: [ControlSection] { ControlSection.allCases.filter { sections[$0.rawValue] != nil } }
}

enum ControlSection: String, CaseIterable, Identifiable, Sendable {
    case soul, memory, skills, schedules, model, channels
    var id: String { rawValue }

    var title: String {
        switch self {
        case .soul: "Personality"
        case .memory: "Memory"
        case .skills: "Skills"
        case .schedules: "Schedules"
        case .model: "Model and tools"
        case .channels: "Channels"
        }
    }
    var icon: String {
        switch self {
        case .soul: "sparkles"
        case .memory: "brain.head.profile"
        case .skills: "wand.and.stars"
        case .schedules: "calendar.badge.clock"
        case .model: "cpu"
        case .channels: "bubble.left.and.bubble.right"
        }
    }
    func sub(_ name: String) -> String {
        switch self {
        case .soul: "Who \(name) is and how it talks"
        case .memory: "What it remembers, and about you"
        case .skills: "Switch on, off, edit"
        case .schedules: "Pause, resume, run now"
        case .model: "What it runs on"
        case .channels: "Where else it answers"
        }
    }
}

/// One row or item from the host. Every field is optional: each section fills its own.
struct ControlItem: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    var title: String?
    var sub: String?
    var group: String?
    var description: String?
    var text: String?
    var outline: [String]?
    var readOnly: Bool?
    var enabled: Bool?
    var bundled: Bool?
    var updated: String?
    var rev: String?
    // schedules
    var when: String?
    var schedule: String?
    var nextRun: String?
    var paused: Bool?
    var lastRun: String?
    var lastOk: Bool?
    var lastError: String?
    var deliver: String?
    var runningSoon: Bool?
    // model
    var model: String?
    var provider: String?
    var toolsets: [Toolset]?
    // channels
    var live: Bool?

    struct Toolset: Decodable, Equatable, Sendable, Identifiable {
        let name: String
        let on: Bool
        var id: String { name }
    }

    var locked: Bool { readOnly ?? false }

    enum CodingKeys: String, CodingKey {
        case id, title, sub, group, description, text, outline, enabled, bundled, updated, rev, when, schedule
        case paused, deliver, model, provider, toolsets, live
        case readOnly = "read_only", nextRun = "next_run", lastRun = "last_run", lastOk = "last_ok"
        case lastError = "last_error", runningSoon = "running_soon"
    }
}

/// The host's answer to one request.
struct ControlAnswer: Decodable, Sendable {
    let ok: Bool
    var req: String?
    var error: String?
    var message: String?
    var id: String?
    var rev: String?
    var items: [ControlItem]?
    var item: ControlItem?
    var deleted: Bool?
}

enum ControlsError: Error, Equatable {
    /// No answer in 5 seconds: "Your Mac didn't answer".
    case noAnswer
    /// The host speaks another protocol version.
    case version
    /// The host said no, in its own words.
    case refused(String, String)
    /// Changed on the host since it was opened: the current rev and item.
    case conflict(String, ControlItem?)

    var message: String {
        switch self {
        case .noAnswer: "Your Mac didn't answer."
        case .version: "Update the Yui plugin on your Mac."
        case .refused(_, let m): m
        case .conflict: "Changed on your Mac since you opened it."
        }
    }
}

protocol ControlsTransport: Sendable {
    func send(_ req: [String: YLValue]) async throws -> ControlAnswer
}

/// The relay: post the request row, then look for the answer with the same `req`.
struct RelayControls: ControlsTransport {
    let client: ThreadClient
    static let wait: TimeInterval = 5

    func send(_ req: [String: YLValue]) async throws -> ControlAnswer {
        let rid = req["req"]?.string ?? ""
        let what = [req["op"]?.string, req["section"]?.string, req["id"]?.string].compactMap { $0 }.joined(separator: " ")
        try await client.post(id: UUID().uuidString.lowercased(), body: "controls: \(what)", kind: "control", meta: .object(req))
        let end = Date.now.addingTimeInterval(Self.wait)
        while Date.now < end {
            try await Task.sleep(for: .milliseconds(350))
            if let a = try await client.controlAnswer(req: rid) { return a }
        }
        throw ControlsError.noAnswer
    }
}

/// One agent's controls, for the screens. Main actor: the screens read it.
@MainActor
final class ControlsModel {
    let transport: ControlsTransport
    let agentName: String
    let report: AgentControls

    init(transport: ControlsTransport, agentName: String, report: AgentControls) {
        self.transport = transport
        self.agentName = agentName
        self.report = report
    }

    private func call(_ op: String, _ section: ControlSection, id: String? = nil, _ extra: [String: YLValue] = [:]) async throws -> ControlAnswer {
        var req: [String: YLValue] = ["v": .number(1), "req": .string("c-" + UUID().uuidString.prefix(8).lowercased()),
                                      "op": .string(op), "section": .string(section.rawValue)]
        if let id { req["id"] = .string(id) }
        req.merge(extra) { $1 }
        let a = try await transport.send(req)
        if a.ok { return a }
        switch a.error {
        case "version": throw ControlsError.version
        case "conflict": throw ControlsError.conflict(a.rev ?? "", a.item)
        default: throw ControlsError.refused(a.error ?? "failed", a.message ?? "The host couldn't do that.")
        }
    }

    func list(_ s: ControlSection) async throws -> [ControlItem] { try await call("list", s).items ?? [] }

    func get(_ s: ControlSection, _ id: String) async throws -> (rev: String, item: ControlItem) {
        let a = try await call("get", s, id: id)
        guard let item = a.item else { throw ControlsError.refused("failed", "The host sent nothing back.") }
        return (a.rev ?? "", item)
    }

    /// Saves one item; the answer's id can differ (a memory entry's id follows its text).
    func put(_ s: ControlSection, _ id: String, rev: String, value: [String: YLValue]) async throws -> (rev: String, item: ControlItem) {
        let a = try await call("put", s, id: id, ["rev": .string(rev), "value": .object(value)])
        guard let item = a.item else { throw ControlsError.refused("failed", "The host sent nothing back.") }
        return (a.rev ?? "", item)
    }

    func act(_ s: ControlSection, _ id: String, _ verb: String) async throws -> ControlItem? {
        try await call("act", s, id: id, ["verb": .string(verb)]).item
    }

    func delete(_ s: ControlSection, _ id: String, rev: String) async throws {
        _ = try await call("delete", s, id: id, ["rev": .string(rev), "confirmed": .bool(true)])
    }

    // MARK: Drafts: an edit survives the app closing mid-edit.

    static func draftKey(_ agent: String, _ s: ControlSection, _ id: String) -> String { "yui.controls.draft.\(agent).\(s.rawValue).\(id)" }
    static func saveDraft(_ text: String?, key: String) { UserDefaults.standard.set(text, forKey: key) }
    static func draft(_ key: String) -> String? { UserDefaults.standard.string(forKey: key) }
}

// MARK: The demo account's host (screenshots and UI tests, no network)

/// A stand-in host with the plugin's rules: revs, conflicts, a hidden key, bundled skills.
actor DemoControls: ControlsTransport {
    private var soul = """
    # Scout

    You are Scout, a trail-running coach who lives in Yui.

    ## Voice
    - Warm, quick, a little playful.
    - Short sentences. The person is on a phone.

    ## What you do
    - Plan the week's runs around the person's schedule.
    - Check in after long runs.
    """
    private var memory: [(id: String, group: String, text: String, locked: Bool)] = [
        ("mem-1", "remembers", "Long runs are on Sunday mornings, 8:00 start.", false),
        ("mem-2", "remembers", "Knee felt tight after the 18 km on Sep 14. Keep the next two runs easy.", false),
        ("mem-3", "remembers", "Strava sync token: [hidden on your Mac]", true),
        ("user-1", "you", "Chris likes short answers and buttons over paragraphs.", false),
        ("user-2", "you", "Never schedule anything at 1:30 or 2:00pm (school pickup).", false),
    ]
    private var skills: [(id: String, desc: String, on: Bool, bundled: Bool, text: String)] = [
        ("trail-planner", "Plan a week of runs from the calendar.", true, false,
         "---\nname: trail-planner\ndescription: Plan a week of runs from the calendar.\n---\n\n# Trail planner\n\n1. Read the week.\n2. Put the long run on Sunday.\n3. Keep two easy days after a hard one.\n"),
        ("apple-reminders", "Apple Reminders: add, list, complete.", true, true,
         "---\nname: apple-reminders\ndescription: Apple Reminders: add, list, complete.\n---\n\n# Reminders\n\nUse remindctl.\n"),
        ("weather-check", "Look up the forecast before a long run.", false, false,
         "---\nname: weather-check\ndescription: Look up the forecast before a long run.\n---\n\n# Weather\n\nCheck the hourly forecast.\n"),
    ]
    private var jobs: [(id: String, name: String, when: String, prompt: String, paused: Bool)] = [
        ("j-morning", "morning brief", "weekdays 8:00", "Send the day's run and the weather as one card.", false),
        ("j-sunday", "sunday check-in", "Sundays 11:00", "Ask how the long run went. Offer a stretch timer.", false),
        ("j-weekly", "weekly plan", "Fridays 17:00", "Draft next week's runs and ask Chris to pick.", true),
    ]
    private var n = 0

    private func rev(_ s: String) -> String { String(format: "%08x", s.hashValue & 0xffffffff) }
    private func ok(_ extra: [String: Any]) -> ControlAnswer { decode(["ok": true].merging(extra) { $1 }) }
    private func no(_ error: String, _ message: String) -> ControlAnswer { decode(["ok": false, "error": error, "message": message]) }
    private func decode(_ d: [String: Any]) -> ControlAnswer {
        let data = try! JSONSerialization.data(withJSONObject: d)
        return try! JSONDecoder().decode(ControlAnswer.self, from: data)
    }

    func send(_ req: [String: YLValue]) async throws -> ControlAnswer {
        try await Task.sleep(for: .milliseconds(250))  // a real host takes a moment
        let op = req["op"]?.string ?? "", section = req["section"]?.string ?? "", id = req["id"]?.string ?? ""
        let text = req["value"]?.object?["text"]?.string
        switch (section, op) {
        case ("soul", "list"): return ok(["items": [["id": "SOUL.md", "title": "Scout"]]])
        case ("soul", "get"): return ok(["rev": rev(soul), "item": soulItem()])
        case ("soul", "put"):
            guard req["rev"]?.string == rev(soul) else { return conflict(rev(soul), soulItem()) }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return no("empty", "An agent needs a personality. It can't be empty.")
            }
            soul = text
            return ok(["rev": rev(soul), "item": soulItem()])
        case ("memory", "list"):
            return ok(["items": memory.reversed().map { ["id": $0.id, "group": $0.group, "title": $0.text, "read_only": $0.locked] }])
        case ("memory", "get"):
            guard let m = memory.first(where: { $0.id == id }) else { return no("not_found", "It's gone from the host.") }
            return ok(["rev": rev(m.text), "item": ["id": m.id, "group": m.group, "text": m.text, "read_only": m.locked]])
        case ("memory", "put"):
            guard let i = memory.firstIndex(where: { $0.id == id }) else { return no("not_found", "It's gone from the host.") }
            if memory[i].locked { return no("read_only", "Part of this is hidden on your Mac, so it can only be changed there.") }
            guard req["rev"]?.string == rev(memory[i].text) else { return conflict(rev(memory[i].text), ["id": id, "text": memory[i].text]) }
            memory[i].text = text ?? memory[i].text
            return ok(["rev": rev(memory[i].text), "item": ["id": id, "group": memory[i].group, "text": memory[i].text]])
        case ("memory", "delete"):
            memory.removeAll { $0.id == id }
            return ok(["deleted": true])
        case ("skills", "list"):
            return ok(["items": skills.map { ["id": $0.id, "title": $0.id, "description": $0.desc, "enabled": $0.on, "bundled": $0.bundled] }])
        case ("skills", "get"):
            guard let s = skills.first(where: { $0.id == id }) else { return no("bad_id", "That isn't something the host listed.") }
            return ok(["rev": rev(s.text), "item": ["id": s.id, "title": s.id, "text": s.text, "enabled": s.on, "bundled": s.bundled]])
        case ("skills", "put"):
            guard let i = skills.firstIndex(where: { $0.id == id }) else { return no("bad_id", "That isn't something the host listed.") }
            guard text?.hasPrefix("---") == true else { return no("no_frontmatter", "A skill needs its name and description at the top.") }
            skills[i].text = text!
            return ok(["rev": rev(skills[i].text), "item": ["id": id, "title": id, "text": skills[i].text, "enabled": skills[i].on]])
        case ("skills", "act"):
            guard let i = skills.firstIndex(where: { $0.id == id }) else { return no("bad_id", "That isn't something the host listed.") }
            skills[i].on = req["verb"]?.string == "enable"
            return ok(["item": ["id": id, "title": id, "enabled": skills[i].on, "bundled": skills[i].bundled]])
        case ("skills", "delete"):
            if skills.first(where: { $0.id == id })?.bundled == true {
                return no("bundled", "This skill ships with Hermes. Switch it off instead.")
            }
            skills.removeAll { $0.id == id }
            return ok(["deleted": true])
        case ("schedules", "list"): return ok(["items": jobs.map(jobItem)])
        case ("schedules", "get"):
            guard let j = jobs.first(where: { $0.id == id }) else { return no("bad_id", "That isn't something the host listed.") }
            return ok(["rev": rev(j.prompt + j.when), "item": jobItem(j)])
        case ("schedules", "act"):
            guard let i = jobs.firstIndex(where: { $0.id == id }) else { return no("bad_id", "That isn't something the host listed.") }
            let verb = req["verb"]?.string
            if verb == "pause" { jobs[i].paused = true }
            if verb == "resume" || verb == "run" { jobs[i].paused = false }
            var item = jobItem(jobs[i])
            if verb == "run" { item["running_soon"] = true }
            return ok(["item": item])
        case ("schedules", "put"):
            guard let i = jobs.firstIndex(where: { $0.id == id }) else { return no("bad_id", "That isn't something the host listed.") }
            if let text { jobs[i].prompt = text }
            if let s = req["value"]?.object?["schedule"]?.string { jobs[i].when = Self.words(s) }
            return ok(["rev": rev(jobs[i].prompt + jobs[i].when), "item": jobItem(jobs[i])])
        case ("schedules", "delete"):
            jobs.removeAll { $0.id == id }
            return ok(["deleted": true])
        case ("model", "list"): return ok(["items": [["id": "model", "title": "claude-opus-5-5", "sub": "Claude on this Mac"]]])
        case ("model", "get"):
            return ok(["item": ["id": "model", "model": "claude-opus-5-5", "provider": "Claude on this Mac",
                                "toolsets": [["name": "hermes-cli", "on": true], ["name": "kanban", "on": true],
                                             ["name": "browser", "on": false]]]])
        case ("channels", "list"):
            return ok(["items": [["id": "yui", "title": "Yui", "live": true], ["id": "telegram", "title": "Telegram", "live": true],
                                 ["id": "discord", "title": "Discord", "live": false]]])
        default:
            return no("bad_op", "The host doesn't know that request.")
        }
    }

    private func conflict(_ rev: String, _ item: [String: Any]) -> ControlAnswer {
        decode(["ok": false, "error": "conflict", "message": "Changed on the host since you opened it.", "rev": rev, "item": item])
    }
    private func soulItem() -> [String: Any] {
        ["id": "SOUL.md", "text": soul,
         "outline": soul.split(separator: "\n").filter { $0.hasPrefix("#") }.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }]
    }
    private func jobItem(_ j: (id: String, name: String, when: String, prompt: String, paused: Bool)) -> [String: Any] {
        var d: [String: Any] = ["id": j.id, "title": j.name, "when": j.when, "text": j.prompt, "paused": j.paused,
                                "deliver": "yui", "last_run": "2026-09-25T12:00:00Z", "last_ok": true]
        if !j.paused { d["next_run"] = ISO8601DateFormatter().string(from: .now.addingTimeInterval(3 * 3600)) }
        return d
    }
    /// The picker's lines in words, as the plugin's when_in_words says them.
    static func words(_ s: String) -> String {
        let p = s.split(separator: " ").map(String.init)
        if s.hasPrefix("every ") { return s.replacingOccurrences(of: "m", with: " minutes") }
        if p.count == 5, let mi = Int(p[0]), let h = Int(p[1]) {
            let t = "\(h):" + String(format: "%02d", mi)
            return p[4] == "1-5" ? "weekdays \(t)" : p[4] == "*" ? "daily \(t)" : s
        }
        return s
    }
}
