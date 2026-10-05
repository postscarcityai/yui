import SwiftUI
import YuiLines

// Stage first (YUI-119 step 2, spec yuigui/spec/YL.md section 5, Stage first;
// mock www.yuigui.com/playground?demo=stage-first). Chris, TestFlight
// AJq7CcQS8fyM: "As I send my first chat instead of seeing the three dots, I'm
// just immediately taken into a full screen experience ... The chat is just a
// record." Yui lives here: a send puts the stage up at once with the working
// state, the reply plays as chunks (a line and a picture each), the questions
// come last on one screen with one Send, and the chat underneath keeps it all.
// The bottom bar is BarButtons (YUI-121, BottomBar.swift), the top bar TopBar.swift (YUI-122).

/// Where the stage is: up or in the chat, which turn, which chunk.
@Observable @MainActor
final class StageFirstModel {
    static let key = "yuiStageFirst"
    /// Which of the bottom bar's buttons show (Settings > Full screen). One of mic and T always stays.
    static let micKey = "yuiStageMic", typeKey = "yuiStageType", attachKey = "yuiStageAttach"

    /// A launch with `-yui…` arguments is a UI test or a screenshot run: those keep the
    /// chat first unless they pass `-yuiStageFirst YES`. A person's launch has none.
    static func enabled(stored: Bool) -> Bool {
        let args = ProcessInfo.processInfo.arguments
        if args.contains(where: { $0.hasPrefix("-yui") }), !args.contains("-" + key) { return false }
        return stored
    }

    /// The stage is up (the chat is under it).
    var open = true
    /// The person's message the turn on show started with. Nil: the greeting.
    var ask: String?
    /// The chunk on show. `chunks.count` is the questions.
    var at = 0
    /// The T field is out.
    var typing = false
    /// Answers given on the questions screen, by question, waiting for Send. Only while the
    /// model lives: a question drawn again (a page back and on, home, another agent, a relaunch)
    /// hands back what the phone kept of it (`AnswerDrafts`, feedback NOTE-19357).
    var answers: [String: YLEvent] = [:]
    /// Turns whose questions went.
    var sent: Set<String> = []
    /// Picks waiting on the last page (YUI-208): set while the questions are up with something picked. Words
    /// the person types or says then go with them as one answer; nil means the words go alone.
    @ObservationIgnored var bundle: ((String) -> Bool)?
    /// What the page on show can fill from spoken words (t_7d424132).
    let pageVoice = PageVoice()
    /// Rows in the record when it was last looked at: the count on its button is the rest.
    var seen = 0
    /// The last move went back a chunk: the next one comes on from the other side (YUI-120).
    var back = false
    /// Counts the times the stage opened on something said: the wash from the mic.
    var opened = 0
    /// The reply just came in: the found beat plays until then, before the first chunk.
    var foundUntil: Date?

    /// The agent's hello on show (YUI-167): the id of its first message. Nil: not playing it.
    var hello: String?

    /// What the stage plays: the turn the person started, the hello, or nothing (the greeting).
    func turn(_ messages: [ChatMessage]) -> StageTurn? {
        if let ask { return StageChunks.turn(messages, ask: ask) }
        if hello != nil { return StageChunks.hello(messages, from: hello) }
        return nil
    }

    /// Hellos already played, by their first message's id. On the phone for a person;
    /// in memory only for the demo account, so every test launch meets the crew fresh.
    static let seenKey = "yuiHelloSeen"
    var memory: Set<String>? = ProcessInfo.processInfo.arguments.contains("-yuiDemoAccount") ? [] : nil
    private var met: Set<String> {
        get { memory ?? Self.loadSeen() }
        set {
            if memory != nil { memory = newValue } else { Self.saveSeen(newValue) }
        }
    }

    /// A plain [String], never a slice: UserDefaults takes property-list types only and
    /// aborts on anything else (0.5.0 build 278 crashed on switching agents, then on launch).
    static func saveSeen(_ ids: Set<String>, to defaults: UserDefaults = .standard) {
        defaults.set(Array(ids.sorted().suffix(200)), forKey: seenKey)
    }

    static func loadSeen(from defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: seenKey) ?? [])
    }

    /// A thread opens (or its hello just arrived): an agent's hello nobody has seen plays on
    /// the stage from its first chunk, instead of the blank greeting (Chris on build 244:
    /// "when I got to his screen for the first time, all it showed me was a blank screen").
    /// Once only: after that the thread opens as it always does. A thread the person
    /// already talked in never plays it. True when it started.
    @discardableResult
    func meet(_ messages: [ChatMessage], agent: String?) -> Bool {
        guard ask == nil, hello == nil, agent != nil, !messages.contains(where: \.fromUser),
              let first = messages.first(where: \.hello), !met.contains(first.id),
              StageChunks.hello(messages).pages > 0 else { return false }
        met.insert(first.id)
        hello = first.id
        at = 0
        back = false
        typing = false
        answers = [:]
        open = true
        opened += 1
        return true
    }

    /// The person said something: the stage comes up on it, working.
    func follow(_ ask: String?) {
        guard let ask else { return }
        hello = nil
        self.ask = ask
        at = 0
        back = false
        foundUntil = nil
        typing = false
        open = true
        opened += 1
    }

    /// Back to the agent's home (YUI-195): the answer goes down, nothing is sent and nothing is
    /// lost. The person's answers so far stay, and the reply's pill in the chat plays it again.
    func dismiss() {
        hello = nil
        ask = nil
        at = 0
        back = false
        typing = false
        foundUntil = nil
    }

    /// A new thread: the greeting.
    func home() {
        ask = nil
        hello = nil
        at = 0
        typing = false
        answers = [:]
    }

    /// Opens the stage at the chunk a reply in the record drew. False when the
    /// reply has no turn to play in (nothing the person said came before it).
    /// `toPlan` (YUI-225, Open on a card): a hello that ends in a first plan nobody has built yet
    /// lands on its questions, not on the first line.
    func show(reply id: String, in messages: [ChatMessage], toPlan: Bool = false) -> Bool {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return false }
        let start = messages[..<i].lastIndex(where: \.fromUser)
        // The hello's pill, before anything was said, plays the hello again (YUI-167).
        // Nothing said before it and no hello (a reply from another channel into a thread nobody spoke in): it plays from itself.
        let lead = start == nil && !messages[i].hello ? id : nil
        let t = start.map { StageChunks.turn(messages, ask: messages[$0].id) } ?? StageChunks.hello(messages, from: lead)
        guard let at = t.chunks.firstIndex(where: { $0.scopes.contains(id) })
                ?? (t.questions.contains { $0.scope == id } ? t.chunks.count : nil) else { return false }
        ask = start.map { messages[$0].id }
        hello = start == nil ? (lead ?? messages.first(where: \.hello)?.id) : nil
        // Nothing said yet means the first plan is still to build; once they sent it, Open is the agent's home.
        self.at = toPlan && start == nil && t.plan != nil && !messages.contains(where: \.fromUser) ? max(0, t.pages - 1) : at
        typing = false
        open = true
        return true
    }
}

/// What the stage can ask ChatView to do.
struct StageActions {
    /// The hamburger: the drawer, with Settings in it (YUI-122).
    var menu: () -> Void
    var pick: (String) -> Void
    /// Add agent, from the picker. Nil for an invited account.
    var add: (() -> Void)? = nil
    var manage: () -> Void
    var record: () -> Void
    /// New chat (YUI-169): the round button top right.
    var newChat: () -> Void = {}
    /// The name and the chat's title: the drawer with the chats.
    var openDrawer: () -> Void = {}
    /// + T and the mic (YUI-121). Its `type` is the stage's own; the view opens the field.
    var bar: BarActions
    var send: () -> Void
    var removePhoto: (ComposerPhoto) -> Void
    /// That screen (1 the answer or the home): a swipe, a chip or VoiceOver paging.
    var goScreen: (Int) -> Void = { _ in }
    /// A drag right on the answer pulls the drawer out with the finger (as on the chat, YUI-54),
    /// then lets it settle open or shut from where the finger let go and how fast.
    var drawerDrag: (CGFloat) -> Void = { _ in }
    var drawerSettle: (CGFloat, CGFloat) -> Void = { _, _ in }
    /// Error's Try again: the person's words go again.
    var retry: (String) -> Void = { _ in }
}

/// The mic as the stage shows it.
struct StageMic: Equatable {
    /// Hands-free is on (listening, sending, waiting for the reply).
    var on = false
    /// The mic is open or its words are settling.
    var live = false
    /// Talking while the finger holds the mic: let go sends.
    var held = false
    /// Held and slid to the trash: let go throws the words away.
    var armed = false
    /// Held and slid up onto the lock: let go keeps it recording, hands-free.
    var locking = false
    var words = ""
    /// Why it stopped, in plain words.
    var note: String?
}

