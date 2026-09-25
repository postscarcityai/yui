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
    /// The person's photos on this message (composer attachments).
    var photos: [MessagePhoto] = []
    /// The person's reply to an earlier message: its quote (YUI-68).
    var replyTo: ReplyQuote? = nil
    /// The person's message went to another agent ("To Luna"), or came here
    /// from another agent's thread ("You, from Alpha's thread") (YUI-44).
    var mentionTo: String? = nil
    /// Another agent's answer to a mention, copied into this thread (YUI-44).
    var from: MentionFrom? = nil
    /// The person typed it on this screen (YUI-62): "From screen 2".
    var fromScreen: Int? = nil
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

    /// A long plain answer read as pages (YUI-79): a deck made from its words, on the stage.
    private(set) var reading: ChatMessage?

    var stageMessage: ChatMessage? {
        stageID.flatMap { id in reading?.id == id ? reading : messages.first { $0.id == id } }
    }

    /// "Read as pages" on a folded bubble: its words as a deck, full screen.
    func readAsPages(_ m: ChatMessage) {
        let id = m.id + "#pages"
        if reading?.id != id { reading = ChatMessage(id: id, text: "", fromUser: false, yl: LongText.deck(m.plain)) }
        openStage(id)
    }

    /// The pages are for reading: a deck of them tells the agent nothing.
    static let quiet = YLEmit()

    /// What the stage holds: the staged part of its reply, empty when that reply
    /// is gone or nothing in it opens on the stage any more (a new look said
    /// `screen=chat`). The StageView is mounted only while this has something.
    var stageComponents: [YLComponent] { stageMessage?.yl?.staged(style) ?? [] }

    /// The stage is up with something on it. The chat steps back only then: an
    /// open flag with nothing to show left it shrunk with no way back (YUI-80).
    var stageShowing: Bool { stageOpen && !stageComponents.isEmpty }

    func openStage(_ id: String) {
        withAnimation(spring) {
            stageID = id
            stageOpen = true
        }
    }

    func closeStage() {
        withAnimation(spring) { stageOpen = false }
    }

    /// Open with nothing on it (its reply went, or its screens stopped being staged):
    /// close it, so it can't pop back up later on its own (YUI-80).
    func settleStage() {
        if stageOpen, stageComponents.isEmpty { closeStage() }
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

    // MARK: Pages (YUI-31, spec YL.md section 5, Pages)

    /// The page on show: 1 is the chat, 2 to 12 the agent's screens beside it.
    private(set) var page = 1
    /// The page each agent's thread was on, so switching agents and back keeps it.
    private var pages: [String: Int] = [:]

    /// Bumped on every request to move (a tab, a pill, a reply sent to a page),
    /// so the pager moves even when it and `page` disagree.
    private(set) var pageTurns = 0

    func goToPage(_ n: Int) {
        guard (1...YuiLines.maxPage).contains(n) else { return }
        showingPage(n)
        pageTurns += 1
    }

    /// The person swiped to page `n`: note it, nothing to move.
    func showingPage(_ n: Int) {
        guard (1...YuiLines.maxPage).contains(n) else { return }
        page = n
        if let id = agent?.id { pages[id] = n }
    }

    /// Made once, like `ylShow`: the chat's "On screen 2" pills go through it.
    @ObservationIgnored private(set) lazy var ylPage = YLPage { [weak self] n in self?.goToPage(n) }

    /// The pages there are, in order: the chat, then each screen with something
    /// on it. A screen appears when a line lands there and goes when `>N clear`
    /// empties it; the numbers can skip (`>5` alone makes chat and screen 5).
    var screens: [Int] {
        var on = Set<Int>()
        for m in messages {
            guard let yl = m.yl else { continue }
            for c in yl.top where c.page != 1 && !c.onStage(style) { on.insert(c.page) }
        }
        return [1] + on.sorted()
    }

    /// What is on page `n`: each reply with something there, oldest first.
    /// A page keeps what lands on it across replies until `>2 clear`.
    func onPage(_ n: Int) -> [ChatMessage] {
        messages.filter { $0.yl.map { !$0.onPage(n, style: style).isEmpty } ?? false }
    }

    /// A live reply added something to a page: bring the newest such page forward.
    /// Patches, `clear` and history loading never move the person.
    private func pageUpdate(_ nodes: [YLNode]) {
        guard let n = nodes.last(where: { $0.op == .add && YuiLines.page(of: $0.screen) != 1
            && !YuiLines.opensOnStage($0, style: style) }).map({ YuiLines.page(of: $0.screen) }) else { return }
        goToPage(n)
    }

    /// Ids that last into the next reply (spec section 5, YUI-75), id -> preset,
    /// newest wins: so `~need-t_x +lock` reaches one ask among many on page 2
    /// and the war room patches a panel instead of re-sending the page.
    var lastingIds: [String: String] {
        var out: [String: String] = [:]
        for m in messages { for c in m.yl?.components ?? [] where c.lasts { out[c.ylID] = c.preset } }
        return out
    }

    /// `>2 clear` empties the page, which holds what earlier replies put there too.
    private func clearPage(_ node: YLNode, except id: String? = nil) {
        guard node.op == .clear, YuiLines.page(of: node.screen) != 1 else { return }
        for j in messages.indices where messages[j].id != id && messages[j].yl != nil { messages[j].yl?.empty(node.screen) }
    }

    /// Pages the agent keeps the composer on (`>2 talk`, YUI-62), from every reply
    /// in order: `talk off` and `>2 clear` take it away again.
    var talking: Set<Int> { Set(YuiLines.talking(messages.flatMap { $0.yl?.talkLines ?? [] })) }

    /// The composer shows on page `n`: the chat always, a page when the agent said `talk`.
    func talks(on n: Int) -> Bool { n == 1 || talking.contains(n) }

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
    /// When the reply started being owed: the working note counts from here.
    private(set) var waitingSince: Date?
    /// When the agent's host picked the message up (its delivered_at): from
    /// then on the agent is working on it, however long that takes.
    private(set) var pickedUpAt: Date?
    private var turnCheckedAt = Date.distantPast
    /// A reopened thread only resumes a turn this recent (the host gives up on
    /// a turn after 30 minutes, TURN_TIMEOUT_SECONDS in the plugin).
    static let turnWindow: TimeInterval = 30 * 60

    init(messages: [ChatMessage] = []) { self.messages = messages }

    /// Made once, like `ylShow`: a fresh closure on every render changes the
    /// environment of every preset (and every full-screen cover) each render.
    @ObservationIgnored private(set) lazy var emit = YLEmit { [weak self] e in self?.receive(e) }

    // MARK: Reactions (YUI-49, spec yuigui/spec/REACTIONS.md)

    /// The emoji on each agent reply, by thread row id. One per row.
    private(set) var reactions: [String: String] = [:]
    /// The bubble whose reaction bar is open.
    var reacting: String?

    var reactingMessage: ChatMessage? { reacting.flatMap { id in messages.first { $0.id == id } } }

    /// The bubble that wears a row's badge: its last text bubble, or its last
    /// card when the reply is all cards (a held card takes reactions too, YUI-68).
    func wearsReaction(_ m: ChatMessage) -> Bool {
        guard !m.fromUser else { return false }
        let row = messages.filter { $0.rowID == m.rowID && !$0.fromUser }
        return (row.last { $0.yl == nil } ?? row.last)?.id == m.id
    }

    func reaction(for m: ChatMessage) -> Reaction? { Reaction.named(reactions[m.rowID]) }

    /// Reacts to the reply `messageID` belongs to. The one already there again
    /// takes it back; another replaces it. Goes to the agent as one turn.
    func react(_ messageID: String, with pick: Reaction?) {
        guard let m = messages.first(where: { $0.id == messageID }), !m.fromUser else { return }
        let row = m.rowID
        let old = Reaction.named(reactions[row])
        let new = pick == old ? nil : pick
        guard new != old else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.62)) { reactions[row] = new?.emoji }
        let quoted = messages.filter { $0.rowID == row && !$0.fromUser && $0.yl == nil }.map(\.text).joined(separator: "\n")
        post(body: Reaction.body(msg: row, reaction: new, changed: old != nil && new != nil, quoting: quoted),
             kind: "event", meta: Reaction.meta(msg: row, reaction: new))
    }

    /// A react event (history, outbox or poll): newest wins, rows come oldest first.
    private func applyReaction(meta: YLValue?) {
        guard let r = Reaction.from(meta: meta) else { return }
        reactions[r.msg] = r.emoji
    }

    // MARK: Replies (YUI-68)

    /// The message the next send answers: its quote sits above the composer.
    var replying: ReplyQuote?
    /// The bubble just scrolled to from a reply's chip: it glows for a moment.
    private(set) var flashing: String?

    /// Hold menu Reply, or a left swipe: quote this bubble or card in the composer.
    func startReply(_ messageID: String) {
        guard let m = messages.first(where: { $0.id == messageID }), let q = ReplyQuote(m) else { return }
        withAnimation(spring) { replying = q }
    }

    func cancelReply() { withAnimation(spring) { replying = nil } }

    /// Where a reply's chip goes: the first bubble of the row it quotes, if it is loaded.
    func original(of q: ReplyQuote) -> String? { messages.first { $0.rowID.lowercased() == q.msg }?.id }

    /// The original lights up once it is on screen.
    func flash(_ id: String) {
        flashing = id
        Task {
            try? await Task.sleep(for: .seconds(2))
            if flashing == id { withAnimation(.easeOut(duration: 0.4)) { flashing = nil } }
        }
    }

    /// The reply set now, taken for one send. A slash command goes out bare.
    private func takeReply(for text: String) -> ReplyQuote? {
        guard let q = replying, !text.hasPrefix("/") else { return nil }
        replying = nil
        return q
    }

    // MARK: Answers

    /// The newest answer for each component, by reply (message id) then YL id.
    /// Filled from the thread's own event rows, so a reopened thread shows what
    /// was chosen, picked or slid instead of blank components.
    private(set) var answers: [String: [String: [String: YLValue]]] = [:]

    /// Made once, like `emit`: presets read their answer back through it.
    @ObservationIgnored private(set) lazy var ylAnswers = YLAnswers { [weak self] scope, id in self?.answers[scope]?[id] }

    /// Files an answer under the reply that drew it: the newest message with a
    /// component of that id and preset. YL ids repeat across replies (`n1` in
    /// every one), and a later reply's `n1` owns every answer after it lands.
    private func record(id: String, preset: String, value: [String: YLValue]) {
        guard let m = messages.last(where: { $0.yl?.components.contains { $0.ylID == id && $0.preset == preset } == true })
        else { return }
        answers[m.id, default: [:]][id] = value
    }

    /// An event row (history, outbox or a live tap) as an answer: only answers carry an echo.
    private func record(meta: YLValue?) {
        guard let o = meta?.object, o["echo"] != nil, let id = o["id"]?.string, let preset = o["preset"]?.string,
              let value = o["value"]?.object else { return }
        record(id: id, preset: preset, value: value)
    }

    func receive(_ e: YLEvent) {
        events.insert(e, at: 0)
        if e.echo != nil { record(id: e.id, preset: e.preset, value: e.value) }
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
        // -yuiDemoGame: on the demo account a stand-in agent answers tic-tac-toe moves (UI tests, videos).
        if client == nil, UserDefaults.standard.bool(forKey: "yuiDemoGame"), e.preset == "game",
           e.value["kind"] == .string("tictactoe"), e.value["winner"] == nil, let move = e.value["move"]?.number {
            let x = TicTacToe.cells(e.value["x"]), o = TicTacToe.cells(e.value["o"])
            let me = x.contains(Int(move)) ? "o" : "x"
            let mine = me == "o" ? o : x
            if let cell = TicTacToe.reply(mine: mine, theirs: me == "o" ? x : o) {
                Task {
                    try? await Task.sleep(for: .seconds(0.9))
                    stream("~game \(me)=" + (mine + [cell]).map(String.init).joined(separator: "|"))
                }
            }
        }
        #endif
        let id = UUID().uuidString.lowercased()
        // A sent plan is done with the whole phone: back to the chat, where its answers land (YUI-51).
        if e.preset == "plan", e.value["plan"] != nil, stageOpen { closeStage() }
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
        guard let i = messages.firstIndex(where: { $0.id == id }), var yl = messages[i].yl else { return }
        apply(YLNode(op: .show, screen: screen, name: name, line: "show \(name)"), to: &yl)
        withAnimation(spring) { messages[i].yl = yl }
    }

    // MARK: Shelf (YUI-32, spec YL.md section 5, saved screens)

    /// The open agent's saved screens. Rebuilt from the thread as it loads, and
    /// kept on the phone so it outlives the thread's retention.
    private(set) var shelf = Shelf()

    /// `show name`: this reply's own save first, else the shelf (a save from an
    /// earlier reply), else the usual error.
    private func apply(_ node: YLNode, to screen: inout YLScreen) {
        if node.op == .show, let name = node.name, !screen.hasSaved(name), let saved = shelf[name] {
            screen.restore(saved, on: node.screen)
        } else {
            screen.apply(node)
        }
    }

    /// A reply's saves and forgets onto the shelf, stamped with the reply's time.
    private func file(_ ops: [ShelfOp], at: Date) {
        var changed = false
        for op in ops { changed = shelf.apply(op, at: at) || changed }
        if changed, let agentID = agent?.id { shelf.store(agentID: agentID) }
    }

    /// A patch to an id that lasts reaches the shelf's copies of it (YUI-75).
    private func shelve(_ node: YLNode, at: Date) {
        if shelf.patch(node, at: at), let agentID = agent?.id { shelf.store(agentID: agentID) }
    }

    /// A tap on the shelf: the saved screen opens on the stage, fresh, with no turn.
    func reopen(_ name: String) {
        guard let saved = shelf[name] else { return }
        var screen = YLScreen()
        screen.restore(saved, on: "full")
        let m = ChatMessage(id: "shelf-\(UUID().uuidString.lowercased())", text: "", fromUser: false, yl: screen)
        withAnimation(spring) { messages.append(m) }
        openStage(m.id)
    }

    /// Held on the shelf, Remove. Only a later save brings it back.
    func unshelve(_ name: String) {
        withAnimation(spring) { shelf.remove(name) }
        if let agentID = agent?.id { shelf.store(agentID: agentID) }
    }

    // MARK: The drawer's lists (YUI-86, spec YL.md section 5, The drawer)

    /// What the open agent put in its drawer with `menu` lines: review, backlog,
    /// shortcuts. Rebuilt from the thread as it loads and kept on the phone, like the shelf.
    private(set) var menu = AgentMenu()

    /// A reply's `menu` lines, stamped with the reply's time.
    private func fileMenu(_ nodes: [YLNode], at: Date) {
        guard !nodes.isEmpty else { return }
        withAnimation(spring) { menu.apply(nodes, at: at) }
        if let agentID = agent?.id { menu.store(agentID: agentID) }
    }

    /// Held in the drawer, Remove. Only a later line from the agent brings it back.
    func removeFromMenu(_ id: String) {
        withAnimation(spring) { menu.remove(id) }
        if let agentID = agent?.id { menu.store(agentID: agentID) }
    }

    /// A review or backlog item with no `show=` or `url=`: it goes back to the
    /// agent (`[yui] dana menu bucket=review tapped`), and the agent answers with the screen.
    func tapMenu(_ item: YLMenuItem, bucket: String) {
        receive(YLEvent(id: item.id, preset: "menu", value: ["bucket": .string(bucket), "tapped": .bool(true)],
                        echo: item.label))
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
        answers = [:]
        shelf = agent.map { Shelf.load(agentID: $0.id) } ?? Shelf()
        menu = agent.map { AgentMenu.load(agentID: $0.id) } ?? AgentMenu()
        reactions = [:]
        reacting = nil
        replying = nil
        stageID = nil
        stageOpen = false
        reading = nil
        page = agent.flatMap { pages[$0.id] } ?? 1
        seen = []
        cursor = nil
        waiting = false
        pickedUpAt = nil
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

    /// A sent bubble's lift into the thread: quick, under 300 ms, whatever the agent's look.
    static let sendSpring: Animation = .spring(response: 0.28, dampingFraction: 0.72)

    /// False when it can't go out (no agent or session yet): nothing is added, the caller keeps the text.
    @discardableResult
    func send(_ text: String, mention: YuiAgent? = nil, screen: Int? = nil) -> Bool {
        // Typed on a screen (YUI-62): tagged with it. A slash command is still a command.
        let screen = text.hasPrefix("/") ? nil : screen
        #if DEBUG
        // -yuiDemoReply "<lines>": on the demo account the agent answers what you send with these lines (SOC-3 videos).
        if client == nil, agent != nil, let reply = UserDefaults.standard.string(forKey: "yuiDemoReply") {
            let q = screen == nil ? takeReply(for: text) : nil
            withAnimation(Self.sendSpring) {
                messages.append(ChatMessage(text: text, fromUser: true, replyTo: q, fromScreen: screen))
            }
            waiting = true
            waitingSince = .now
            pickedUpAt = nil
            // -yuiDemoPickupAfter / -yuiDemoReplyAfter <seconds>: stretch the turn so the working row can be watched (YUI-63).
            let d = UserDefaults.standard
            let pickup = d.object(forKey: "yuiDemoPickupAfter") == nil ? 0.5 : d.double(forKey: "yuiDemoPickupAfter")
            let answer = max(pickup, d.object(forKey: "yuiDemoReplyAfter") == nil ? 1.6 : d.double(forKey: "yuiDemoReplyAfter"))
            Task {
                try? await Task.sleep(for: .seconds(pickup))
                pickedUpAt = .now
                try? await Task.sleep(for: .seconds(answer - pickup))
                waiting = false
                pickedUpAt = nil
                stream(reply.replacingOccurrences(of: "\\n", with: "\n"))
            }
            return true
        }
        #endif
        guard client != nil, agent != nil, account?.session?.userID != nil else { return false }
        if let screen {
            // About the screen, to this agent: no mention, and a reply quote waits for the chat.
            let m = ChatMessage(id: UUID().uuidString.lowercased(), text: text, fromUser: true, fromScreen: screen)
            withAnimation(Self.sendSpring) { messages.append(m) }
            post(id: m.id, body: ScreenTalk.body(text, screen: screen), kind: "text", meta: ScreenTalk.meta(nil, screen: screen))
            return true
        }
        if let mention {
            // A mention goes to the other agent with this thread's last lines; a reply
            // quote would point at a row it can't see, so it stays here.
            replying = nil
            let m = ChatMessage(id: UUID().uuidString.lowercased(), text: text, fromUser: true, mentionTo: "To \(mention.name)")
            withAnimation(Self.sendSpring) { messages.append(m) }
            post(id: m.id, body: Mentions.body(text, to: mention), kind: "text", meta: Mentions.meta(nil, to: mention),
                 answers: false)
            return true
        }
        let q = takeReply(for: text)
        let m = ChatMessage(id: UUID().uuidString.lowercased(), text: text, fromUser: true, replyTo: q)
        withAnimation(Self.sendSpring) { messages.append(m) }
        post(id: m.id, body: ReplyQuote.body(text, replyingTo: q), kind: "text", meta: ReplyQuote.meta(nil, replyingTo: q))
        return true
    }

    /// Words and photos. The photos go up first (the outbox holds rows, not
    /// files), then the row goes out like any other. Throws when an upload
    /// fails: nothing is added, the composer keeps everything.
    func send(_ text: String, photos: [ComposerPhoto], mention: YuiAgent? = nil, screen: Int? = nil) async throws {
        guard !photos.isEmpty else { if !send(text, mention: mention, screen: screen) { throw AccountError.signedOut }; return }
        guard client != nil, let agentID = agent?.id, let account else { throw AccountError.signedOut }
        let media = YuiMedia(account: account, agentID: agentID)
        var paths: [String] = []
        for p in photos { paths.append(try await media.upload(photo: p.jpeg)) }
        guard agent?.id == agentID else { throw AccountError.signedOut }  // switched threads mid-upload
        let body = Attachments.body(text: text, photos: paths.count)
        if let screen {
            let m = ChatMessage(id: UUID().uuidString.lowercased(), text: Attachments.caption(body: body, photos: paths.count),
                                fromUser: true, photos: photos.map { .local($0.preview) }, fromScreen: screen)
            withAnimation(Self.sendSpring) { messages.append(m) }
            post(id: m.id, body: ScreenTalk.body(body, screen: screen), kind: "text",
                 meta: ScreenTalk.meta(Attachments.meta(paths: paths), screen: screen))
            return
        }
        if let mention {
            replying = nil
            let m = ChatMessage(id: UUID().uuidString.lowercased(), text: Attachments.caption(body: body, photos: paths.count),
                                fromUser: true, photos: photos.map { .local($0.preview) }, mentionTo: "To \(mention.name)")
            withAnimation(Self.sendSpring) { messages.append(m) }
            post(id: m.id, body: Mentions.body(body, to: mention), kind: "text",
                 meta: Mentions.meta(Attachments.meta(paths: paths), to: mention), answers: false)
            return
        }
        let q = takeReply(for: body)
        let m = ChatMessage(id: UUID().uuidString.lowercased(), text: Attachments.caption(body: body, photos: paths.count),
                            fromUser: true, photos: photos.map { .local($0.preview) }, replyTo: q)
        withAnimation(Self.sendSpring) { messages.append(m) }
        post(id: m.id, body: ReplyQuote.body(body, replyingTo: q), kind: "text",
             meta: ReplyQuote.meta(Attachments.meta(paths: paths), replyingTo: q))
    }

    /// A person's text row (or outbox item) as a bubble, photos and reply quote included.
    static func userMessage(id: String, body: String, meta: YLValue?) -> ChatMessage {
        let paths = Attachments.paths(meta)
        let arrived = Mentions.arrived(meta: meta)
        let words = arrived != nil ? Mentions.arrivedWords(body: body)
            : Mentions.words(body: ReplyQuote.words(body: ScreenTalk.words(body: body, meta: meta), meta: meta), meta: meta)
        return ChatMessage(id: id, text: Attachments.caption(body: words, photos: paths.count), fromUser: true,
                           photos: paths.map { .stored($0) }, replyTo: ReplyQuote.from(meta: meta),
                           mentionTo: Mentions.to(meta: meta).map { "To \($0)" } ?? arrived,
                           fromScreen: ScreenTalk.screen(meta: meta))
    }

    /// Into the outbox first (on disk), then out: a dropped network or a killed
    /// app never loses it, and it sends itself when the connection is back.
    /// `answers: false`: this agent won't answer it (a mention goes to another), so no typing dots.
    private func post(id: String = UUID().uuidString.lowercased(), body: String, kind: String, meta: YLValue?,
                      answers: Bool = true) {
        guard client != nil, let agentID = agent?.id, let user = account?.session?.userID else { return }
        seen.insert(id.lowercased())
        if answers {
            waiting = true
            waitingSince = .now
            pickedUpAt = nil
        }
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
                record(meta: item.meta)
                applyReaction(meta: item.meta)
                if let echo = item.meta?.object?["echo"]?.string { new.append(ChatMessage(id: item.id, text: echo, fromUser: true)) }
            } else {
                new.append(Self.userMessage(id: item.id, body: item.body, meta: item.meta))
            }
        }
        guard !new.isEmpty else { return }
        messages.append(contentsOf: new)
        waiting = true
        waitingSince = .now
        pickedUpAt = nil
    }

    func refresh() async {
        guard let client, let agentID = agent?.id else { return }
        let first = !loaded
        do {
            // Overlap the last poll by 10 s: a row can commit after a later one.
            let rows = try await client.fetch(since: cursor.map { YuiTime.before($0, seconds: 10) })
            guard agent?.id == agentID else { return }
            for row in rows { add(row) }
            if first { resume(rows) }
            if let last = rows.last?.createdAt, last > (cursor ?? "") { cursor = last }
            loaded = true
            // No time limit on a turn: the dots stay until the reply comes or the
            // host says the turn is over. Asleep or offline agents get their own note.
            if waiting, Date.now.timeIntervalSince(turnCheckedAt) > 4, Outbox.shared.pending(agentID: agentID).isEmpty {
                turnCheckedAt = .now
                if let row = try await client.newestFromUser(), agent?.id == agentID, waiting { track(row) }
            }
        } catch {
            loaded = true
        }
        if first { restorePending() }
    }

    /// Thread rows, oldest first, the way a poll adds them. Tests and `-yuiThreadRows` use it.
    func load(_ rows: [ThreadRow]) {
        for row in rows { add(row) }
        resume(rows)
    }

    /// A thread opened mid-turn: its newest row is the person's and the agent
    /// has not finished it, so the working note picks up where it was.
    private func resume(_ rows: [ThreadRow], now: Date = .now) {
        guard let last = rows.last, last.sender == "user", last.handledAt == nil,
              let sent = YuiTime.date(last.createdAt), now.timeIntervalSince(sent) < Self.turnWindow else { return }
        waiting = true
        waitingSince = sent
        pickedUpAt = last.deliveredAt.flatMap(YuiTime.date)
    }

    /// How far the turn on the person's newest row has got. Finished with no
    /// reply after a grace period (a command, a turn that errored): stop waiting.
    private func track(_ row: ThreadRow, now: Date = .now) {
        pickedUpAt = row.deliveredAt.flatMap(YuiTime.date) ?? pickedUpAt
        if let done = row.handledAt.flatMap(YuiTime.date), now.timeIntervalSince(done) > 20 { waiting = false }
    }

    private func add(_ row: ThreadRow) {
        let id = row.id.lowercased()
        // Polls overlap: only a row not seen before can end the wait.
        guard seen.insert(id).inserted else { return }
        // Another agent's answer copied in (YUI-44) doesn't end this agent's turn.
        if row.sender == "agent", Mentions.from(meta: row.meta) == nil { waiting = false; pickedUpAt = nil }
        var new: [ChatMessage] = []
        /// A live reply's lines: they can bring a page forward.
        var live: [YLNode] = []
        if row.sender == "user" {
            if row.kind == "event" {
                record(meta: row.meta)
                applyReaction(meta: row.meta)
                if let echo = row.meta?.object?["echo"]?.string { new.append(ChatMessage(id: id, text: echo, fromUser: true)) }
            } else {
                new.append(Self.userMessage(id: id, body: row.body, meta: row.meta))
            }
        } else if let from = Mentions.from(meta: row.meta) {
            // Another agent's answer to a mention (YUI-44): its words here, in its look.
            // Its screens stay in its own thread, where their taps reach it.
            if let r = row.reaction { reactions[id] = r }
            for (i, seg) in YuiFence.split(row.body).enumerated() {
                switch seg {
                case .text(let t): new.append(ChatMessage(id: "\(id)#\(i)", text: t, fromUser: false, from: from))
                case .yl: new.append(ChatMessage(id: "\(id)#\(i)", text: "Sent a screen. It's in \(from.name)'s thread.",
                                                 fromUser: false, from: from))
                }
            }
        } else {
            if let r = row.reaction { reactions[id] = r }
            for (i, seg) in YuiFence.split(row.body).enumerated() {
                switch seg {
                case .text(let t): new.append(ChatMessage(id: "\(id)#\(i)", text: t, fromUser: false))
                case .yl(let y):
                    var screen = YLScreen()
                    let known = lastingIds
                    let at = YuiTime.date(row.createdAt) ?? .now
                    let nodes = YuiLines.parse(y, known: known)
                    for node in nodes {
                        clearPage(node)
                        // A patch for something an earlier reply drew (`~choose +lock`
                        // after the booking is confirmed) lands on the newest match.
                        if node.op == .patch, let t = node.target, !screen.has(t),
                           let j = messages.lastIndex(where: { $0.yl?.has(t) == true }) {
                            messages[j].yl?.apply(node)
                            if known[t] != nil { shelve(node, at: at) }
                        } else {
                            apply(node, to: &screen)
                        }
                    }
                    file(screen.shelfOps, at: at)
                    fileMenu(screen.menuLines, at: at)
                    if let agentID = agent?.id { for look in screen.looks { onLook?(agentID, look, row.createdAt) } }
                    new.append(ChatMessage(id: "\(id)#\(i)", text: "", fromUser: false, yl: screen))
                    if loaded { live += nodes }
                }
            }
        }
        guard !new.isEmpty else { return }
        withAnimation(loaded ? spring : nil) { messages.append(contentsOf: new) }
        // Live replies can take the stage; history loading on open never does.
        if loaded { for m in new where m.yl != nil { stageUpdate(m.id, before: nil) } }
        pageUpdate(live)
    }

    /// Adds an agent reply and feeds it through the stream parser a line at a
    /// time, the way a model's tokens will arrive, so each preset lands on its own.
    func stream(_ text: String, lineDelay: Duration = .milliseconds(220)) {
        let msg = ChatMessage(text: "", fromUser: false, yl: YLScreen())
        withAnimation(spring) { messages.append(msg) }
        Task {
            var parser = YLStreamParser(known: lastingIds)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                apply(parser.push(line + "\n"), to: msg.id)
                try? await Task.sleep(for: lineDelay)
            }
            apply(parser.flush(), to: msg.id)
        }
    }

    private func apply(_ nodes: [YLNode], to id: String) {
        guard !nodes.isEmpty, let i = messages.firstIndex(where: { $0.id == id }) else { return }
        guard var yl = messages[i].yl else { return }
        let before = yl
        let known = lastingIds
        // A patch for something an earlier reply drew lands on the newest match, as in history.
        var earlier: [(Int, YLNode)] = []
        for n in nodes {
            if n.op == .patch, let t = n.target, !yl.has(t),
               let j = messages[..<i].lastIndex(where: { $0.yl?.has(t) == true }) {
                earlier.append((j, n))
            } else {
                apply(n, to: &yl)
            }
        }
        withAnimation(spring) {
            for n in nodes { clearPage(n, except: id) }
            messages[i].yl = yl
            for (j, n) in earlier { messages[j].yl?.apply(n) }
        }
        for (_, n) in earlier where known[n.target ?? ""] != nil { shelve(n, at: .now) }
        file(Array(yl.shelfOps.dropFirst(before.shelfOps.count)), at: .now)
        fileMenu(nodes.filter { $0.op == .menu }, at: .now)
        pageUpdate(nodes)
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
        ("needs", """
        choose@need-t_8b02462c "How did it go?" "Works"|"Phone only"|"Connector failed"|"Not yet"|"You decide" tag=INT-7 title="Claude adapter, MCP connector plus Yui screens as an MCP App" body="Yui is built as a Claude connector. The last check needs your browser: in claude.ai add Yui as a custom connector, then ask Claude for a 5 minute timer."
        choose@need-t_85ea7583 "How did it go?" "Works"|"Phone only"|"Failed"|"Not yet"|"You decide" tag=INT-8 title="ChatGPT adapter through the Yui MCP server" body="Yui is built as a ChatGPT connector too. The last check needs your browser: in chatgpt.com developer mode add Yui as a connector, then ask for a 5 minute timer."
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
