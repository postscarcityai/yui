import Foundation
import Observation
import SwiftUI
import YuiLines

struct ChatMessage: Identifiable, Equatable {
    var id = UUID().uuidString
    var text: String
    var fromUser: Bool
    /// An agent reply in Yui Lines, drawn as presets instead of a bubble.
    var yl: YLScreen?
}

/// The chat's messages plus the event log going back to the agent.
/// Attached to an agent, it is that agent's thread (yui_messages, spec
/// yuigui/spec/RELAY.md); detached, it is the local demo chat.
@Observable @MainActor
final class ChatStore {
    var messages: [ChatMessage]
    private(set) var events: [YLEvent] = []
    var spring: Animation = .default
    /// An agent reply carried a `theme` line: (agent id, props, message time).
    var onLook: (@MainActor (String, [String: String], String) -> Void)?

    /// The agent this thread talks to, when there is one.
    private(set) var agent: YuiAgent?
    /// The agent owes a reply: shows the typing dots.
    private(set) var waiting = false
    private(set) var loaded = false
    var error: String?
    private var client: ThreadClient?
    private var poll: Task<Void, Never>?
    private var cursor: String?
    private var seen = Set<String>()
    private var waitingSince: Date?

    init(messages: [ChatMessage] = []) { self.messages = messages }

    var emit: YLEmit { YLEmit { [weak self] e in self?.receive(e) } }

    func receive(_ e: YLEvent) {
        events.insert(e, at: 0)
        if let echo = e.echo {
            withAnimation(spring) { messages.append(ChatMessage(text: echo, fromUser: true)) }
        }
        guard client != nil, e.relays else { return }
        post(body: e.line, kind: "event", meta: e.meta)
    }

    // MARK: Thread

    /// Same agent, new fields (a rename, a new look): swap it in, keep the thread.
    func refreshAgent(_ fresh: YuiAgent?) {
        guard let fresh, fresh.id == agent?.id, fresh != agent else { return }
        agent = fresh
    }

    /// The demo account: show `agent`'s face on the local demo chat, no thread.
    func demo(_ agent: YuiAgent?) {
        poll?.cancel()
        client = nil
        self.agent = agent
        loaded = true
    }

    /// Switches to `agent`'s thread and keeps it fresh. nil detaches.
    func attach(_ agent: YuiAgent?, account: Account) {
        guard agent?.id != self.agent?.id || client == nil && agent != nil else { return }
        poll?.cancel()
        self.agent = agent
        client = agent.map { ThreadClient(account: account, agentID: $0.id) }
        messages = []
        seen = []
        cursor = nil
        waiting = false
        loaded = false
        error = nil
        guard client != nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    func send(_ text: String) {
        let m = ChatMessage(text: text, fromUser: true)
        withAnimation(spring) { messages.append(m) }
        post(id: m.id, body: text, kind: "text", meta: nil)
    }

    private func post(id: String = UUID().uuidString, body: String, kind: String, meta: YLValue?) {
        guard let client else { return }
        seen.insert(id.lowercased())
        waiting = true
        waitingSince = .now
        Task {
            do {
                try await client.post(id: id, body: body, kind: kind, meta: meta)
                error = nil
            } catch {
                waiting = false
                self.error = "Couldn't send that. Check your connection and try again."
            }
        }
    }

    func refresh() async {
        guard let client, let agentID = agent?.id else { return }
        do {
            let rows = try await client.fetch(since: cursor)
            guard agent?.id == agentID else { return }
            for row in rows { add(row) }
            if let last = rows.last { cursor = last.createdAt }
            loaded = true
            if let since = waitingSince, Date.now.timeIntervalSince(since) > 180 { waiting = false }
        } catch {
            loaded = true
        }
    }

    private func add(_ row: ThreadRow) {
        let id = row.id.lowercased()
        if row.sender == "agent" { waiting = false }
        guard seen.insert(id).inserted else { return }
        var new: [ChatMessage] = []
        if row.sender == "user" {
            if row.kind == "event" {
                if let echo = row.meta?.object?["echo"]?.string { new.append(ChatMessage(id: id, text: echo, fromUser: true)) }
            } else {
                new.append(ChatMessage(id: id, text: row.body, fromUser: true))
            }
        } else {
            for (i, seg) in YuiFence.split(row.body).enumerated() {
                switch seg {
                case .text(let t): new.append(ChatMessage(id: "\(id)#\(i)", text: t, fromUser: false))
                case .yl(let y):
                    let screen = YLScreen(y)
                    if let agentID = agent?.id { for look in screen.looks { onLook?(agentID, look, row.createdAt) } }
                    new.append(ChatMessage(id: "\(id)#\(i)", text: "", fromUser: false, yl: screen))
                }
            }
        }
        guard !new.isEmpty else { return }
        withAnimation(loaded ? spring : nil) { messages.append(contentsOf: new) }
    }

    /// Adds an agent reply and feeds it through the stream parser a line at a
    /// time, the way a model's tokens will arrive, so each preset lands on its own.
    func stream(_ text: String, lineDelay: Duration = .milliseconds(220)) {
        let msg = ChatMessage(text: "", fromUser: false, yl: YLScreen())
        withAnimation(spring) { messages.append(msg) }
        Task {
            var parser = YLStreamParser()
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                apply(parser.push(line + "\n"), to: msg.id)
                try? await Task.sleep(for: lineDelay)
            }
            apply(parser.flush(), to: msg.id)
        }
    }

    private func apply(_ nodes: [YLNode], to id: String) {
        guard !nodes.isEmpty, let i = messages.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(spring) {
            for n in nodes { messages[i].yl?.apply(n) }
        }
        // Demo streams restyle live too, stamped now.
        for n in nodes where n.op == .theme {
            guard let agentID = agent?.id else { continue }
            onLook?(agentID, (n.props ?? [:]).compactMapValues { v in v.string ?? v.number.map(YLComponent.format) },
                    Date.now.formatted(.iso8601))
        }
    }
}

/// Canned replies for the paste box and screenshot launch args (`-yuiYL <name>`).
enum YLSamples {
    static let all: [(name: String, text: String)] = [
        ("tabata", """
        say Tabata time. Eight rounds, 20 on and 10 off.
        timer@hiit 20/10x8 Tabata +auto
        ask "Log it when you're done?"
        """),
        ("checkin", """
        form "Daily check-in" mood:1-5 sleep_hours:number! "Trained today":yes split:Push|Pull|Legs notes:voice submit="Log it"
        """),
        ("choose", """
        choose "Which split today?" Push|Pull|Legs +other
        ask "Send the invite now?" "Yes, send"|"Not yet"
        """),
        ("gear", """
        pick "What gear do you have?" Dumbbells|Bench|Bands|"Pull-up bar"|Kettlebell +other max=3
        """),
        ("today", """
        list Today "Squat 5x5 @ 225" "Bench 5x5 @ 185" "Row 3x10" +check
        list Warmup "Jumping jacks"|"Hip openers"|"Band pull-aparts" +num
        """),
        ("tour", """
        say Here's everything I can draw so far.
        ask "Ready?"
        choose "Pick a vibe" Calm|Focused|Chaotic +other
        pick "Snacks" Tteokbokki|Kimbap|Hotteok|Bingsu
        form "Quick one" name! "Favorite number":1-10
        list Plan "Stretch" "Lift" "Nap" +check
        timer 5m Plank hold
        slide "Energy" 1-5
        """),
    ]

    static func text(_ name: String) -> String? { all.first { $0.name == name }?.text }
}