struct StageFirstView: View {
    let store: ChatStore
    let model: StageFirstModel
    let agent: YuiAgent?
    let agents: [YuiAgent]
    var unshared: [String] = []
    let composer: ComposerModel
    var focus: FocusState<Bool>.Binding
    let photos: [ComposerPhoto]
    let sending: Bool
    let mic: StageMic
    let showMic: Bool
    let showType: Bool
    let showAttach: Bool
    let unread: Int
    /// Things waiting on the person: the dot on the menu.
    var waiting = 0
    let reduceMotion: Bool
    /// The agent's screens (YUI-31): 1 is the answer playing here, 2... each screen it put
    /// something on. A swipe apart, with a pill each in the top bar (YUI-193).
    var screens: [Int] = [1]
    var screen = 1
    /// What a screen's pill says (`ScreenName`).
    var screenTitle: (Int) -> String = { _ in "Page" }
    var style: [String: String] = [:]
    /// How this agent moves (YUI-120): its character and the look said in words. Reduce Motion gives the still look.
    let look: MotionLook
    let actions: StageActions
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL
    /// The visual's scrim follows the words (YUI-124): the top of the chunk's words and the
    /// stage's height, both in global points.
    @State private var wordsTop: CGFloat?
    @State private var stageHeight: CGFloat = 0
    /// Heard words so far: the mic ring beats on each change.
    @State private var voice = 0
    /// The pager (YUI-187): the page drawn in the middle, how far off center it sits, the page
    /// beside it and on which side (-1 left, +1 right), the stage's width, and where the finger
    /// let go of a drag that turned the page.
    @State private var shown = 1
    /// Not `@State` on this view: the finger moves it every frame, and reading it here made the
    /// whole stage (the turn, both bars, both pages and their rows) run its body per frame. Only
    /// each page's slot reads it (`PagerSlot`), so a drag moves the pages and nothing else.
    @State private var motion = PagerMotion()
    @State private var beside: Int?
    @State private var side = 1
    @State private var pagerWidth: CGFloat = 0
    @State private var releasedAt: CGFloat?
    /// How far the finger has pulled the answer down toward home (YUI-195).
    @State private var pull: CGFloat = 0
    /// Where the layout on show keeps a place for the orb. Only the visual's host reads it.
    @State private var orbSpot = OrbSpot()
    #if DEBUG
    /// -yuiAutoSwitch: the way it is going and how many switches it has made.
    @State private var autoStep = 1
    @State private var autoCount = 0
    @State private var autoLatency: [Int] = []
    #endif
    /// Compare pictures pressed, by question (NOTE-42080): each press reaches the question as a tap on its option.
    @State private var presses: [String: YLPress] = [:]

    static let small = BarButtons.small, touch = BarButtons.touch
    /// The orb's size where it is the hero (the agent working), where it is the agent's face (the
    /// home, a greeting) and where it listens over the words it hears.
    static let orbWorking: CGFloat = 196, orbFace: CGFloat = 128, orbListening: CGFloat = 132
    /// A tap this far in from the left edge goes back a page; anywhere else goes on (Chris,
    /// TestFlight AOM_F89JfsVH: "if I tap on the left 25% it goes back").
    static let backZone: CGFloat = 0.25
    /// Faster screen switching (feedback NOTE-15980): a page turn settles in a quick spring with no wobble,
    /// the same for every agent. The look's own spring (0.55 s for a calm agent, a wobble for the default)
    /// was slow to land, and the old screen stayed drawn beside it until it came to rest.
    static let pageTurn = Animation.snappy(duration: 0.28)

