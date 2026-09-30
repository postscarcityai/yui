import Foundation
import Observation
import QuartzCore
import SwiftUI
import Synchronization
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
    /// Sent about a Controls item (YUI-69): "About SOUL.md".
    var about: String? = nil
    /// The agent's hello, the first message its thread opens on (`meta.native = "first"`):
    /// an answer to start from, never something waiting on you in Review (YUI-165).
    var hello = false
    /// The agent's home (`meta.native = "home"`, YUI-168): its shortcuts and starter screens,
    /// written once. It fills the chips and the pages and never shows in the record.
    var home = false
    /// The person stopped the agent here (YUI-190): a quiet "Stopped" in the record, nothing on the stage.
    var stopped = false
    /// When it was sent (YUI-202): the row's time, or now for what this phone made.
    var sentAt = Date.now
}

/// The chat's messages and the events going back to the agent.
/// Attached to an agent, it is that agent's thread (yui_messages, spec
/// yuigui/spec/RELAY.md); detached, it is the local demo chat.
@Observable @MainActor
final class ChatStore {
    var messages: [ChatMessage] {
        didSet {
            derived = nil
            waitingCache = nil
            // The demo account keeps no server: a chat made here is saved the moment something is said in it.
            if client == nil, chats.openIsDraft, messages.contains(where: \.fromUser) { chats.saveDraft() }
        }
    }
    /// The agent's screens (`>2` and up), patches, saves and drawer lines said in its OTHER chats
    /// (YUI-169). Screens belong to the agent, so every chat draws them; the thread never does.
    private(set) var scoped: [ChatMessage] = [] { didSet { derived = nil; waitingCache = nil } }
    /// Every message a screen can be on: the agent's from other chats first, then this chat's.
    var pool: [ChatMessage] { scoped.isEmpty ? messages : scoped + messages }
    var spring: Animation = .default
    /// An agent reply carried a `theme` line: (agent id, props, message time).
    var onLook: (@MainActor (String, [String: String], String) -> Void)?

    // MARK: Stage (YUI-13, spec YL.md section 5)

    /// The open agent's style profile: decides what opens on the stage.
    var style: [String: String] = [:] { didSet { if style != oldValue { derived = nil } } }

    /// What the thread reads on every pass, worked out once per change to the
    /// messages or the style (YUI-101): a 500-row thread used to scan every
    /// message for each row and each page on every frame of a drag.
    private struct Derived {
        var shown: [ChatMessage]
        var wearers: Set<String>
        var screens: [Int]
        var talking: Set<Int>
        var restyleNewest: String?
        var visual: YLVisual?
        var visualSaid: Bool
    }
    @ObservationIgnored private var derived: Derived?

    private var derive: Derived {
        // Reading `messages` and `style` keeps the views that ask observing them.
        let messages = messages, style = style, scoped = scoped
        if let derived { return derived }
        var lastInRow: [String: (text: String?, any: String)] = [:]
        var on = Set<Int>()
        var restyle: String?
        for m in scoped {
            guard let yl = m.yl else { continue }
            for c in yl.top where c.page != 1 && !c.onStage(style) { on.insert(c.page) }
        }
        for m in messages {
            if !m.fromUser {
                var r = lastInRow[m.rowID] ?? (nil, m.id)
                r.any = m.id
                if m.yl == nil { r.text = m.id }
                lastInRow[m.rowID] = r
            }
            guard let yl = m.yl else { continue }
            for c in yl.top where c.page != 1 && !c.onStage(style) { on.insert(c.page) }
            if yl.restyle != nil { restyle = m.id }
        }
        let visualLines = messages.flatMap { $0.yl?.visualLines ?? [] }
        let d = Derived(shown: messages.filter { $0.yl?.isBlank != true && !$0.home },
                        wearers: Set(lastInRow.values.map { $0.text ?? $0.any }),
                        screens: [1] + on.sorted(),
                        talking: Set(YuiLines.talking((scoped + messages).flatMap { $0.yl?.talkLines ?? [] })),
                        restyleNewest: restyle,
                        visual: YuiLines.visual(of: visualLines),
                        visualSaid: !visualLines.isEmpty)
        derived = d
        return d
    }

    /// The rows the thread draws: a reply with nothing left to draw gets none (YUI-80).
    var shown: [ChatMessage] { derive.shown }

    /// The visual behind the stage (YUI-124): the thread's newest `visual` line, until `visual off`.
    var visual: YLVisual? { derive.visual }
    /// The agent has sent a `visual` line (or `visual off`): its word beats its default (YUI-180).
    var visualSaid: Bool { derive.visualSaid }

    /// The newest reply offering Yui a new look (RESTYLE.md).
    var restyleNewest: String? { derive.restyleNewest }

    /// The reply on the stage, and whether the stage is up or swiped away.
    private(set) var stageID: String?
    private(set) var stageOpen = false
    /// Timer clocks for the whole thread, shared by the stage and the pills.
    let timers = TimerRuns()
    /// Stage first is on (YUI-119): replies play on the full screen, so the old
    /// stage no longer opens by itself (a pill in the record still opens it).
    var stageFirst = false
    /// Bumped each time the person sends something the agent will answer: the stage follows it.
    private(set) var owed = 0

    /// A long plain answer read as pages (YUI-79): a deck made from its words, on the stage.
    private(set) var reading: ChatMessage?

    var stageMessage: ChatMessage? {
        stageID.flatMap { id in reading?.id == id ? reading : messages.first { $0.id == id } }
    }

