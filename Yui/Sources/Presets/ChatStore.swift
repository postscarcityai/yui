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

    // MARK: Stage (YUI-13, spec YL.md section 5)

    /// The open agent's style profile: decides what opens on the stage.
    var style: [String: String] = [:]
    /// The reply on the stage, and whether the stage is up or swiped away.
    private(set) var stageID: String?
    private(set) var stageOpen = false
    /// Timer clocks for the whole thread, shared by the stage and the pills.
    let timers = TimerRuns()

    var stageMessage: ChatMessage? { stageID.flatMap { id in messages.first { $0.id == id } } }

    func openStage(_ id: String) {
        withAnimation(spring) {
            stageID = id
            stageOpen = true
        }
    }

    func closeStage() {
        withAnimation(spring) { stageOpen = false }
    }

    /// A reply grew (a streamed line, a new row): open the stage for new staged
    /// components, close it when the agent said `close`.
    private func stageUpdate(_ id: String, before: YLScreen?) {
        guard let yl = messages.first(where: { $0.id == id })?.yl else { return }
        let wanted = yl.wantsStage(style)
        if wanted, yl.staged(style).count > (before?.staged(style).count ?? 0) {
            openStage(id)
        } else if !wanted, yl.closedAt > (before?.closedAt ?? 0), stageID == id {
            closeStage()
        }
    }

    /// The agent this thread talks to, when there is one.
    private(set) var agent: YuiAgent?
    /// The agent owes a reply: shows the typing dots.
    private(set) var waiting = false
    private(set) var loaded = false
    var error: String?
    private var client: ThreadClient?
    private weak var account: Account?
    private var poll: Task<Void, Never>?
    private var cursor: String?
    private var seen = Set<String>()
    /// When the reply started being owed: a long wait shows a fix-it hint.
    private(set) var waitingSince: Date?

    init(messages: [ChatMessage] = []) { self.messages = messages }

    var emit: YLEmit { YLEmit { [weak self] e in self?.receive(e) } }

    func receive(_ e: YLEvent) {
        events.insert(e, at: 0)
        #if DEBUG
        // `-yuiEventLog <path>`: UI tests read back the events a tap sent.
        if let path = UserDefaults.standard.string(forKey: "yuiEventLog"),
           let out = FileHandle(forWritingAtPath: path) ?? {
               FileManager.default.createFile(atPath: path, contents: nil)
               return FileHandle(forWritingAtPath: path)
           }() {
            out.seekToEndOfFile()
            out.write(Data((e.json + "\n").utf8))
            try? out.close()
        }
        #endif
        let id = UUID().uuidString.lowercased()
        if let echo = e.echo {
            withAnimation(spring) { messages.append(ChatMessage(id: id, text: echo, fromUser: true)) }
        }
        guard client != nil, e.relays else { return }
        post(id: id, body: e.line, kind: "event", meta: e.meta)
    }

    /// `show` for the environment, made once: a fresh closure on every render
    /// changes the environment each timer tick and swallows taps on the stage.
    @ObservationIgnored private(set) lazy var ylShow = YLShow { [weak self] scope, screen, name in
        self?.show(name, screen: screen, in: scope)
    }

    /// `project open=name`: put the saved screen `name` back, the same as the
    /// agent sending `show name` in reply `id` (spec: project).
    func show(_ name: String, screen: String, in id: String) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(spring) { messages[i].yl?.apply(YLNode(op: .show, screen: screen, name: name, line: "show \(name)")) }
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
        self.account = account
        messages = []
        stageID = nil
        stageOpen = false
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
        let m = ChatMessage(id: UUID().uuidString.lowercased(), text: text, fromUser: true)
        withAnimation(spring) { messages.append(m) }
        post(id: m.id, body: text, kind: "text", meta: nil)
    }

    /// Into the outbox first (on disk), then out: a dropped network or a killed
    /// app never loses it, and it sends itself when the connection is back.
    private func post(id: String = UUID().uuidString.lowercased(), body: String, kind: String, meta: YLValue?) {
        guard client != nil, let agentID = agent?.id, let user = account?.session?.userID else { return }
        seen.insert(id.lowercased())
        waiting = true
        waitingSince = .now
        Outbox.shared.add(.init(id: id.lowercased(), userID: user, agentID: agentID, body: body, kind: kind,
                                meta: meta, queuedAt: .now))
    }

    /// Messages still in the outbox for this thread, after the history: they
    /// were sent last. Shown as not sent yet until they land.
    private func restorePending() {
        guard let agentID = agent?.id else { return }
        var new: [ChatMessage] = []
        for item in Outbox.shared.pending(agentID: agentID) where seen.insert(item.id).inserted {
            if item.kind == "event" {
                if let echo = item.meta?.object?["echo"]?.string { new.append(ChatMessage(id: item.id, text: echo, fromUser: true)) }
            } else {
                new.append(ChatMessage(id: item.id, text: item.body, fromUser: true))
            }
        }
        guard !new.isEmpty else { return }
        messages.append(contentsOf: new)
        waiting = true
        waitingSince = .now
    }

    func refresh() async {
        guard let client, let agentID = agent?.id else { return }
        let first = !loaded
        do {
            // Overlap the last poll by 10 s: a row can commit after a later one.
            let rows = try await client.fetch(since: cursor.map { YuiTime.before($0, seconds: 10) })
            guard agent?.id == agentID else { return }
            for row in rows { add(row) }
            if let last = rows.last?.createdAt, last > (cursor ?? "") { cursor = last }
            loaded = true
            // Dots give up after 3 minutes for an agent that is online; one that is
            // asleep keeps its "waiting" note until the answer comes.
            if let since = waitingSince, Date.now.timeIntervalSince(since) > 180,
               agent?.liveness == .online, Outbox.shared.pending(agentID: agentID).isEmpty { waiting = false }
        } catch {
            loaded = true
        }
        if first { restorePending() }
    }

    private func add(_ row: ThreadRow) {
        let id = row.id.lowercased()
        // Polls overlap: only a row not seen before can end the wait.
        guard seen.insert(id).inserted else { return }
        if row.sender == "agent" { waiting = false }
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
                    var screen = YLScreen()
                    for node in YuiLines.parse(y) {
                        // A patch for something an earlier reply drew (`~choose +lock`
                        // after the booking is confirmed) lands on the newest match.
                        if node.op == .patch, let t = node.target, !screen.has(t),
                           let j = messages.lastIndex(where: { $0.yl?.has(t) == true }) {
                            messages[j].yl?.apply(node)
                        } else {
                            screen.apply(node)
                        }
                    }
                    if let agentID = agent?.id { for look in screen.looks { onLook?(agentID, look, row.createdAt) } }
                    new.append(ChatMessage(id: "\(id)#\(i)", text: "", fromUser: false, yl: screen))
                }
            }
        }
        guard !new.isEmpty else { return }
        withAnimation(loaded ? spring : nil) { messages.append(contentsOf: new) }
        // Live replies can take the stage; history loading on open never does.
        if loaded { for m in new where m.yl != nil { stageUpdate(m.id, before: nil) } }
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
        let before = messages[i].yl
        withAnimation(spring) {
            for n in nodes { messages[i].yl?.apply(n) }
        }
        stageUpdate(id, before: before)
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