    var body: some View {
        let _ = BodyLog.hit("StageFirst")
        let c = theme.swatch(scheme)
        let turn = model.turn(store.messages)
        let plan = visualPlan(turn)
        // The orb is the look on show: the layouts keep a place for it, and it is the agent's face.
        let orb = plan?.isOrb == true
        VStack(spacing: 0) {
            topBar(c)
            Group {
                if mic.live {
                    listening(c, orb: orb)
                } else {
                    pager(turn, c, orb: orb)
                        .modifier(PullHome(pull: $pull, enabled: closable(turn), reduceMotion: look.reduced,
                                           surface: c.surface, outline: c.outline, radius: theme.radius.card) { goHome() })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // T is out: a tap anywhere above folds it back to mic, T and + (YUI-121).
            .overlay {
                if model.typing {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { fold() }
                        .accessibilityHidden(true)
                        .accessibilityIdentifier("stage-tap-away")
                }
            }
            bottom(turn, c)
        }
        // One sideways gesture (YUI-168): a drag left anywhere on the stage shows the next screen,
        // a drag right the one before, and on screen 1 it pulls the drawer out (Chris, TestFlight
        // AC0r0OFGJiJOcbFdbXMgHms: "we lost the left and right scroll"). The bars count too. A
        // control that needs a sideways drag (keys, pads, a map, a slider, a row that scrolls)
        // owns it inside its own frame: a touch that starts on it goes to it first, and pages
        // keep a margin at both edges where nothing but the swipe lives. The mic's hold and its
        // slide to the trash start on the mic, so they stay the mic's. T out: the field's own.
        .contentShape(Rectangle())
        // The screen under the finger moves with it and the next one comes in beside it (YUI-187).
        .gesture(DrawerPan(direction: .right, enabled: !mic.live && !model.typing) { x in
            if at == 1 { actions.drawerDrag(max(0, x)) } else { follow(max(0, x), toward: -1) }
        } ended: { x, v in
            if at == 1 { actions.drawerSettle(x, v) } else { release(max(0, x), turns: Self.turns(x, v, by: 1), toward: -1) }
        })
        .gesture(DrawerPan(direction: .left, enabled: !mic.live && !model.typing && screens.last.map { $0 > at } == true) { x in
            follow(min(0, x), toward: 1)
        } ended: { x, v in
            release(min(0, x), turns: Self.turns(x, v, by: -1), toward: 1)
        })
        .onChange(of: at, initial: true) { old, new in arrive(at: new, from: old) }
        #if DEBUG
        .task(id: [at, screens.count]) { await autoSwitch() }
        #endif
        .background {
            ZStack {
                c.background
                if let plan {
                    // The agent's visual (YUI-124): a shader behind the chunks, or alone on the stage.
                    // The orb sits where the layout on show keeps its place, and tucks away behind words.
                    StageVisualHost(plan: plan, spot: orbSpot, up: orbUp(turn))
                        .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).maxY }) { stageHeight = $0 }
                } else {
                    // A soft wash of the agent's color from the top, like the mock.
                    RadialGradient(colors: [c.accent.opacity(scheme == .dark ? 0.16 : 0.10), .clear],
                                   center: .top, startRadius: 0, endRadius: 520)
                }
            }
            .ignoresSafeArea()
        }
        // The stage opens from the mic: a wash of the agent's color out of the bottom right.
        .overlay { StageWash(color: c.accent, look: look, trigger: model.opened).ignoresSafeArea() }
        .environment(\.ylOnStage, true)
        .environment(\.orbSpot, orbSpot)
        .environment(\.ylPageVoice, model.pageVoice)
        .onChange(of: mic.live, initial: true) { model.pageVoice.listening = mic.live }
        // Another turn or a hello: the page that took the voice is gone.
        .onChange(of: model.ask) { model.pageVoice.reset() }
        .onChange(of: model.hello) { model.pageVoice.reset() }
        .onChange(of: mic.words) { voice &+= 1 }
        // The reply came in: one beat of found, then the first chunk (Stage motion).
        .onChange(of: turn?.pages ?? 0) { old, new in
            guard old == 0, new > 0, !look.reduced, model.at == 0 else { return }
            let beat = look.timings.beat
            model.foundUntil = .now.addingTimeInterval(beat)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(beat))
                withAnimation(look.handoffAnimation) { model.foundUntil = nil }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("stage-first")
    }

    // MARK: Back home (YUI-195)

    /// An answer is up on screen 1, with something to leave: a way out is always there.
    private func closable(_ t: StageTurn?) -> Bool {
        guard let t, t.ask != nil || t.hello, at == 1, !mic.live, !model.typing else { return false }
        return t.pages > 0 || !store.inFlight
    }

    /// The last page (the questions, or the last chunk) with nothing more coming: the end.
    private func atEnd(_ t: StageTurn?) -> Bool {
        guard closable(t), let t, t.pages > 0, !store.inFlight, model.foundUntil == nil else { return false }
        return min(model.at, t.pages - 1) == t.pages - 1
    }

    /// Down to the agent's home. Local only: no event, no turn, no tokens. Every question
    /// answered so far stays, and the reply's pill in the chat plays it again.
    private func goHome() {
        focus.wrappedValue = false
        withAnimation(look.reduced ? .easeInOut(duration: 0.2) : theme.spring) {
            model.dismiss()
            pull = 0
        }
    }

    // MARK: Sideways between screens

    /// The screen on show: 1 is the answer or the home.
    private var at: Int {
        // The hello is on screen 1, wherever the last agent's page was left (YUI-225: Open lands on its first question).
        screen > 1 && screens.contains(screen) && model.hello == nil ? screen : 1
    }

    /// A drag far enough (a fifth of a phone) or quick enough turns the screen; `by` is +1 right, -1 left.
    static func turns(_ x: CGFloat, _ v: CGFloat, by sign: CGFloat) -> Bool {
        x * sign > 80 || v * sign > Drawer.flick
    }

    // MARK: The home (YUI-168)

    /// The agent's shortcuts, newest four.
    private var chips: [YLMenuItem] { AgentHome.chips(store) }

    /// Screen 1 is the home: the agent set shortcuts, or something waits on the person.
    private var hasHome: Bool { !chips.isEmpty || !AgentHome.waiting(store).isEmpty }

    /// The line under its name: what it does (its tagline, YUI-165), else how to start.
    private var homeLine: String {
        agent?.line ?? (showMic ? "Tap a shortcut, or the mic and talk." : "Tap a shortcut, or T and type.")
    }

    /// Nothing is playing on screen 1: the chips are big. Over an answer they step down to one small row.
    private func onHome(_ turn: StageTurn?) -> Bool { turn.map { $0.ask == nil && $0.pages == 0 } ?? true }

    private func tapChip(_ item: YLMenuItem) {
        AgentHome.tap(item, store: store, goPage: actions.goScreen) { words in
            composer.draft = words
            barActions.type()
        }
    }

    /// An ask opens where it waits: its page, or its turn on the stage at the questions.
    /// A review item opens its screen or link, or goes to the agent, as in the drawer.
    private func openWaiting(_ w: AgentHome.Waiting) {
        if let r = w.ask {
            if r.ask.page > 1, screens.contains(r.ask.page) { actions.goScreen(r.ask.page); return }
            let shown = withAnimation(look.enterAnimation) { model.show(reply: r.message.id, in: store.messages) }
            if !shown { actions.menu() }
        } else if let item = w.item {
            MenuAction.open(item, bucket: "review", store: store, close: {}, openURL: openURL)
        }
    }

    /// The screen before or after the one on show.
    private func go(_ step: Int) {
        guard let n = neighbor(step) else { return }
        actions.goScreen(n)
    }

    private func neighbor(_ step: Int) -> Int? {
        guard let i = screens.firstIndex(of: at), screens.indices.contains(i + step) else { return nil }
        return screens[i + step]
    }

    // MARK: The pager (YUI-187, Chris Sep 28: "slide, not fade")

    /// The screens slide: the one on show sits `slide` points off center, and while a drag or
    /// its spring is under way the one beside it (`beside`, on the `side` it comes from) is
    /// drawn a screen's width away. Only those two are ever drawn. Reduce Motion cross-fades.
    @ViewBuilder private func pager(_ turn: StageTurn?, _ c: Swatch, orb: Bool) -> some View {
        let still = look.reduced
        ZStack {
            ForEach(pagerPages, id: \.self) { n in
                PagerSlot(motion: motion, shown: n == shown, side: side, width: pagerWidth) {
                    page(n, turn, c, orb: orb)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                    .allowsHitTesting(n == shown)
                    .accessibilityHidden(n != shown)
                    .transition(still ? .opacity : .identity)
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { pagerWidth = $0 }
    }

    /// What screen `n` holds: 1 the answer or the home, 2 on the agent's screens.
    @ViewBuilder private func page(_ n: Int, _ turn: StageTurn?, _ c: Swatch, orb: Bool) -> some View {
        if n > 1, screens.contains(n) {
            ScreenPage(number: n, parts: store.onPage(n), agent: agent, style: style) { store.openStage($0) }
                .accessibilityIdentifier("stage-screen-\(n)")
        } else if let turn, turn.ask != nil || turn.hello {
            play(turn, c, orb: orb)
        } else if hasHome {
            // The agent's home (YUI-168): what it does, what is waiting on you, its chips below.
            HomeHead(agent: agent, line: homeLine, waiting: AgentHome.waiting(store), open: openWaiting,
                     seeAll: actions.menu, dismiss: { if let item = $0.item { store.dismissMenu(item) } },
                     orb: orb)
        } else {
            greeting(c, title: "Hi. \(showMic ? "Tap the mic and talk." : "Tap T and type.")",
                     sub: "I answer right here, on the whole screen.", orb: orb)
        }
    }

    /// The orb has the stage: the home, a greeting, the agent working, the mic. With a page of
    /// words up, or one of the agent's screens, it tucks away and only its wash stays behind them.
    private func orbUp(_ turn: StageTurn?) -> Bool {
        if mic.live { return true }
        guard shown == 1 else { return false }
        guard let t = turn, t.ask != nil || t.hello else { return true }
        return t.pages == 0 || model.foundUntil != nil
    }

    /// The pages drawn: the one on show, and the one beside it while it moves.
    private var pagerPages: [Int] {
        guard let b = beside, b != shown, screens.contains(b) || b == 1 else { return [shown] }
        return side < 0 ? [b, shown] : [shown, b]
    }

    /// The finger is down and has moved `x`: the page goes with it, the next one (`toward` +1)
    /// or the one before (-1) comes in from that side. Past the last screen it gives a little.
    private func follow(_ x: CGFloat, toward step: Int) {
        guard !look.reduced, shown == at else { return }
        guard let n = neighbor(step) else { motion.slide = x / 4; return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            if beside != n { beside = n }
            if side != step { side = step }
            motion.slide = x
        }
    }

    /// The finger let go: the page turns (the store moves on; `arrive` takes it from where the
    /// finger left it) or springs back.
    private func release(_ x: CGFloat, turns: Bool, toward step: Int) {
        if turns, neighbor(step) != nil {
            releasedAt = look.reduced ? nil : x
            go(step)
        } else {
            settle()
        }
    }

    /// The store turned the page (a drag, a dot, a chip, VoiceOver). The new page takes over
    /// from where the finger left the old one, or from the edge it comes in at, and springs
    /// home; the old one slides out beside it. Reduce Motion: the pages cross-fade.
    private func arrive(at new: Int, from old: Int) {
        let released = releasedAt
        releasedAt = nil
        // A hello playing keeps screen 1, whatever page the last agent left (YUI-225).
        let new = model.hello != nil ? 1 : new
        guard new != shown else { return }
        let before = shown
        guard !look.reduced, pagerWidth > 0, screens.contains(before) || before == 1 else {
            withAnimation(look.reduced ? .easeInOut(duration: 0.25) : nil) {
                shown = new
                motion.slide = 0
                beside = nil
            }
            return
        }
        let from = screens.firstIndex(of: before) ?? 0, to = screens.firstIndex(of: new) ?? 0
        let forward = to > from
        let step: CGFloat = forward ? 1 : -1
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            shown = new
            motion.slide = (released ?? 0) + step * pagerWidth
            beside = before
            side = forward ? -1 : 1
        }
        settle()
    }

    #if DEBUG
    /// `-yuiAutoSwitch`: the app drags its own screens, so a run times the switch with no test
    /// polling the accessibility tree (a snapshot blocks the main thread 40 to 60 ms and reads as a
    /// hitch). Back and forth across the screens: 18 frames of finger, then let go, a second apart.
    /// One switch per run of the task: it restarts when the screen turns (`.task(id:)`), so each
    /// run sees the view as it is then, not the copy it started on.
    /// `-yuiAutoSwitchOut <path>`: after 24 switches, a JSON file with how long each took from the
    /// finger lifting to the new screen taking over, and how often the stage's and the screens' bodies ran.
    /// `scripts/smoothness.sh` with SMOOTH_TEST=StageSwitchSmoothnessTests reads the frames.
    private func autoSwitch() async {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-yuiAutoSwitch") || args.contains("-yuiAutoSwitchOut"), !look.reduced,
              screens.count > 1, autoCount < 24 else { return }
        try? await Task.sleep(for: .seconds(autoCount == 0 ? 8 : 1))
        if Task.isCancelled { return }
        if neighbor(autoStep) == nil { autoStep = -autoStep }
        let step = autoStep
        guard neighbor(step) != nil else { return }
        if autoCount == 0 { BodyLog.counts = [:] }
        autoCount += 1
        var x: CGFloat = 0
        for _ in 0..<18 {
            x -= CGFloat(step) * 14
            follow(x, toward: step)
            try? await Task.sleep(for: .milliseconds(16))
        }
        let from = shown, lifted = CACurrentMediaTime()
        release(x, turns: true, toward: step)
        while shown == from, CACurrentMediaTime() - lifted < 3 { try? await Task.sleep(for: .milliseconds(2)) }
        autoLatency.append(Int(((CACurrentMediaTime() - lifted) * 1000).rounded()))
        guard autoCount == 24, let i = args.firstIndex(of: "-yuiAutoSwitchOut"), args.indices.contains(i + 1) else { return }
        let out: [String: Any] = ["switches": autoCount, "latencyMs": autoLatency,
                                  "stageBodies": BodyLog.counts["StageFirst"] ?? 0,
                                  "screenPageBodies": BodyLog.counts["ScreenPage"] ?? 0]
        try? JSONSerialization.data(withJSONObject: out).write(to: URL(fileURLWithPath: args[i + 1]))
    }
    #endif

    /// The page springs to the middle; the one beside it goes once it is off screen.
    private func settle() {
        withAnimation(Self.pageTurn) {
            motion.slide = 0
        } completion: {
            if motion.slide == 0 { beside = nil }
        }
    }

    // MARK: The visual (YUI-124)

    /// What the stage draws for this thread (YUI-180): the person's switch, then the agent's
    /// own `visual` line, then its quiet default. DEBUG `-yuiDemoVisual "aurora tone=mint"`
    /// puts one up with no reply.
    private var choice: StageVisualChoice {
        #if DEBUG
        if let s = UserDefaults.standard.string(forKey: "yuiDemoVisual"),
           let v = YuiLines.visual(of: YuiLines.parse("visual " + s)) { return .said(v) }
        #endif
        return .choose(default: VisualDefault.of(agent), said: store.visual, saidAny: store.visualSaid,
                       personOff: agent.map { VisualSwitch.isOff($0.id) } ?? false)
    }

    /// What the visual draws now: dimmed with a scrim behind words, full strength alone
    /// (the agent working, nothing to read yet), still when the app is not on screen.
    /// A default stays quiet either way.
    private func visualPlan(_ turn: StageTurn?) -> VisualPlan? {
        let v: YLVisual, def: VisualDefault?
        switch choice {
        case .none: return nil
        case .said(let s): v = s; def = nil
        case .quiet(let d): v = d.line; def = d
        }
        let p = theme.palette(for: scheme)
        let conditions = VisualConditions.shared
        return VisualPlan(v, accent: p.accent, ground: p.background, ink: p.ink, motion: look,
                          words: !working(turn), zone: wordsZone(turn), lowPower: conditions.lowPower, thermal: conditions.thermal,
                          hidden: phase != .active, quiet: def, action: StageMotion.action(facts(turn)))
    }

    /// Where the scrim lies: under the chunk's words, over the whole stage for the questions
    /// (words everywhere), the spec's zone until the words have been laid out.
    private func wordsZone(_ turn: StageTurn?) -> VisualPlan.Zone {
        if let t = turn, t.pages > 0, model.at >= t.chunks.count { return .under(top: 1) }
        guard let top = wordsTop, stageHeight > 0 else { return .spec }
        return .under(top: 1 - Double(top / stageHeight))
    }

    /// The agent is on it and nothing is up to read: the mark and its doing words only.
    private func working(_ turn: StageTurn?) -> Bool {
        guard !mic.live, let t = turn, t.ask != nil else { return false }
        if model.foundUntil != nil { return true }
        return t.pages == 0 && store.inFlight
    }

    // MARK: Top bar (YUI-122, TopBar.swift): the menu and the agent top left, the record top right

    private func topBar(_ c: Swatch) -> some View {
        HStack(spacing: theme.spacing.s) {
            // The drawer: the war room, the agent's controls and Settings.
            MenuPill(agent: agent, compact: screens.count > 1, id: "stage-menu", action: actions.menu)
                .modifier(WaitingDot(waiting: waiting > 0, reduceMotion: reduceMotion, x: 1, y: 1))
                .accessibilityValue(waiting > 0 ? "\(waiting) waiting on you" : "")
            // The screens as pills (YUI-193, Chris Sep 28: "some pills for the screens ... kind of
            // like tabs on an internet browser"). None with only the one screen.
            if screens.count > 1 {
                ScreenPills(screens: screens, page: shown, title: screenTitle, go: actions.goScreen)
                    .transition(.opacity)
            } else {
                Spacer(minLength: 0)
            }
            // The pen on a page starts a new chat (YUI-169); the chat itself, the record, is the bubble beside it.
            // One glass container, so the two circles sit in the same pane of glass and blend as they move.
            GlassEffectContainer {
                HStack(spacing: theme.spacing.s) {
                    circle("bubble.left", c, label: "Chat", id: "stage-record", action: actions.record)
                        .accessibilityValue(unread > 0 ? "\(unread) new" : "")
                    circle("square.and.pencil", c, label: "New chat", id: "stage-new-chat", action: actions.newChat)
                }
            }
            // The count sits over the container, at the chat button's corner. Inside it the glass
            // drew over the badge and only a sliver of it showed.
            .overlay(alignment: .topLeading) {
                if unread > 0 {
                    Text(unread > 99 ? "99+" : "\(unread)")
                        .font(.system(size: 11, weight: .heavy).monospacedDigit())
                        .foregroundStyle(c.onAccent)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(c.accent, in: Capsule())
                        .frame(width: 44, alignment: .trailing)
                        .offset(x: 2, y: -2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, theme.spacing.l)
        .padding(.top, theme.spacing.xs)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : theme.spring, value: screens.count > 1)
    }

    private func circle(_ icon: String, _ c: Swatch, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(c.ink)
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: .circle)
                .contentShape(Circle())
        }
        .buttonStyle(BounceButtonStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    // MARK: The middle

    private func greeting(_ c: Swatch, title: String, sub: String, id: String = "stage-greeting", orb: Bool) -> some View {
        VStack(spacing: theme.spacing.m) {
            // The shader draws the agent (YUI-232): its orb is its face here. With the visual off, its badge.
            if orb {
                OrbSlot(size: Self.orbFace).padding(.bottom, theme.spacing.s)
            } else if let agent {
                AgentBadge(agent: agent, size: 72)
                    .shadow(color: c.accent.opacity(0.35), radius: 24, y: 6)
            }
            Text(title)
                .font(theme.font(theme.type.display, .heavy))
                .foregroundStyle(c.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(sub)
                .font(theme.font(theme.type.body))
                .foregroundStyle(c.inkSoft)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, theme.spacing.xl)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    /// Hands-free is open: what it hears, big, as it hears it.
    private func listening(_ c: Swatch, orb: Bool) -> some View {
        VStack(spacing: theme.spacing.m) {
            // The orb is the one listening: a tall pill that breathes with the voice, over what it hears.
            if orb { OrbSlot(size: Self.orbListening).padding(.bottom, theme.spacing.m) }
            Label("Listening", systemImage: "waveform")
                .font(theme.font(theme.type.caption, .heavy))
                .foregroundStyle(c.accent)
                .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
            let hint = mic.armed ? "Let go to cancel"
                : mic.locking ? "Let go to keep recording"
                : mic.held ? "Let go to send. Slide left to cancel, up to lock." : "Just talk. A short pause sends it."
            Text(mic.words.isEmpty || mic.armed ? hint : mic.words)
                .font(theme.font(mic.words.isEmpty || mic.armed ? theme.type.body : theme.type.display,
                                 mic.words.isEmpty || mic.armed ? .semibold : .bold))
                .foregroundStyle(mic.armed ? c.accent : mic.words.isEmpty ? c.inkSoft : c.ink)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: mic.words)
        }
        .padding(.horizontal, theme.spacing.xl)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("stage-listening")
    }

    private func play(_ t: StageTurn, _ c: Swatch, orb: Bool) -> some View {
        let pages = t.pages
        let at = min(model.at, max(0, pages - 1))
        return VStack(alignment: .leading, spacing: theme.spacing.s) {
            if pages > 1 { segments(pages, at: at, c) }
            if let ask = t.ask {
                // What was asked, over the answer: not their exact words, the gist of them in 5 to 12
                // (Chris, TestFlight ADv4muh06N4P: "just summarize what I asked ... a little haiku"). The
                // whole ask is in the record, and VoiceOver still reads all of it. Always from the left, so
                // it never jumps sides between the working state and the answer.
                Text(WorkingWords.gist(ask.text))
                    .font(theme.font(theme.type.caption, .medium).italic())
                    .foregroundStyle(c.inkSoft)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("You: \(ask.text)")
                    .accessibilityIdentifier("stage-you")
            }
            Group {
                if t.failed, pages == 0, !store.inFlight {
                    failed(t, c, orb: orb)
                } else if pages == 0 || model.foundUntil != nil {
                    if store.inFlight || model.foundUntil != nil { working(c, orb: orb) } else if t.stopped {
                        // Stopped (YUI-190): the stage is still, ready for the next thing.
                        greeting(c, title: "Stopped.", sub: "Say the next thing when you're ready.", id: "stage-stopped", orb: orb)
                    } else if t.unanswered {
                        // The agent never answered this one (a dropped or timed-out turn): say so and offer
                        // Try again, never a bare "Nothing to show" that reads as Yui gave up (feedback AClUWC-D8Vp).
                        failed(t, c, title: "No answer came back.", orb: orb)
                    } else {
                        greeting(c, title: "Anything else?", sub: "Everything so far is in the chat, top right.", orb: orb)
                    }
                } else if at < t.chunks.count {
                    // done: the stage hands over to the chunk, in the look's enter.
                    chunk(t.chunks[at], c)
                        .id(t.chunks[at].id)
                        .transition(look.transition(back: model.back))
                } else {
                    questions(t, c)
                        .id("questions")
                        .transition(look.transition(back: model.back))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The end (YUI-195): the mic stays in the bar; the way out is a quiet line under the content.
            if atEnd(t), t.questions.isEmpty { pageEnd(c) }
            // More is coming: the working line stays under what already landed.
            if pages > 0, store.inFlight { workingLine(c).frame(maxWidth: .infinity) }
        }
        .padding(.horizontal, theme.spacing.l)
        .padding(.top, theme.spacing.s)
        .onChange(of: bundleKey(t), initial: true) {
            // Kept while the mic is open (the page gives way to the listening view): the hook checks again when used.
            model.bundle = { words in
                guard model.open, model.ask != nil, canBundle(t) else { return false }
                submit(t, said: words)
                return true
            }
        }
    }

    /// Changes whenever a pick, the page or the sent state does, so the hook follows them.
    private func bundleKey(_ t: StageTurn) -> String {
        "\(t.ask?.id ?? "")|\(canBundle(t))|\(model.answers.count)|\(model.at)|\(model.sent.count)"
    }

    /// The end of the last page (YUI-208): Back home and New chat side by side, quiet. Back home sends
    /// nothing: the agent never hears of it. New chat starts an empty one.
    private func pageEnd(_ c: Swatch) -> some View {
        HStack(spacing: theme.spacing.xs) {
            endButton("Back home", "house", c, id: "stage-home", hint: "Closes this and goes to the agent's home. Sends nothing.") { goHome() }
            endButton("New chat", "square.and.pencil", c, id: "stage-page-new-chat", hint: "Starts a new chat with this agent.") { actions.newChat() }
            Spacer(minLength: 0)
        }
    }

    private func endButton(_ title: String, _ icon: String, _ c: Swatch, id: String, hint: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(theme.font(theme.type.caption, .semibold))
                .foregroundStyle(c.inkSoft)
                .padding(.horizontal, theme.spacing.m)
                .frame(minHeight: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(BounceButtonStyle())
        .accessibilityHint(hint)
        .accessibilityIdentifier(id)
    }

    /// One bar per chunk, the questions last; the ones read are filled.
    private func segments(_ n: Int, at: Int, _ c: Swatch) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<n, id: \.self) { i in
                Capsule().fill(i <= at ? c.accent : c.outline).frame(height: 4)
            }
        }
        .animation(look.reduced ? nil : look.enterAnimation, value: at)
        .accessibilityElement()
        .accessibilityLabel("Part \(at + 1) of \(n)")
        .accessibilityIdentifier("stage-segments")
    }

    /// A page: up to 3 ideas, each a line and its picture, stacked. A tap on the left quarter goes back,
    /// anywhere else on. One idea centers; several share the height so the page fills the phone (VIS-4).
    private func chunk(_ page: StageChunk, _ c: Swatch) -> some View {
        let blocks = page.blocks
        return GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: blocks.count > 1 ? theme.spacing.xl : theme.spacing.l) {
                    ForEach(blocks) { k in
                        block(k, c, room: blocks.count > 1 ? geo.size.width * 0.72 : nil)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            // Buttons and drawings inside keep their own taps; a tap on words or space turns the page.
            .contentShape(.rect)
            .onTapGesture { p in step(p.x < geo.size.width * Self.backZone ? -1 : 1) }
        }
        .accessibilityIdentifier("stage-page-\(blocks.count)")
    }

    /// Presets that are a drawing: on the stage they sit straight on the page, no card round them
    /// (values 4, "no card sitting inside full screen"; feedback APXu3dFU, ALkikjiu).
    static let drawings: Set<String> = ["sketch", "row", "shapes", "shape", "mock", "part", "diagram", "map", "chart", "stat",
                                        "math", "timeline", "compare", "draw"]

    /// One idea: its words, then the drawing that shows them, as a headline sits over its figure.
    @ViewBuilder private func block(_ k: StageChunk, _ c: Swatch, room: CGFloat?) -> some View {
        let stacked = room != nil
        VStack(alignment: .leading, spacing: stacked ? theme.spacing.m : theme.spacing.xl) {
            if let line = k.line, !line.isEmpty {
                // Big type is for one short line; longer words read as body (YUI-196). Stacked ideas read a size down.
                ReadingText(text: line, ink: c.ink, soft: c.inkSoft, accent: c.accent,
                            headlineSize: stacked ? theme.type.title + 2 : theme.type.display + 4)
                    .accessibilityIdentifier("stage-line")
                    .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minY }) { wordsTop = $0 }
            }
            if let page = k.page {
                if let body = page.string("body") {
                    ReadingText(text: body, ink: c.inkSoft, soft: c.inkSoft, accent: c.accent)
                        .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minY }) { top in
                            if k.line?.isEmpty != false { wordsTop = top }
                        }
                }
                ForEach(Array((page.strings("points") ?? []).enumerated()), id: \.offset) { _, p in
                    Label { Text(p) } icon: { Circle().fill(c.accent).frame(width: 7, height: 7) }
                        .font(theme.font(theme.type.body, .semibold))
                        .foregroundStyle(c.ink)
                }
            }
            if let pic = k.pic {
                drawing(pic, k)
                    // Stacked ideas share the height: a scene is drawn narrower so its height shrinks with it; a sketch keeps its own height and the page scrolls if it must.
                    .frame(maxWidth: pic.preset == "shapes" ? room : nil)
            }
        }
    }

    /// A chunk's picture as the stage draws it: a drawing sits bare on the page.
    private func drawing(_ pic: YLComponent, _ k: StageChunk) -> some View {
        PresetView(component: pic)
            .environment(\.ylComponents, k.all)
            .environment(\.ylScope, k.scope)
            .environment(\.ylBare, Self.drawings.contains(pic.preset))
    }

    private func step(_ by: Int) {
        let t = model.turn(store.messages) ?? StageTurn()
        let to = min(max(0, model.at + by), max(0, t.pages - 1))
        guard to != model.at else { return }
        model.back = to < model.at
        withAnimation(look.enterAnimation) { model.at = to }
    }

    /// The agent is on it: the gist of the ask up top, the orb as the hero (the shader behind the
    /// stage draws it in the place kept here, and its shape says what the agent is doing, YUI-232),
    /// and under it what it is doing in a few friendly words with the seconds in glass.
    private func working(_ c: Swatch, orb: Bool) -> some View {
        VStack(spacing: theme.spacing.l) {
            if orb { OrbSlot(size: Self.orbWorking) }
            workingWords(c)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("stage-working")
    }

    /// What it is doing, light and lit by the orb's color, the seconds floating under it in glass,
    /// and the step when the agent counts them (feedback ADv4muh06N4P; StageWorking.swift).
    private func workingWords(_ c: Swatch) -> some View {
        VStack(spacing: theme.spacing.m) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let doing = store.doing.map { YLDoing(text: $0.text) }
                let word = WorkingNote.shown(doing, pickedUp: store.pickedUpAt, now: ctx.date)
                VStack(spacing: theme.spacing.s) {
                    WorkingWordsLine(text: word, ink: c.ink, accent: c.accent, still: look.reduced)
                        .id(word)
                        .transition(look.reduced ? .identity : .opacity.combined(with: .scale(scale: 0.94)))
                    if let start = store.pickedUpAt ?? store.waitingSince {
                        GlassSeconds(text: WorkingNote.elapsed(ctx.date.timeIntervalSince(start)), ink: c.inkSoft, still: look.reduced)
                    }
                }
                .animation(look.reduced ? nil : .easeInOut(duration: 0.45), value: word)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(WorkingNote.label(since: store.waitingSince, pickedUp: store.pickedUpAt, now: ctx.date, doing: doing))
            }
            if let d = store.doing, let step = d.step, let of = d.of, of > 0 {
                ProgressView(value: Double(min(step, of)), total: Double(of))
                    .tint(c.accent)
                    .frame(width: 132)
                    .animation(look.reduced ? nil : look.enterAnimation, value: step)
                    // Read as the row's value, so the row stays one element of one kind while the bar comes and goes.
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, theme.spacing.xl)
        .accessibilityValue(store.doing.flatMap { d in d.step.flatMap { s in d.of.map { "Step \(min(s, $0)) of \($0)" } } } ?? "")
        .accessibilityIdentifier("stage-working-line")
    }

    /// error: a small shake, grey, and Try again. The words still say what happened.
    private func failed(_ t: StageTurn, _ c: Swatch, title: String = "That didn't go through.", orb: Bool) -> some View {
        VStack(spacing: theme.spacing.l) {
            if orb { OrbSlot(size: Self.orbFace) }
            Text(title)
                .font(theme.font(theme.type.title, .bold))
                .foregroundStyle(c.ink)
            if let ask = t.ask?.text, !ask.isEmpty {
                Button { actions.retry(ask) } label: {
                    Text("Try again")
                        .font(theme.font(theme.type.body, .heavy))
                        .foregroundStyle(c.onAccent)
                        .padding(.horizontal, theme.spacing.xl)
                        .frame(minHeight: 48)
                        .background(c.accent, in: Capsule())
                }
                .buttonStyle(BounceButtonStyle())
                .accessibilityIdentifier("stage-try-again")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stage-error")
    }

    /// The turn as the stage reads it (StageMotion.action picks the blob's shape).
    private func facts(_ t: StageTurn?) -> StageFacts {
        let pages = t?.pages ?? 0
        var f = StageFacts()
        f.failed = (t?.failed == true || t?.unanswered == true) && pages == 0 && !store.inFlight && model.foundUntil == nil
        f.listening = mic.live
        f.asking = t != nil && pages > 0 && model.foundUntil == nil && model.at >= (t?.chunks.count ?? 0)
        if pages > 0, model.foundUntil == nil, !f.asking { f.chunk = model.at }
        f.arrived = model.foundUntil != nil
        if store.waiting, let d = store.doing { f.doing = d.text ?? "" }
        f.sent = t?.ask != nil
        return f
    }

    /// More is coming under a page that already landed: one quiet line.
    private func workingLine(_ c: Swatch) -> some View {
        VStack(spacing: theme.spacing.s) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(WorkingNote.label(since: store.waitingSince, pickedUp: store.pickedUpAt, now: ctx.date,
                                       doing: store.doing.map { YLDoing(text: $0.text) }))
                    .font(theme.font(theme.type.caption, .bold))
                    .foregroundStyle(c.inkSoft)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            if let d = store.doing, let step = d.step, let of = d.of, of > 0 {
                ProgressView(value: Double(min(step, of)), total: Double(of))
                    .tint(c.accent)
                    .frame(width: 100)
                    .animation(look.reduced ? nil : look.enterAnimation, value: step)
                    // Read as the row's value, so the row stays one element of one kind while the bar comes and goes.
                    .accessibilityHidden(true)
            }
        }
        .accessibilityValue(store.doing.flatMap { d in d.step.flatMap { s in d.of.map { "Step \(min(s, $0)) of \($0)" } } } ?? "")
        .accessibilityIdentifier("stage-working-line")
    }

    // MARK: Questions: all at once, one Send

    private func questions(_ t: StageTurn, _ c: Swatch) -> some View {
        let sent = t.ask.map { model.sent.contains($0.id) } == true || alreadySent(t)
        let n = t.questions.count
        let lone = n == 1 && t.plan == nil && (t.questions[0].c.string("q") ?? t.questions[0].c.string("title")) != nil
        return GeometryReader { geo in ScrollView {
            VStack(alignment: .leading, spacing: theme.spacing.l) {
                // One decision, one screen (NOTE-42080): the page the questions ask about heads them, a size
                // down so the answers stay in reach. It is the headline, so the plan's own title steps aside.
                if let lead = t.lead {
                    block(lead, c, room: geo.size.width * 0.72)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("stage-questions-lead")
                } else if !lone {
                    Text(t.plan?.c.string("title") ?? (n == 1 ? "One question" : "Before I go"))
                        .font(theme.font(theme.type.display, .heavy))
                        .foregroundStyle(c.ink)
                }
                // A lone ask already heads itself with its question: no filler above it.
                if sent || !lone {
                    Text(sent ? "Sent. It's in the chat." : n == 1 ? "One quick question." : "\(n) quick questions, one Send.")
                        .font(theme.font(theme.type.body))
                        .foregroundStyle(c.inkSoft)
                }
                let draft = StageDraft.load()
                ForEach(Array(t.questions.enumerated()), id: \.element.id) { i, q in
                    VStack(alignment: .leading, spacing: theme.spacing.m) {
                        // The looks it compares sit small above it, side by side (NOTE-42080, web YUI-277).
                        if !q.compare.isEmpty { compare(q, c, width: geo.size.width, sent: sent) }
                        PresetView(component: q.c)
                            // What was typed before a relaunch or another thread comes back into the fields.
                            .environment(\.ylAnswers, YLAnswers { scope, id in
                                scope == q.scope && id == q.c.ylID ? draft.entries.first { $0.id == q.id }?.value : store.ylAnswers(scope, id)
                            })
                            .environment(\.ylComponents, q.all)
                            .environment(\.ylScope, q.scope)
                            .environment(\.ylOnStage, false)
                            .environment(\.ylHostedSubmit, true)
                            // On the stage a question is the page, not a card on it.
                            .environment(\.ylBare, true)
                            .environment(\.ylEmit, YLEmit { e in
                                model.answers[q.id] = e
                                if !sent { StageDraft.keep(q.id, e) }
                            })
                            .environment(\.ylPress, presses[q.id] ?? YLPress())
                            .disabled(sent)
                    }
                    // ask: the questions come on one by one.
                    .modifier(StaggerIn(index: i, look: look))
                }
                if !sent {
                    let ready = picked(t)
                    Button { submit(t) } label: {
                        Text(t.plan?.c.string("submit") ?? "Send")
                            .font(theme.font(theme.type.title, .heavy))
                            .foregroundStyle(c.onAccent)
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(c.accent.opacity(ready ? 1 : 0.45), in: Capsule())
                    }
                    .buttonStyle(BounceButtonStyle())
                    .disabled(!ready)
                    .padding(.top, theme.spacing.s)
                    .accessibilityIdentifier("stage-send")
                }
                // The way out lives on the page (YUI-208): the mic stays in the bar for a word to add.
                if atEnd(t) { pageEnd(c) }
            }
            .padding(.vertical, theme.spacing.m)
            // A short page sits under its title, close to the fields, with no empty band over them.
            .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        // Tap the left side to go back (feedback AOM_F89JfsVH), as on a chunk: a tap on words or space in the
        // left quarter goes back to the page before the questions. Buttons, pickers and fields keep their own taps.
        .contentShape(.rect)
        .onTapGesture { p in if p.x < geo.size.width * Self.backZone, !t.chunks.isEmpty { step(-1) } }
        }
        .accessibilityIdentifier("stage-questions")
        // Kept answers count at once: Send is lit before a field has been touched again.
        .onAppear {
            guard !sent else { return }
            let draft = StageDraft.load()
            for q in t.questions where model.answers[q.id] == nil {
                if let v = draft.entries.first(where: { $0.id == q.id })?.value { model.answers[q.id] = q.c.event(v) }
            }
        }
    }

    /// The earlier pages a question's options name, each a small picture with its option under it (feedback
    /// NOTE-42080, web YUI-277). A tap is the answer: it presses that option in the question, which shows it picked.
    /// The row fits the phone's width; only when too many to fit does it scroll sideways, so a swipe still turns the page.
    private func compare(_ q: StageQuestion, _ c: Swatch, width: CGFloat, sent: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            compareRow(q, c, width: width, sent: sent)
            ScrollView(.horizontal) { compareRow(q, c, width: width, sent: sent) }
                .scrollIndicators(.hidden)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Compare")
        .accessibilityIdentifier("stage-compare")
    }

    private func compareRow(_ q: StageQuestion, _ c: Swatch, width: CGFloat, sent: Bool) -> some View {
        let n = CGFloat(q.compare.count), gap = CGFloat(theme.spacing.s)
        let w = max(72, min(112, ((width - gap * (n - 1) - 4) / n - gap).rounded(.down))), h = (w * 0.72).rounded()
        // Each picture is drawn at a phone page's width, then scaled down into its frame.
        let scale = w / 320
        let on = chosen(q)
        let corner = CGFloat(theme.radius.card) * 0.7
        return HStack(alignment: .top, spacing: gap) {
            ForEach(Array(q.compare.enumerated()), id: \.offset) { i, hit in
                let picked = on.contains(hit.option)
                Button {
                    let was = presses[q.id]?.n ?? 0
                    presses[q.id] = YLPress(option: hit.option, n: was + 1)
                } label: {
                    VStack(spacing: theme.spacing.xs) {
                        thumbnail(hit.page)
                            .frame(width: w / scale, height: h / scale)
                            .scaleEffect(scale, anchor: .topLeading)
                            .frame(width: w, height: h, alignment: .topLeading)
                            .clipShape(.rect(cornerRadius: corner / 2))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        Text(hit.option)
                            .font(theme.font(theme.type.caption, .heavy))
                            .foregroundStyle(picked ? c.accent : c.ink)
                            .lineLimit(1)
                            .frame(maxWidth: w)
                    }
                    .padding(gap / 2)
                    .background(c.surface, in: .rect(cornerRadius: corner))
                    .overlay(RoundedRectangle(cornerRadius: corner).stroke(picked ? c.accent : c.outline, lineWidth: picked ? 3 : 1.5))
                }
                .buttonStyle(BounceButtonStyle())
                .disabled(sent || q.c.locked)
                .accessibilityLabel("\(hit.option), \(hit.page.page?.string("title") ?? "")")
                .accessibilityHint("Picks \(hit.option)")
                .accessibilityAddTraits(picked ? .isSelected : [])
                .accessibilityIdentifier("stage-compare-\(i)")
            }
        }
        // Room for the picked ring.
        .padding(2)
    }

    /// A page's picture for the compare row: its drawing, or its image when it has no drawing.
    @ViewBuilder private func thumbnail(_ k: StageChunk) -> some View {
        if let pic = k.pic {
            drawing(pic, k)
        } else if let url = YLMediaURL.url(k.page?.string("img")) {
            MediaTile(src: url, fit: .fill)
        }
    }

    /// The options the question holds right now, so the pictures show what the question shows.
    private func chosen(_ q: StageQuestion) -> Set<String> {
        guard let v = model.answers[q.id]?.value else { return [] }
        if let one = v["choice"]?.string ?? v["answer"]?.string { return [one] }
        return Set(v["picked"]?.array?.compactMap(\.string) ?? [])
    }

    /// A form counts once a field has a value; one missing a required field holds Send.
    private func picked(_ t: StageTurn) -> Bool {
        t.questions.contains { model.answers[$0.id].flatMap(YLComponent.answerValue) != nil }
            && !t.questions.contains { model.answers[$0.id]?.value["missing"] != nil }
    }

    /// Picks waiting to go, so the mic and T can take a word along with them.
    private func canBundle(_ t: StageTurn) -> Bool {
        let sent = t.ask.map { model.sent.contains($0.id) } == true || alreadySent(t)
        return !t.questions.isEmpty && !sent && model.at >= t.chunks.count && picked(t)
    }

    /// Answered before (a relaunch, the record): the plan, or every loose question, has an answer.
    private func alreadySent(_ t: StageTurn) -> Bool {
        guard !t.questions.isEmpty else { return false }
        if let p = t.plan, store.ylAnswers(p.scope, p.c.ylID)?["plan"] != nil { return true }
        return t.questions.allSatisfy { store.ylAnswers($0.scope, $0.c.ylID) != nil }
    }

    /// The plan's questions go as one `{plan: {...}}` event (its fold-back is the
    /// person's message in the record); loose ones as their own events, in line order.
    private func submit(_ t: StageTurn, said: String? = nil) {
        var said = said
        var inPlan: [StageQuestion] = []
        if let p = t.plan { inPlan = t.questions.filter { $0.scope == p.scope && $0.c.inGroup == p.c.ylID } }
        if let p = t.plan, !inPlan.isEmpty {
            var plan: [String: YLValue] = [:]
            for q in inPlan { if let e = model.answers[q.id], let v = YLComponent.answerValue(e) { plan[q.c.ylID] = v } }
            var e = p.c.event(["plan": .object(plan)], echo: YLComponent.foldText(inPlan.map(\.c), plan))
            if let w = said { e = withWords(e, w); said = nil }
            store.emit(e)
            // The first plan (Build my week): the moment to ask for notifications (YUI-230).
            if p.c.ylID == "first" { Task { await PushCenter.shared.firstPlanBuilt() } }
        }
        let planned = Set(inPlan.map(\.id))
        let loose = t.questions.filter { !planned.contains($0.id) && model.answers[$0.id].flatMap(YLComponent.answerValue) != nil }
        for (i, q) in loose.enumerated() {
            guard var e = model.answers[q.id] else { continue }
            if i == loose.count - 1, let w = said { e = withWords(e, w); said = nil }
            store.emit(e)
        }
        finishDecks(t)
        StageDraft.clear(t.questions.map(\.id))
        if let id = t.ask?.id { withAnimation(theme.spring) { _ = model.sent.insert(id) } }
    }

    /// The person's own words ride with the answer: one event, one message in the record.
    private func withWords(_ e: YLEvent, _ words: String) -> YLEvent {
        var e = e
        e.value["said"] = .string(words)
        e.echo = [e.echo, words].compactMap { $0 }.joined(separator: "\n")
        return e
    }

    /// A lesson's quiz lands on this screen, not inside its deck, so the deck never saw the answers
    /// (YUI-186: Quill's score and Last quiz would never come). Once every quiz question of a deck is
    /// answered, the deck's done goes with the score, as the inline deck sends it.
    private func finishDecks(_ t: StageTurn) {
        var seen: Set<String> = []
        for q in t.questions {
            guard let g = q.c.inGroup, seen.insert("\(q.scope)#\(g)").inserted,
                  let deck = q.all.last(where: { $0.ylID == g && $0.preset == "deck" && $0.serial < q.c.serial }) else { continue }
            let quizzes = t.questions.filter { $0.scope == q.scope && $0.c.inGroup == g && $0.c.quizAnswer != nil }
            guard !quizzes.isEmpty, quizzes.allSatisfy({ model.answers[$0.id].flatMap(YLComponent.answerValue) != nil }) else { continue }
            let right = quizzes.filter { model.answers[$0.id]?.value["correct"]?.bool == true }.count
            store.emit(deck.event(["done": .bool(true), "pages": .number(Double(q.all.steps(of: deck).count)),
                                   "score": .number(Double(right)), "of": .number(Double(quizzes.count))]))
        }
    }

    // MARK: Bottom bar: back and on at the left (never an X; the pull-down and Back home close the answer), + T and the mic at the right

    @ViewBuilder private func bottom(_ turn: StageTurn?, _ c: Swatch) -> some View {
        VStack(alignment: .trailing, spacing: theme.spacing.s) {
            if let note = mic.note {
                Label(note, systemImage: "mic.slash")
                    .font(theme.font(theme.type.caption, .semibold))
                    .foregroundStyle(c.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityIdentifier("stage-mic-note")
            }
            // The agent's shortcuts over the bar, on screen 1 only: big on the home, small over an answer.
            if !model.typing, !mic.live, at == 1, !chips.isEmpty {
                HomeChips(items: chips, small: !onHome(turn), tap: tapChip)
                    .transition(.opacity)
                    .animation(reduceMotion ? nil : theme.spring, value: onHome(turn))
            }
            if model.typing {
                typingField(c)
            } else {
                let pages = turn?.pages ?? 0
                let arrows = pages > 1 && !mic.live
                let part = min(model.at, max(0, pages - 1))
                HStack(spacing: 8) {
                    // No X and no lone close (feedback AFxMozFA0OX, "just left and right, we don't need the X ever"):
                    // the arrows only, when there is more than one page. The pull-down and Back home close the answer.
                    if arrows {
                        // One pane of glass, so the two arrows blend as they come and go.
                        GlassEffectContainer {
                            HStack(spacing: 8) {
                                small("chevron.left", c, filled: false, label: "Back", id: "stage-back") { step(-1) }
                                    .opacity(part == 0 ? 0.35 : 1)
                                    .disabled(part == 0)
                                small("chevron.right", c, filled: part < pages - 1, label: "Next", id: "stage-next") { step(1) }
                                    .opacity(part == pages - 1 ? 0.35 : 1)
                                    .disabled(part == pages - 1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    BarButtons(prefix: "stage", showMic: showMic, showType: showType, showAttach: showAttach,
                               micOn: mic.on, micLive: mic.live, armed: mic.armed,
                               held: mic.held, lockArmed: mic.locking,
                               attachDisabled: sending || photos.count >= Attachments.maxPhotos,
                               reduceMotion: reduceMotion, actions: barActions, look: look, voice: voice)
                }
                // Held to talk: the trash flush left, as far from the left edge as the mic is from the right.
                .overlay(alignment: .leading) {
                    if mic.held { BarTrash(prefix: "stage", armed: mic.armed, reduceMotion: reduceMotion) }
                }
            }
        }
        .padding(.horizontal, theme.spacing.l)
        .padding(.bottom, theme.spacing.s)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : theme.spring, value: model.typing)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : theme.spring, value: mic.on)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : theme.spring, value: (turn?.pages ?? 0) > 1)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : theme.spring, value: closable(turn))
    }

    private func small(_ icon: String, _ c: Swatch, filled: Bool, label: String, id: String,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(filled ? c.onAccent : c.ink)
                .frame(width: Self.small, height: Self.small)
                .glassEffect(filled ? .regular.tint(c.accent).interactive() : .regular.interactive(), in: .circle)
                .frame(width: Self.touch, height: Self.touch)
                .contentShape(Circle())
        }
        .buttonStyle(BounceButtonStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    /// The bar's actions with T opening the stage's own field.
    private var barActions: BarActions {
        var a = actions.bar
        a.type = {
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : theme.spring) { model.typing = true }
            focus.wrappedValue = true
        }
        return a
    }

    /// Back to mic, T and +. The words stay for next time.
    private func fold() {
        focus.wrappedValue = false
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : theme.spring) { model.typing = false }
    }

    /// T: the whole field, photos in it while typing, and the way back to the mic.
    private func typingField(_ c: Swatch) -> some View {
        VStack(alignment: .trailing, spacing: theme.spacing.s) {
            VStack(alignment: .leading, spacing: theme.spacing.s) {
                if !photos.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: theme.spacing.s) {
                            ForEach(photos) { p in
                                Image(uiImage: p.preview)
                                    .resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: 64, height: 64)
                                    .clipShape(.rect(cornerRadius: 12))
                                    .overlay(alignment: .topTrailing) {
                                        Button { actions.removePhoto(p) } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 18, weight: .bold))
                                                .symbolRenderingMode(.palette)
                                                .foregroundStyle(c.onAccent, c.ink.opacity(0.7))
                                        }
                                        .padding(2)
                                        .disabled(sending)
                                        .accessibilityLabel("Remove photo")
                                    }
                                    .accessibilityIdentifier("stage-photo")
                            }
                        }
                    }
                }
                HStack(alignment: .bottom, spacing: theme.spacing.s) {
                    if showAttach {
                        AttachMenu(actions: actions.bar) {
                            Image(systemName: "plus")
                                .font(.system(size: 19, weight: .bold))
                                .foregroundStyle(c.ink)
                                .frame(width: Self.small, height: Self.small)
                                .glassEffect(.regular.interactive(), in: .circle)
                                .frame(width: Self.touch, height: Self.touch)
                                .contentShape(Circle())
                        }
                        .disabled(sending || photos.count >= Attachments.maxPhotos)
                        .accessibilityLabel("Attach")
                        .accessibilityIdentifier("stage-attach")
                    }
                    TextField(photos.isEmpty ? "Say something nice" : "Add a caption",
                              text: Binding(get: { composer.draft }, set: { if $0 != composer.draft { composer.draft = $0 } }),
                              axis: .vertical)
                        .font(theme.font(theme.type.body))
                        .foregroundStyle(c.ink)
                        .lineLimit(1...6)
                        .focused(focus)
                        .onSubmit(actions.send)
                        .id(composer.fieldID)
                        .frame(minHeight: Self.touch)
                        .accessibilityIdentifier("stage-field")
                    NameMic(text: Binding(get: { composer.draft }, set: { if $0 != composer.draft { composer.draft = $0 } }),
                            id: "stage-caption-mic", label: photos.isEmpty ? "Say a message" : "Say a caption", append: true)
                    Button(action: actions.send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 17, weight: .black))
                            .foregroundStyle(c.onAccent)
                            .frame(width: Self.small, height: Self.small)
                            .glassEffect(.regular.tint(c.accent).interactive(), in: .circle)
                            .frame(width: Self.touch, height: Self.touch)
                            .contentShape(Circle())
                            .overlay { if sending { ProgressView().tint(c.onAccent) } }
                    }
                    .buttonStyle(BounceButtonStyle())
                    .disabled(sending)
                    .accessibilityLabel("Send")
                    .accessibilityIdentifier("stage-send-text")
                }
            }
            .padding(theme.spacing.s)
            // Liquid Glass, as the bar it grows out of; the agent's color rims it while it has the keyboard.
            .glassEffect(.regular, in: .rect(cornerRadius: theme.radius.card))
            .overlay(RoundedRectangle(cornerRadius: theme.radius.card).stroke(c.accent.opacity(0.5), lineWidth: 1.5))
            if showMic {
                Button(action: fold) {
                    Text("Back to the mic")
                        .font(theme.font(theme.type.body, .bold))
                        .foregroundStyle(c.accent)
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("stage-back-to-mic")
            }
        }
        // The field grows out of T, bottom right, and folds back into it.
        .transition(reduceMotion ? .opacity : .scale(scale: 0.2, anchor: .bottomTrailing).combined(with: .opacity))
    }
}