    /// "Read as pages" on a folded bubble: its words as a deck, full screen.
    func readAsPages(_ m: ChatMessage) {
        let id = m.id + "#pages"
        if reading?.id != id { reading = ChatMessage(id: id, text: "", fromUser: false, yl: LongText.deck(m.plain), sentAt: m.sentAt) }
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
        // fullscreen_open (YUI-102) ends on StageView's first frame.
        if !stageOpen || stageID != id { Perf.shared.begin(.fullscreenOpen) }
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
        // Stage first (YUI-119): the whole reply already plays full screen, so nothing pops up over it.
        if wanted, !stageFirst, yl.staged(style).count > (before?.staged(style).count ?? 0) {
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

    /// Bumped when the person asks for a screen (a pill in the chat, a drawer row), not
    /// when a reply turns the page: with stage first the screens are on the stage, so
    /// the chat opens it there (Chris, 2026-09-27).
    private(set) var screenAsks = 0

    func openScreen(_ n: Int) {
        goToPage(n)
        screenAsks += 1
    }

    /// The person swiped to page `n`: note it, nothing to move.
    func showingPage(_ n: Int) {
        guard (1...YuiLines.maxPage).contains(n) else { return }
        page = n
        if let id = agent?.id { pages[id] = n }
    }

    /// Made once, like `ylShow`: the chat's "On screen 2" pills go through it.
    @ObservationIgnored private(set) lazy var ylPage = YLPage { [weak self] n in self?.openScreen(n) }

    /// The pages there are, in order: the chat, then each screen with something
    /// on it. A screen appears when a line lands there and goes when `>N clear`
    /// empties it; the numbers can skip (`>5` alone makes chat and screen 5).
    var screens: [Int] { derive.screens }

    /// What is on page `n`: each reply with something there, oldest first.
    /// A page keeps what lands on it across replies until `>2 clear`.
    func onPage(_ n: Int) -> [ChatMessage] {
        (n == 1 ? messages : pool).filter { $0.yl.map { !$0.onPage(n, style: style).isEmpty } ?? false }
    }

    /// A live reply added something to a page: bring the newest such page forward.
    /// Patches, `clear` and history loading never move the person.
    /// A reply with something to read in the chat that also redraws a named page (`>4 clear`,
    /// its lines, `save groceries`) keeps the person on what it said: the redraw keeps the page
    /// current, like a patch (YUI-183: Basil's week lands as a deck, not on the grocery list).
    private func pageUpdate(_ nodes: [YLNode]) {
        let saved = Set(nodes.filter { $0.op == .save }.map(\.screen))
        let redrawn = Set(nodes.filter { $0.op == .clear }.map(\.screen)).intersection(saved)
        let says = nodes.contains { $0.op == .add && YuiLines.page(of: $0.screen) == 1 }
        guard let n = nodes.last(where: { $0.op == .add && YuiLines.page(of: $0.screen) != 1
            && !YuiLines.opensOnStage($0, style: style) && !(says && redrawn.contains($0.screen)) })
            .map({ YuiLines.page(of: $0.screen) }) else { return }
        goToPage(n)
    }

    /// Ids that last into the next reply (spec section 5, YUI-75), id -> preset,
    /// newest wins: so `~need-t_x +lock` reaches one ask among many on page 2
    /// and the war room patches a panel instead of re-sending the page.
    var lastingIds: [String: String] {
        var out: [String: String] = [:]
        for m in pool { for c in m.yl?.components ?? [] where c.lasts { out[c.ylID] = c.preset } }
        return out
    }

    /// `>2 clear` empties the page, which holds what earlier replies put there too.
    private func clearPage(_ node: YLNode, except id: String? = nil) {
        guard node.op == .clear, YuiLines.page(of: node.screen) != 1 else { return }
        for j in messages.indices where messages[j].id != id && messages[j].yl != nil { messages[j].yl?.empty(node.screen) }
        for j in scoped.indices where scoped[j].id != id && scoped[j].yl != nil { scoped[j].yl?.empty(node.screen) }
    }

    /// Pages the agent keeps the composer on (`>2 talk`, YUI-62), from every reply
    /// in order: `talk off` and `>2 clear` take it away again.
    var talking: Set<Int> { derive.talking }

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
    // MARK: Chats (YUI-169, spec yuigui/spec/CHATS.md)

    /// The agent's chats as the drawer draws them.
    let chats = ChatList()
    /// The chat this thread is. Nil until the list is in, on a server with no chats, and on no agent.
    private(set) var chatID: String?
    private var chatClient: ChatsClient?
    /// False when the server has no chats yet: the thread is the agent's, as before.
    private var chatsOn = true
    /// The chat a push named: opened when the agent's list is in.
    var wantedChat: String?
    /// The last chat open with each agent this session, so switching agents and back returns to it.
    private var lastChat: [String: String] = [:]
    /// Where each chat was scrolled to this session (points above the bottom); the view keeps it.
    @ObservationIgnored var places: [String: CGFloat] = [:]
    /// The demo account's chats, by id: what was said in each (kept for the session only).
    private var demoThreads: [String: [ChatMessage]] = [:]
    private var scopeCursor: String?
    private var scopePass = 0
    /// A host's key ask waiting for an answer (YUI-34): the app draws the sheet, one at a time.
    var keyAsk: KeyAsk?
    private var keyPass = 0
    /// Chats saved from this phone that a list fetched before them may not hold yet.
    private var justSaved: [String: ChatInfo] = [:]
    /// When the newest agent row in this chat landed, and how far seen_at was reported.
    private var newestAgentAt: String?
    private var seenReported: String?
    /// The app is on screen: an agent row that lands is being read.
    var watching = true
    /// Sends waiting for a chat made on this phone to reach the server.
    private var unsaved: [Outbox.Item] = []
    private var committing = false
    /// A send Yui's server refused for a new chat: the words to put back and what to tell the person.
    private(set) var refusal: (text: String, note: String)?
    func clearRefusal() { refusal = nil }

    /// The open chat's title, for the header: "New chat" until it has one.
    var chatTitle: String {
        guard let c = chats.open else { return "New chat" }
        return Chats.title(c, agent: agent?.name ?? "Yui")
    }
    private var poll: Task<Void, Never>?
    private var cursor: String?
    private var seen = Set<String>()
    /// When the reply started being owed: the working note counts from here.
    private(set) var waitingSince: Date?
    /// When the agent's host picked the message up (its delivered_at): from
    /// then on the agent is working on it, however long that takes.
    private(set) var pickedUpAt: Date?
    /// What the agent says it is doing on this turn (`doing`, YUI-63): its
    /// words and step for the working row. Nil: the working word.
    private(set) var doing: YLDoing?
    /// Work the agent runs after its answer (YUI-103: Basil's "Got it, working out the macros"),
    /// by its job id: the agent is still on it until the job's own answer lands.
    private(set) var job: String?
    private var jobAt: Date?
    /// The agent is on something the person can stop (YUI-190): a turn, or a job behind its answer.
    var working: Bool { waiting || job != nil }
    /// What a Stop ended (YUI-190): the person's rows and the jobs. An answer to any of them
    /// that lands later is never shown, in this session or when the thread opens again.
    private var stoppedRows = Set<String>()
    private var stoppedJobs = Set<String>()
    /// A job's answer is owed at most this long after its "working on it" (a meal takes seconds).
    static let jobWindow: TimeInterval = 10 * 60
    #if DEBUG
    /// The demo account's scripted answer on its way: Stop cancels it.
    private var demoTurn: Task<Void, Never>?
    #endif
    /// How long this agent's recent turns took, pickup to finished, oldest
    /// first (TestFlight AE1JyD1P: "give a range, like an iPhone install").
    /// The working row turns them into "Usually 1 to 3 min".
    private(set) var turnTimes: [TimeInterval] = []
    private var timed = Set<String>()
    /// Turns kept for the range.
    static let turnTimesKept = 20
    private var turnCheckedAt = Date.distantPast
    /// A reopened thread only resumes a turn this recent (the host gives up on
    /// a turn after 30 minutes, TURN_TIMEOUT_SECONDS in the plugin).
    static let turnWindow: TimeInterval = 30 * 60
    /// How often the thread is fetched: while a reply is owed, and otherwise.
    static let replyPoll: Duration = .milliseconds(350)
    static let idlePoll: Duration = .seconds(1.5)

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
        !m.fromUser && derive.wearers.contains(m.id)
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
    /// The Controls item pinned above the composer (YUI-69). Every message sent
    /// while it's on is about it; x, an applied proposal or another agent takes it off.
    var about: TalkItem?

    func talkAbout(_ item: TalkItem?) {
        withAnimation(spring) { about = item }
        if item != nil { goToPage(1) }
    }
    /// The bubble just scrolled to from a reply's chip: it glows for a moment.
    private(set) var flashing: String?

    /// Hold menu Reply: quote this bubble or card in the composer.
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
    private(set) var answers: [String: [String: [String: YLValue]]] = [:] { didSet { waitingCache = nil } }

    /// `awaitingYou`, worked out once per change to the messages or the answers
    /// (YUI-106): the menu button's count read it on every pass of the chat.
    @ObservationIgnored var waitingCache: [ReviewItem]?

    /// Made once, like `emit`: presets read their answer back through it.
    @ObservationIgnored private(set) lazy var ylAnswers = YLAnswers { [weak self] scope, id in self?.answers[scope]?[id] }

    /// Files an answer under the reply that drew it: the newest message with a
    /// component of that id and preset. YL ids repeat across replies (`n1` in
    /// every one), and a later reply's `n1` owns every answer after it lands.
    private func record(id: String, preset: String, value: [String: YLValue]) {
        // A tapped review item in the drawer: no component to file it under,
        // but it stops waiting on the person (the menu button's dot).
        if preset == "menu" {
            guard value["bucket"] == .string("review") else { return }
            menu.markSeen(id)
            if let agentID = agent?.id { menu.store(agentID: agentID) }
            return
        }
        guard let m = pool.last(where: { $0.yl?.components.contains { $0.ylID == id && $0.preset == preset } == true })
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
        // A tick on a page a native agent keeps goes to its runtime quietly (YUI-185): Penny marks the
        // task done in her tables and patches Today and This week. No working row: nothing is owed.
        let quietTick = !e.relays && e.keepsPage && agent?.kind == "hosted"
        #if DEBUG
        // -yuiDemoReplyTaps: a tap the agent would get (an answer, or a deck's done: YUI-186) is answered with -yuiDemoReply too (YUI-145).
        if client == nil, e.relays, e.echo != nil || e.value["done"] == .bool(true), ProcessInfo.processInfo.arguments.contains("-yuiDemoReplyTaps"),
           let reply = ChatStore.demoText("yuiDemoReply") {
            demoAnswer(reply)
            return
        }
        // -yuiDemoReplyTicks: a quiet tick is answered too, with no working row (YUI-185).
        if client == nil, quietTick, ProcessInfo.processInfo.arguments.contains("-yuiDemoReplyTicks"),
           let reply = ChatStore.demoText("yuiDemoReply") {
            demoAnswer(reply, quiet: true)
            return
        }
        #endif
        if client != nil, quietTick { post(id: id, body: e.line, kind: "event", meta: e.meta, answers: false); return }
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
        if let i = messages.firstIndex(where: { $0.id == id }), var yl = messages[i].yl {
            apply(YLNode(op: .show, screen: screen, name: name, line: "show \(name)"), to: &yl)
            withAnimation(spring) { messages[i].yl = yl }
        } else if let i = scoped.firstIndex(where: { $0.id == id }), var yl = scoped[i].yl {
            apply(YLNode(op: .show, screen: screen, name: name, line: "show \(name)"), to: &yl)
            withAnimation(spring) { scoped[i].yl = yl }
        }
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

    /// The drawer's Controls for this agent (YUI-70): over the relay, or on the demo
    /// account a stand-in host. Nil when its host shares no settings.
    func controlsModel() -> ControlsModel? {
        guard let agent, let report = agent.controls else { return nil }
        if let client { return ControlsModel(transport: RelayControls(client: client), agentName: agent.name, report: report) }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-yuiDemoAccount") {
            // A native agent answers as yui-native does (YUI-145).
            let host = agent.kind == "hosted" ? DemoControls(native: agent.name) : Self.demoControls
            return ControlsModel(transport: host, agentName: agent.name, report: report)
        }
        #endif
        return nil
    }
    #if DEBUG
    static let demoControls = DemoControls()
    #endif

    // MARK: Key asks (YUI-34, spec/VAULT.md section 3)

    /// The host's `key_ask` control rows not yet answered on this phone. One shows at a time.
    private func checkKeyAsks(_ client: ThreadClient) async {
        guard keyAsk == nil, let agent, let rows = try? await client.keyAsks() else { return }
        for row in rows.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard case .object(let o)? = row.meta, let req = o["req"]?.string, !KeyAsks.answered(req) else { continue }
            switch KeyAsk.parse(row.meta) {
            case .ask(let ask):
                // A shared agent never spends its client's keys (contract decision 4): a no, nothing shown.
                if agent.isShared { await answerKeyAsk(KeyAnswer(req: ask.req, decision: .deny, provider: ask.provider.rawValue), purpose: ask.purpose); continue }
                keyAsk = ask
                return
            case .refuse(let req, let provider):
                await answerKeyAsk(KeyAnswer(req: req, decision: .deny, provider: provider), purpose: "")
            case .ignore:
                KeyAsks.markAnswered(req)
            }
        }
    }

    /// Sends the `key_answer` control row; the relay writes the one `[yui]` line into the agent's next turn.
    func answerKeyAsk(_ answer: KeyAnswer, purpose: String) async {
        if let client {
            do { try await client.post(id: UUID().uuidString.lowercased(), body: "controls: key_answer", kind: "control", meta: answer.meta) }
            catch { return }  // not sent: the ask stays up, and comes back on the next look
        } else {
            #if DEBUG
            // The demo account has no relay: show the line the relay would hand the agent.
            messages.append(ChatMessage(text: answer.line(purpose: purpose), fromUser: false))
            #endif
        }
        if client != nil { KeyAsks.markAnswered(answer.req) }  // the demo account asks again next launch
        if keyAsk?.req == answer.req { keyAsk = nil }
    }

    #if DEBUG
    /// `-yuiDemoKeyAsk "fal|Draw your agent avatars|5|about 4 images a week"`: a host's ask on the demo account
    /// (provider, the for line, suggested cap, estimate).
    func demoKeyAsk() {
        guard let spec = UserDefaults.standard.string(forKey: "yuiDemoKeyAsk") else { return }
        let p = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard p.count >= 2 else { return }
        var meta: [String: YLValue] = ["v": .number(1), "req": .string("k-demo-" + p[0]), "op": .string("key_ask"),
                                       "provider": .string(p[0]), "for": .string(p[1])]
        if p.count > 2, let cap = Double(p[2]) { meta["cap"] = .number(cap) }
        if p.count > 3 { meta["est"] = .string(p[3]) }
        if case .ask(let ask) = KeyAsk.parse(.object(meta)) { keyAsk = ask }
    }
    #endif

    /// The demo account: show `agent`'s face on the local demo chat, no thread.
    /// It has one local chat; New chat starts a local empty one (YUI-169).
    func demo(_ agent: YuiAgent?) {
        poll?.cancel()
        client = nil
        chatClient = nil
        chatsOn = false
        self.agent = agent
        // Each agent opens on its own page, as a real thread does (attach).
        page = agent.flatMap { pages[$0.id] } ?? 1
        loaded = true
        scoped = []
        chats.reset()
        chatID = nil
        guard let agent else { return }
        keyAsk = nil
        #if DEBUG
        Task { try? await Task.sleep(for: .seconds(1)); demoKeyAsk() }
        #endif
        var items = [ChatInfo(id: "demo-\(agent.id)", isFirst: true, lastAt: ISO8601DateFormatter().string(from: .now))]
        #if DEBUG
        if let fixture = ChatList.debugChats() { items = fixture }
        #endif
        chats.seed(items, open: nil)
        chatID = chats.openID
    }

    /// Switches to `agent`'s thread and keeps it fresh. nil detaches.
    func attach(_ agent: YuiAgent?, account: Account) {
        guard agent?.id != self.agent?.id || client == nil && agent != nil else { return }
        poll?.cancel()
        self.agent = agent
        chatID = nil
        chats.reset()
        chatsOn = true
        chatClient = agent.map { ChatsClient(account: account, agentID: $0.id) }
        client = agent.map { ThreadClient(account: account, agentID: $0.id) }
        self.account = account
        shelf = agent.map { Shelf.load(agentID: $0.id) } ?? Shelf()
        menu = agent.map { AgentMenu.load(agentID: $0.id) } ?? AgentMenu()
        resetThread()
        guard client != nil else { return }
        startPolling()
    }

    /// The parts of a thread that are one chat's: its rows, its answers, the working row.
    /// The agent's shelf, drawer rows and the page it was on stay.
    private func resetThread() {
        keyAsk = nil
        messages = []
        scoped = []
        answers = [:]
        timers.prune()
        reactions = [:]
        reacting = nil
        replying = nil
        about = nil
        stageID = nil
        stageOpen = false
        reading = nil
        page = agent.flatMap { pages[$0.id] } ?? 1
        seen = []
        turnTimes = []
        timed = []
        cursor = nil
        scopeCursor = nil
        scopePass = 0
        waiting = false
        pickedUpAt = nil
        doing = nil
        job = nil
        jobAt = nil
        stoppedRows = []
        stoppedJobs = []
        newestAgentAt = nil
        seenReported = nil
        unsaved = []
        loaded = false
        error = nil
    }

    private func startPolling() {
        poll?.cancel()
        poll = Task { [weak self] in
            var pass = 0
            while !Task.isCancelled {
                await self?.refresh()
                pass += 1
                // The drawer's list stays honest on its own: a reply in another chat moves it up.
                if pass % 4 == 0 { await self?.refreshChats() }
                // A reply is owed: look often, so its first words show soon after they land (YUI-14).
                try? await Task.sleep(for: self?.waiting == true ? Self.replyPoll : Self.idlePoll)
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
        if client == nil, agent != nil, let reply = ChatStore.demoText("yuiDemoReply") {
            let about = screen == nil && !text.hasPrefix("/") ? self.about : nil
            let q = screen == nil && about == nil ? takeReply(for: text) : nil
            withAnimation(Self.sendSpring) {
                messages.append(ChatMessage(text: text, fromUser: true, replyTo: q, fromScreen: screen, about: about?.title))
                demoAnswer(reply)
            }
            return true
        }
        #endif
        guard client != nil, agent != nil, account?.session?.userID != nil else { return false }
        if let screen {
            // About the screen, to this agent: no mention, and a reply quote waits for the chat.
            let m = ChatMessage(id: UUID().uuidString.lowercased(), text: text, fromUser: true, fromScreen: screen)
            withAnimation(Self.sendSpring) {
                messages.append(m)
                post(id: m.id, body: ScreenTalk.body(text, screen: screen), kind: "text", meta: ScreenTalk.meta(nil, screen: screen))
            }
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
        if let about, !text.hasPrefix("/") {
            // About a Controls item (YUI-69): the attach line first; a reply quote waits.
            let m = ChatMessage(id: UUID().uuidString.lowercased(), text: text, fromUser: true, about: about.title)
            withAnimation(Self.sendSpring) {
                messages.append(m)
                post(id: m.id, body: TalkAbout.body(text, about: about), kind: "text", meta: TalkAbout.meta(nil, about: about))
            }
            return true
        }
        let q = takeReply(for: text)
        let m = ChatMessage(id: UUID().uuidString.lowercased(), text: text, fromUser: true, replyTo: q)
        // One transaction for the bubble and the working row (YUI-108): the row's
        // change outside it cost the send frame a second pass over the thread.
        withAnimation(Self.sendSpring) {
            messages.append(m)
            post(id: m.id, body: ReplyQuote.body(text, replyingTo: q), kind: "text", meta: ReplyQuote.meta(nil, replyingTo: q))
        }
        return true
    }

    /// Words and photos. The photos go up first (the outbox holds rows, not
    /// files), then the row goes out like any other. Throws when an upload
    /// fails: nothing is added, the composer keeps everything.
    func send(_ text: String, photos: [ComposerPhoto], mention: YuiAgent? = nil, screen: Int? = nil) async throws {
        guard !photos.isEmpty else { if !send(text, mention: mention, screen: screen) { throw AccountError.signedOut }; return }
        guard client != nil, let agentID = agent?.id, let account else { throw AccountError.signedOut }
        let media = YuiMedia(account: account, agentID: agentID)
        let paths = try await media.upload(photos: photos.map(\.jpeg))
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
    static func userMessage(id: String, body: String, meta: YLValue?, sentAt: Date = .now) -> ChatMessage {
        let paths = Attachments.paths(meta)
        let arrived = Mentions.arrived(meta: meta)
        let words = arrived != nil ? Mentions.arrivedWords(body: body)
            : Mentions.words(body: ReplyQuote.words(body: ScreenTalk.words(body: TalkAbout.words(body: body, meta: meta),
                                                                           meta: meta), meta: meta), meta: meta)
        return ChatMessage(id: id, text: Attachments.caption(body: words, photos: paths.count), fromUser: true,
                           photos: paths.map { .stored($0) }, replyTo: ReplyQuote.from(meta: meta),
                           mentionTo: Mentions.to(meta: meta).map { "To \($0)" } ?? arrived,
                           fromScreen: ScreenTalk.screen(meta: meta), about: TalkAbout.title(meta: meta), sentAt: sentAt)
    }

    /// Into the outbox first (on disk), then out: a dropped network or a killed
    /// app never loses it, and it sends itself when the connection is back.
    /// `answers: false`: this agent won't answer it (a mention goes to another), so no typing dots.
    private func post(id: String = UUID().uuidString.lowercased(), body: String, kind: String, meta: YLValue?,
                      answers: Bool = true) {
        guard client != nil, let agentID = agent?.id, let user = account?.session?.userID else { return }
        seen.insert(id.lowercased())
        if answers { owe() }
        let item = Outbox.Item(id: id.lowercased(), userID: user, agentID: agentID, body: body, kind: kind,
                               meta: meta, queuedAt: .now, chatID: chatID)
        // A chat made on this phone is made on the server with its first words, not before.
        if chats.openIsDraft { commit(item) } else {
            if kind == "text", let chatID { chats.said(in: chatID, sender: "user", body: body, at: ISO8601DateFormatter().string(from: .now)) }
            Outbox.shared.add(item)
        }
    }

    /// The first words in a chat made here: the chat goes to the server, then the words.
    /// A refusal ("update_needed", "limit_reached") takes the words back out and says why.
    private func commit(_ item: Outbox.Item) {
        unsaved.append(item)
        guard !committing, let chatClient, let chat = item.chatID else { return }
        committing = true
        Task { [weak self] in
            var refused: ChatError?
            var reached = true
            do { try await chatClient.insert(id: chat) }
            catch let e as ChatError { refused = e }
            catch { reached = false }  // offline: the outbox makes the chat, then sends
            guard let self else { return }
            committing = false
            let sent = unsaved
            unsaved = []
            // Left for another chat meanwhile: the outbox still makes this one and sends.
            guard chatID == chat || refused == nil else { return }
            if chatID != chat {
                for var it in sent { it.createChat = true; Outbox.shared.add(it) }
                return
            }
            if let refused {
                let ids = Set(sent.map(\.id))
                let words = messages.first { ids.contains($0.id.lowercased()) && $0.fromUser }?.text ?? ""
                withAnimation(spring) { messages.removeAll { ids.contains($0.id.lowercased()) } }
                waiting = false
                refusal = (words, refused.spoken)
                chats.note = refused.spoken
                return
            }
            let last = sent.last { $0.kind == "text" }?.body
            chats.saveDraft(lastBody: last)
            if let saved = chats.items.first(where: { $0.id == chat }) { justSaved[chat] = saved }
            for var it in sent {
                if !reached { it.createChat = true }
                Outbox.shared.add(it)
            }
        }
    }

    /// A reply is owed: the working row shows and its seconds start.
    private func owe() {
        owed += 1
        waiting = true
        waitingSince = .now
        pickedUpAt = nil
        doing = nil
    }

    // MARK: Stop (YUI-190)

    /// The person's Stop: a control row from them with op stop.
    static func isStop(_ row: ThreadRow) -> Bool {
        row.kind == "control" && row.sender == "user" && row.meta?.object?["op"]?.string == "stop"
    }

    /// True when an agent row answers something a Stop ended: its meta.turn names a stopped
    /// row, or it is a stopped job's answer (`meta.native.meal`).
    static func answers(_ meta: YLValue?, rows: Set<String>, jobs: Set<String>) -> Bool {
        let o = meta?.object
        if !rows.isEmpty, let turn = o?["turn"]?.array,
           turn.contains(where: { $0.string.map { rows.contains($0.lowercased()) } ?? false }) { return true }
        if !jobs.isEmpty, let job = o?["native"]?.object?["meal"]?.string, jobs.contains(job) { return true }
        return false
    }

    /// A job behind an answer (YUI-103): the agent is on it from its "working on it"
    /// (`meta.native.queued`) until the job's own answer, or `jobWindow` at most.
    private func trackJob(_ row: ThreadRow) {
        guard let n = row.meta?.object?["native"]?.object, let id = n["meal"]?.string else { return }
        if n["queued"]?.bool == true {
            guard let at = YuiTime.date(row.createdAt), Date.now.timeIntervalSince(at) < Self.jobWindow else { return }
            job = id
            jobAt = at
        } else if job == id {
            job = nil
            jobAt = nil
        }
    }

    /// Stop: the mic's stop square while the agent works. The phone stops waiting at once and
    /// the record says Stopped. The host reads a control row (never a turn): it ends the turn
    /// or drops the job, with nothing written. Its late answers never land here.
    func stop() {
        guard working else { return }
        let id = UUID().uuidString.lowercased()
        #if DEBUG
        if client == nil {
            demoTurn?.cancel()
            demoTurn = nil
            seen.insert(id)
            halt(note: id)
            return
        }
        #endif
        guard client != nil, let agentID = agent?.id, let user = account?.session?.userID else { return }
        seen.insert(id)
        halt(note: id)
        Outbox.shared.add(.init(id: id, userID: user, agentID: agentID, body: "stop", kind: "control",
                                meta: .object(["op": .string("stop")]), queuedAt: .now, chatID: chatID))
    }

    /// A Stop, sent from here or read back from the thread (another phone, a reopen): what
    /// was running is over, answers to it are dropped, and a quiet Stopped goes in the record.
    private func halt(note id: String) {
        let from = messages.lastIndex { !$0.fromUser && !$0.stopped }.map { $0 + 1 } ?? 0
        for m in messages[from...] where m.fromUser { stoppedRows.insert(m.rowID.lowercased()) }
        if let job { stoppedJobs.insert(job) }
        waiting = false
        pickedUpAt = nil
        doing = nil
        job = nil
        jobAt = nil
        guard !messages.contains(where: { $0.id == id }) else { return }
        withAnimation(loaded ? spring : nil) {
            messages.append(ChatMessage(id: id, text: "Stopped", fromUser: false, stopped: true))
        }
    }

    /// Messages still in the outbox for this thread, after the history: they
    /// were sent last. Shown as not sent yet until they land.
    private func restorePending() {
        guard let agentID = agent?.id else { return }
        var new: [ChatMessage] = []
        for item in Outbox.shared.pending(agentID: agentID, chatID: chatID) where seen.insert(item.id).inserted {
            if item.kind == "control" { continue }  // a Stop on its way (YUI-190): its note is already here
            if item.kind == "event" {
                record(meta: item.meta)
                applyReaction(meta: item.meta)
                if let echo = item.meta?.object?["echo"]?.string { new.append(ChatMessage(id: item.id, text: echo, fromUser: true, sentAt: item.queuedAt)) }
            } else {
                new.append(Self.userMessage(id: item.id, body: item.body, meta: item.meta, sentAt: item.queuedAt))
            }
        }
        guard !new.isEmpty else { return }
        messages.append(contentsOf: new)
        waiting = true
        waitingSince = .now
        pickedUpAt = nil
        doing = nil
    }

    func refresh() async {
        guard let agentID = agent?.id, client != nil else { return }
        let first = !loaded
        do {
            // Which chat: the list comes first, and the thread is that chat's rows (YUI-169).
            if chatsOn, chatID == nil || !chats.loaded { try await resolveChat() }
            // A chat made here with nothing said in it is not on the server: nothing to read.
            if chats.openIsDraft { loaded = true; return }
            guard let client, agent?.id == agentID else { return }
            let chat = chatID
            // Overlap the last poll by 10 s: a row can commit after a later one.
            let rows = try await client.fetch(since: cursor.map { YuiTime.before($0, seconds: 10) })
            // The agent's screens said in its other chats: with the first load, then now and then.
            var scopedRows: [ThreadRow] = []
            scopePass += 1
            if chat != nil, first || scopePass % 3 == 0 {
                scopedRows = (try? await client.fetchScoped(since: scopeCursor.map { YuiTime.before($0, seconds: 10) })) ?? []
            }
            // arrive_drawn (YUI-102) starts when the rows are here and ends on the frame that shows them.
            let arrived = CACurrentMediaTime()
            guard agent?.id == agentID, chatID == chat else { return }
            keyPass += 1
            if first || keyPass % 3 == 0 { await checkKeyAsks(client) }
            for row in scopedRows { addScoped(row) }
            if let last = scopedRows.last?.createdAt, last > (scopeCursor ?? "") { scopeCursor = last }
            var landed = false
            for row in rows where add(row) && row.sender == "agent" { landed = true }
            if landed, !first { Perf.shared.span(.arriveDrawn, from: arrived) }
            if first { resume(rows) }
            if let jobAt, Date.now.timeIntervalSince(jobAt) > Self.jobWindow { job = nil; self.jobAt = nil }
            if let last = rows.last?.createdAt, last > (cursor ?? "") { cursor = last }
            loaded = true
            if first { Perf.shared.threadShown() }
            // No time limit on a turn: the dots stay until the reply comes or the
            // host says the turn is over. Asleep or offline agents get their own note.
            // About once a second: the host writes the agent's `doing` onto this row (YUI-63).
            if waiting, Date.now.timeIntervalSince(turnCheckedAt) > Self.turnCheck,
               Outbox.shared.pending(agentID: agentID, chatID: chat).isEmpty {
                turnCheckedAt = .now
                if let row = try await client.newestFromUser(), agent?.id == agentID, chatID == chat, waiting { track(row) }
            }
            noteRead()
        } catch {
            loaded = true
            if first { Perf.shared.cancel(.threadOpen); Perf.shared.cancel(.threadOpenCold) }
        }
        if first { restorePending() }
    }

    /// Thread rows, oldest first, the way a poll adds them. Tests and `-yuiThreadRows` use it.
    func load(_ rows: [ThreadRow]) {
        for row in rows { _ = add(row) }
        resume(rows)
    }

    #if DEBUG
    /// The demo account with `-yuiThreadRows` (YUI-101): opening a thread loads the
    /// rows again, from nothing, and is timed like a real open, the network aside.
    func reopen(_ rows: [ThreadRow]) {
        messages = []
        seen = []
        turnTimes = []
        timed = []
        answers = [:]
        reactions = [:]
        reacting = nil
        replying = nil
        about = nil
        stageID = nil
        stageOpen = false
        loaded = false
        load(rows)
        loaded = true
        Perf.shared.threadShown()
    }
    #endif

    /// How often a turn in progress is looked at (pickup, `doing`, finished).
    static let turnCheck: TimeInterval = 0.9

    /// A row's `doing` as the working row draws it: words, a step or both.
    /// Anything else (a host bug, a step past the end) is the working word.
    static func doing(_ v: YLValue?) -> YLDoing? {
        guard let o = v?.object else { return nil }
        let text = o["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        var d = YLDoing(text: text?.isEmpty == false ? text : nil)
        if let n = o["step"]?.number, let m = o["of"]?.number, m >= 1, n >= 0, n <= m {
            d.step = Int(n)
            d.of = Int(m)
        }
        return d.text == nil && d.step == nil ? nil : d
    }

    private func setDoing(_ d: YLDoing?) {
        if d != doing { doing = d }
    }

    /// A thread opened mid-turn: its newest row is the person's and the agent
    /// has not finished it, so the working note picks up where it was.
    private func resume(_ rows: [ThreadRow], now: Date = .now) {
        guard let last = rows.last, last.sender == "user", last.kind != "control", last.handledAt == nil,
              let sent = YuiTime.date(last.createdAt), now.timeIntervalSince(sent) < Self.turnWindow else { return }
        waiting = true
        waitingSince = sent
        pickedUpAt = last.deliveredAt.flatMap(YuiTime.date)
        doing = pickedUpAt == nil ? nil : Self.doing(last.doing)
    }

    /// How far the turn on the person's newest row has got. Finished with no
    /// reply after a grace period (a command, a turn that errored): stop waiting.
    private func track(_ row: ThreadRow, now: Date = .now) {
        pickedUpAt = row.deliveredAt.flatMap(YuiTime.date) ?? pickedUpAt
        // Words for the working row only once the host has the row: a queued
        // row has none of its own yet.
        if row.deliveredAt != nil { setDoing(Self.doing(row.doing)) }
        time(row)
        if let done = row.handledAt.flatMap(YuiTime.date), now.timeIntervalSince(done) > 20 { waiting = false }
    }

    /// A finished turn on one of the person's rows: keep how long it took.
    /// Once per row; a turn over the host's 30 minutes is not a real one.
    private func time(_ row: ThreadRow) {
        guard row.sender == "user", !timed.contains(row.id.lowercased()),
              let start = row.deliveredAt.flatMap(YuiTime.date),
              let done = row.handledAt.flatMap(YuiTime.date) else { return }
        timed.insert(row.id.lowercased())
        let took = done.timeIntervalSince(start)
        guard took >= 1, took <= Self.turnWindow else { return }
        turnTimes.append(took)
        if turnTimes.count > Self.turnTimesKept { turnTimes.removeFirst(turnTimes.count - Self.turnTimesKept) }
    }

    /// True when the row was new.
    @discardableResult
    private func add(_ row: ThreadRow) -> Bool {
        let id = row.id.lowercased()
        if row.kind == "control" {
            // Settings traffic (YUI-70) never shows; the person's Stop (YUI-190) is a quiet note.
            guard Self.isStop(row), seen.insert(id).inserted else { return false }
            halt(note: id)
            return true
        }
        // Polls overlap: only a row not seen before can end the wait.
        guard seen.insert(id).inserted else { return false }
        if row.sender == "agent", row.kind == "text", row.createdAt > (newestAgentAt ?? "") { newestAgentAt = row.createdAt }
        if loaded, row.kind == "text", let chatID { chats.said(in: chatID, sender: row.sender, body: row.body, at: row.createdAt) }
        // An answer to what the person stopped (YUI-190): it never lands.
        if row.sender == "agent", Self.answers(row.meta, rows: stoppedRows, jobs: stoppedJobs) { return false }
        time(row)
        if row.sender == "agent", Mentions.from(meta: row.meta) == nil { trackJob(row) }
        // Another agent's answer copied in (YUI-44) doesn't end this agent's turn.
        if row.sender == "agent", Mentions.from(meta: row.meta) == nil { waiting = false; pickedUpAt = nil; doing = nil }
        if row.sender == "agent", let done = TalkAbout.applied(meta: row.meta), done == about?.id {
            withAnimation(spring) { about = nil }  // its proposal was applied (YUI-69)
        }
        var new: [ChatMessage] = []
        let sent = YuiTime.date(row.createdAt) ?? .now
        /// A live reply's lines: they can bring a page forward.
        var live: [YLNode] = []
        if row.sender == "user" {
            if row.kind == "event" {
                record(meta: row.meta)
                applyReaction(meta: row.meta)
                if let echo = row.meta?.object?["echo"]?.string { new.append(ChatMessage(id: id, text: echo, fromUser: true, sentAt: sent)) }
            } else {
                new.append(Self.userMessage(id: id, body: row.body, meta: row.meta, sentAt: sent))
            }
        } else if let from = Mentions.from(meta: row.meta) {
            // Another agent's answer to a mention (YUI-44): its words here, in its look.
            // Its screens stay in its own thread, where their taps reach it.
            if let r = row.reaction { reactions[id] = r }
            for (i, seg) in YuiFence.split(row.body).enumerated() {
                switch seg {
                case .text(let t): new.append(ChatMessage(id: "\(id)#\(i)", text: t, fromUser: false, from: from, sentAt: sent))
                case .yl: new.append(ChatMessage(id: "\(id)#\(i)", text: "Sent a screen. It's in \(from.name)'s thread.",
                                                 fromUser: false, from: from, sentAt: sent))
                }
            }
        } else {
            if let r = row.reaction { reactions[id] = r }
            // Reminders the agent keeps (YUI-185): the phone schedules them as local notifications.
            if let a = agent { Reminders.shared.take(meta: row.meta, agent: a.id, name: a.name, createdAt: row.createdAt, live: loaded) }
            let hello = row.meta?.object?["native"]?.string == "first"
            let home = row.meta?.object?["native"]?.string == "home"
            for (i, seg) in YuiFence.split(row.body).enumerated() {
                switch seg {
                case .text(let t): new.append(ChatMessage(id: "\(id)#\(i)", text: t, fromUser: false, hello: hello, sentAt: sent))
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
                        } else if node.op == .patch, let t = node.target, !screen.has(t),
                                  let j = scoped.lastIndex(where: { $0.yl?.has(t) == true }) {
                            // A patch for a screen the agent drew in another chat (YUI-169).
                            scoped[j].yl?.apply(node)
                            if known[t] != nil { shelve(node, at: at) }
                        } else {
                            apply(node, to: &screen)
                        }
                    }
                    file(screen.shelfOps, at: at)
                    fileMenu(screen.menuLines, at: at)
                    if let agentID = agent?.id { for look in screen.looks { onLook?(agentID, look, row.createdAt) } }
                    new.append(ChatMessage(id: "\(id)#\(i)", text: "", fromUser: false, yl: screen, hello: hello, home: home, sentAt: sent))
                    // The home fills its pages quietly: it never brings one forward (YUI-168).
                    if loaded, !home { live += nodes }
                }
            }
        }
        guard !new.isEmpty else { return false }
        withAnimation(loaded ? spring : nil) { messages.append(contentsOf: new) }
        // Live replies can take the stage; history loading on open never does.
        if loaded { for m in new where m.yl != nil && !m.home { stageUpdate(m.id, before: nil) } }
        pageUpdate(live)
        handOff(live, at: row.createdAt)
        return true
    }

    /// A hand-off (YUI-144): a live reply's `card ... url=yui://agent/<handle>` takes the
    /// person to that agent's thread, a beat after the card lands so they read who and why.
    /// History never jumps: only a reply that arrives while this thread is open, and fresh.
    private func handOff(_ live: [YLNode], at createdAt: String) {
        guard let url = Self.handOffLink(live), let from = agent?.id,
              Date.now.timeIntervalSince(YuiTime.date(createdAt) ?? .now) < 120 else { return }
        var wait = 1.4
        #if DEBUG
        // -yuiDemoHandoffAfter <seconds>: a longer beat, so a test can photograph the card first.
        if UserDefaults.standard.object(forKey: "yuiDemoHandoffAfter") != nil { wait = UserDefaults.standard.double(forKey: "yuiDemoHandoffAfter") }
        #endif
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard self?.agent?.id == from else { return }
            PushCenter.shared.open(url)
        }
    }

    /// The first hand-off card's link in these lines, if any.
    static func handOffLink(_ nodes: [YLNode]) -> URL? {
        for n in nodes where n.op == .add && n.preset == "card" {
            if let raw = n.props?["url"]?.string, let u = URL(string: raw), PushCenter.isHandOff(u) { return u }
        }
        return nil
    }

    #if DEBUG
    /// A demo launch arg's text: `-yuiDemoReply <lines>`, or `-yuiDemoReplyFile <path>` for a
    /// runtime reply as it is, apostrophes and all (a launch arg is read as a plist, where `'` quotes).
    /// A `.json` file is an array of replies, one per turn, the last one kept (YUI-183: Plan my
    /// meals, then its Send, then a swap, each answered as the runtime answers it).
    nonisolated static func demoText(_ key: String) -> String? { demoTurnRow(key)?.body }

    /// A demo turn as the row it becomes: its words, and a `.json` file's `{body, meta}` entry's meta
    /// (YUI-185: Penny's plan lands with `meta.native.reminders`, as the runtime writes it).
    nonisolated static func demoTurnRow(_ key: String) -> (body: String, meta: YLValue?)? {
        let d = UserDefaults.standard
        if let text = d.string(forKey: key) { return (text, nil) }
        guard let path = d.string(forKey: key + "File"), let data = FileManager.default.contents(atPath: path) else { return nil }
        guard path.hasSuffix(".json") else { return String(data: data, encoding: .utf8).map { ($0, nil) } }
        guard let turns = try? JSONDecoder().decode([YLValue].self, from: data), !turns.isEmpty else { return nil }
        let turn = turns[min(demoTurn.withLock { $0 }, turns.count - 1)]
        if let body = turn.string { return (body, nil) }
        guard let body = turn.object?["body"]?.string else { return nil }
        return (body, turn.object?["meta"])
    }
    /// Which of a `.json` file's replies is next: each demo answer moves it on.
    nonisolated static let demoTurn = Mutex(0)

    /// The demo account's scripted answer (-yuiDemoReply), after a working row. A reply
    /// with a ```yui fence lands as a real agent row does (YUI-141: a native agent's answer, verbatim).
    func demoAnswer(_ reply: String, quiet: Bool = false) {
        if !quiet { owe() }
        let meta = Self.demoTurnRow("yuiDemoReply")?.meta
        Self.demoTurn.withLock { $0 += 1 }
        // -yuiDemoPickupAfter / -yuiDemoReplyAfter <seconds>: stretch the turn so the working row can be watched (YUI-63).
        let d = UserDefaults.standard
        let pickup = d.object(forKey: "yuiDemoPickupAfter") == nil ? 0.5 : d.double(forKey: "yuiDemoPickupAfter")
        let answer = max(pickup, d.object(forKey: "yuiDemoReplyAfter") == nil ? 1.6 : d.double(forKey: "yuiDemoReplyAfter"))
        // -yuiDemoDoing "Reading your calendar 1/3|Checking the weather 2/3|doing off": what the
        // agent says it is doing (YUI-63), spread evenly between pickup and the answer.
        let steps = (d.string(forKey: "yuiDemoDoing") ?? "").split(separator: "|").map {
            YuiLines.doing(of: YuiLines.parse("doing \($0)"))
        }
        demoTurn = Task {
            try? await Task.sleep(for: .seconds(pickup))
            guard !Task.isCancelled else { return }
            if !quiet { pickedUpAt = .now }
            let gap = (answer - pickup) / Double(steps.count + 1)
            for step in steps {
                try? await Task.sleep(for: .seconds(gap))
                guard !Task.isCancelled else { return }
                setDoing(step)
            }
            try? await Task.sleep(for: .seconds(steps.isEmpty ? answer - pickup : gap))
            guard !Task.isCancelled else { return }  // stopped (YUI-190): no late reply
            waiting = false
            pickedUpAt = nil
            doing = nil
            let text = reply.replacingOccurrences(of: "\\n", with: "\n")
            if text.contains("```yui") {
                // A line of `@@` between two replies sends them as separate messages (YUI-199b: a turn of several).
                for part in text.components(separatedBy: "\n@@\n") {
                    add(ThreadRow(id: UUID().uuidString.lowercased(), sender: "agent", body: part, kind: "text", meta: meta,
                                  createdAt: ISO8601DateFormatter().string(from: .now)))
                }
            } else {
                stream(text)
            }
        }
    }
    #endif

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
        // `theme app` is an offer for Yui itself: a card, never this agent's look.
        for n in nodes where n.op == .theme && n.props?["scope"]?.string != "app" {
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


// MARK: Chats (YUI-169, spec yuigui/spec/CHATS.md)

extension ChatStore {
    /// The list first, then the chat the thread opens on: a push's, the last one open with this
    /// agent, else the newest. An agent with none opens an empty one. A server with no chats
    /// yet answers 404: the thread stays the agent's, as before. The list is kept even when a chat
    /// is already open by the time it arrives, so the drawer is never left without it.
    fileprivate func resolveChat() async throws {
        guard let chatClient, let agentID = agent?.id else { return }
        let page: [ChatInfo]
        do {
            page = try await chatClient.list()
        } catch AccountError.server(let code) where code == "http_404" {
            chatsOn = false
            return
        }
        guard agent?.id == agentID else { return }
        chats.apply(page: page, keep: Array(justSaved.values))
        // A chat was already opened before the list came (New chat, a push): the list still fills in.
        guard chatID == nil else { return }
        let known = Set(page.map(\.id))
        let pick = wantedChat ?? lastChat[agentID].flatMap { known.contains($0) ? $0 : nil } ?? page.first?.id
        wantedChat = nil
        if let pick {
            adopt(pick)
        } else {
            adopt(chats.startNew().id)
        }
    }

    /// This chat is the thread now: its rows are what the client reads and posts.
    private func adopt(_ id: String) {
        guard let account, let agentID = agent?.id else { return }
        chatID = id
        chats.select(id)
        lastChat[agentID] = id
        client = ThreadClient(account: account, agentID: agentID, chatID: id)
    }

    /// The list from the server again: a reply in another chat moves it up, a delete or
    /// rename on another phone shows, and an open chat gone elsewhere hands over to the next.
    func refreshChats() async {
        guard chatsOn, let chatClient, let agentID = agent?.id, chats.loaded, watching else { return }
        guard let page = try? await chatClient.list(), agent?.id == agentID else { return }
        for c in page { justSaved[c.id] = nil }
        chats.apply(page: page, keep: Array(justSaved.values))
        if let id = chatID, !chats.openIsDraft, !chats.more, !chats.items.contains(where: { $0.id == id }) {
            leaveDeleted()
        }
    }

    /// The open chat was deleted on another phone: the next newest opens, or a new one.
    private func leaveDeleted() {
        if let next = chats.items.first?.id { switchChat(to: next) } else { switchChat(to: chats.startNew().id) }
    }

    /// The next page of older chats, as the list scrolls.
    func loadMoreChats() async {
        guard chatsOn, chats.more, let chatClient, let agentID = agent?.id else { return }
        guard let older = try? await chatClient.list(offset: chats.savedCount), agent?.id == agentID else { return }
        chats.apply(older: older)
    }

    /// New chat: an empty one, saved when something is said in it. Already in an empty one, or
    /// tapping twice: that same chat. Nothing on the server until then.
    func newChat() {
        guard agent != nil else { return }
        if chats.openIsDraft || (chatID != nil && loaded && messages.isEmpty && !waiting) { return }
        let d = chats.startNew()
        switchChat(to: d.id)
    }

    /// The chat a push came from: opened even when the first page of the list lacks it.
    func openPushed(_ id: String) {
        let id = id.lowercased()
        guard chatsOn || client == nil, id != chatID else { return }
        switchChat(to: id)
    }

    /// A chat from the list.
    func openChat(_ id: String) {
        guard id != chatID, chats.items.contains(where: { $0.id == id }) else { return }
        switchChat(to: id)
    }

    private func switchChat(to id: String) {
        guard id != chatID else { return }
        let demoing = client == nil
        if demoing, let old = chatID { demoThreads[old] = messages }
        poll?.cancel()
        resetThread()
        chatID = id
        chats.select(id)
        chats.note = nil
        if let agentID = agent?.id { lastChat[agentID] = id }
        if demoing {
            messages = demoThreads[id] ?? []
            loaded = true
            return
        }
        guard let account, let agentID = agent?.id else { return }
        client = ThreadClient(account: account, agentID: agentID, chatID: id)
        if chats.openIsDraft { loaded = true }
        startPolling()
    }

    /// Rename in place: shown at once, then saved. A renamed title never changes on its own again.
    func renameChat(_ id: String, to raw: String) {
        guard let title = Chats.validTitle(raw) else { return }
        chats.rename(id, to: title)
        guard client != nil, let chatClient else { return }
        Task { [weak self] in
            do { try await chatClient.rename(id, to: title) }
            catch { self?.chats.note = "Couldn't rename that right now. Try again in a moment."; await self?.refreshChats() }
        }
    }

    /// What Delete does for this chat: it goes, or (an agent's only chat) it is cleared.
    var deletePlan: ChatDelete { Chats.deletePlan(saved: chats.savedCount) }

    /// Delete or clear, after the person said yes. Deleting the open chat opens the next newest.
    func deleteChat(_ id: String) async {
        let plan = deletePlan
        let next = Chats.openAfterDeleting(id, open: chatID, list: chats.items)
        if client != nil, let chatClient {
            do {
                switch plan {
                case .clear: try await chatClient.clear(id)
                case .delete: try await chatClient.delete(id)
                }
            } catch ChatError.lastChat {
                // The list said two, the server says one: clear it instead.
                do { try await chatClient.clear(id) } catch { chats.note = ChatError.other("").spoken; return }
                clearedLocally(id)
                return
            } catch {
                chats.note = (error as? ChatError)?.spoken ?? ChatError.other("").spoken
                return
            }
        }
        switch plan {
        case .clear: clearedLocally(id)
        case .delete:
            chats.remove(id)
            justSaved[id] = nil
            demoThreads[id] = nil
            if chatID == id {
                if let next { switchChat(to: next) } else { switchChat(to: chats.startNew().id) }
            }
        }
    }

    private func clearedLocally(_ id: String) {
        chats.cleared(id)
        demoThreads[id] = nil
        guard chatID == id else { return }
        withAnimation(spring) { messages = [] }
        waiting = false
        pickedUpAt = nil
        doing = nil
        job = nil
        newestAgentAt = nil
    }

    /// The person is reading this chat and its newest agent row is in: seen_at moves there, so the
    /// coral dot goes on every phone. The first look at a chat with no dot needs no call.
    fileprivate func noteRead() {
        guard watching, let chat = chatID, !chats.openIsDraft, let at = newestAgentAt, at != seenReported else { return }
        let known = chats.items.first { $0.id == chat }
        if seenReported == nil, known?.unread != true { seenReported = at; return }
        seenReported = at
        chats.markSeen(chat, at: at)
        guard let chatClient else { return }
        Task { try? await chatClient.seen(chat, at: at) }
    }

    /// An agent row from another chat: only what belongs to the agent (screens, patches, saves,
    /// drawer lines) is kept, out of the thread.
    func addScoped(_ row: ThreadRow) {
        let id = row.id.lowercased()
        guard row.kind != "control", row.sender == "agent", Mentions.from(meta: row.meta) == nil,
              seen.insert(id).inserted else { return }
        var new: [ChatMessage] = []
        for (i, seg) in YuiFence.split(row.body).enumerated() {
            guard case .yl(let y) = seg else { continue }
            var screen = YLScreen()
            let known = lastingIds
            let at = YuiTime.date(row.createdAt) ?? .now
            for node in YuiLines.parse(y, known: known) {
                clearPage(node)
                if node.op == .patch, let t = node.target, !screen.has(t),
                   let j = scoped.lastIndex(where: { $0.yl?.has(t) == true }) {
                    scoped[j].yl?.apply(node)
                    if known[t] != nil { shelve(node, at: at) }
                } else if node.op == .patch, let t = node.target, !screen.has(t),
                          let j = messages.lastIndex(where: { $0.yl?.has(t) == true }) {
                    messages[j].yl?.apply(node)
                    if known[t] != nil { shelve(node, at: at) }
                } else {
                    apply(node, to: &screen)
                }
            }
            file(screen.shelfOps, at: at)
            fileMenu(screen.menuLines, at: at)
            new.append(ChatMessage(id: "\(id)#\(i)", text: "", fromUser: false, yl: screen, sentAt: at))
        }
        guard !new.isEmpty else { return }
        scoped.append(contentsOf: new)
    }
}