/// How far the pager's page sits off center. Observed by `PagerSlot` alone.
@MainActor @Observable
final class PagerMotion {
    var slide: CGFloat = 0
}

/// One page of the pager at its place: the one on show sits `slide` off center, the one
/// beside it a screen's width further on its `side`. It is the only view that reads the
/// motion, so a drag frame re-runs this and moves the page; the page's own body stays put.
private struct PagerSlot<Content: View>: View {
    let motion: PagerMotion
    let shown: Bool
    let side: Int
    let width: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        content.offset(x: shown ? motion.slide : motion.slide + CGFloat(side) * width)
    }
}

/// The answer is a card you pull down to home (YUI-195, Chris: "should we be able to pull it
/// down like we were before? Re-introduce the card that can be pulled away"). It follows the
/// finger with a rubber band, turns into a rounded card as it goes, and springs back if the
/// pull is short. Mostly down only, so pages, sliders and the sideways swipes keep theirs.
private struct PullHome: ViewModifier {
    @Binding var pull: CGFloat
    let enabled: Bool
    let reduceMotion: Bool
    let surface: Color
    let outline: Color
    let radius: CGFloat
    let close: () -> Void

    func body(content: Content) -> some View {
        let t = min(pull / 300, 1)
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(surface).opacity(t)
            }
            .clipShape(RoundedRectangle(cornerRadius: pull > 0 ? radius : 0, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(outline, lineWidth: 1.5).opacity(t).allowsHitTesting(false)
            }
            .scaleEffect(reduceMotion ? 1 : 1 - 0.06 * t, anchor: .top)
            .offset(y: pull)
            .opacity(1 - 0.35 * t)
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onChanged { v in
                        guard enabled, v.translation.height > 0,
                              v.translation.height > abs(v.translation.width) * 1.5 else { return }
                        // The rubber band: it gives more the further it goes.
                        pull = reduceMotion ? 0 : rubber(v.translation.height)
                    }
                    .onEnded { v in
                        guard enabled, v.translation.height > 0 else { pull = 0; return }
                        if v.translation.height > 120 || v.predictedEndTranslation.height > 400,
                           v.translation.height > abs(v.translation.width) * 1.5 {
                            close()
                        } else {
                            withAnimation(.spring(duration: 0.35, bounce: 0.3)) { pull = 0 }
                        }
                    }
            )
            .accessibilityAction(named: "Back home") { if enabled { close() } }
    }

    private func rubber(_ d: CGFloat) -> CGFloat { 220 * (1 - 1 / (d / 220 + 1)) * 1.4 }
}
