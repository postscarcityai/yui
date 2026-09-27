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
    /// Answers given on the questions screen, by question, waiting for Send.
    var answers: [String: YLEvent] = [:]
    /// Turns whose questions went.
    var sent: Set<String> = []
    /// Rows in the record when it was last looked at: the count on its button is the rest.
    var seen = 0
    /// The last move went back a chunk: the next one comes on from the other side (YUI-120).
    var back = false
    /// Counts the times the stage opened on something said: the wash from the mic.
    var opened = 0
    /// The reply just came in: the found beat plays until then, before the first chunk.
    var foundUntil: Date?

    /// The person said something: the stage comes up on it, working.
    func follow(_ ask: String?) {
        guard let ask else { return }
        self.ask = ask
        at = 0
        back = false
        foundUntil = nil
        typing = false
        open = true
        opened += 1
    }

    /// A new thread: the greeting.
    func home() {
        ask = nil
        at = 0
        typing = false
        answers = [:]
    }

    /// Opens the stage at the chunk a reply in the record drew. False when the
    /// reply has no turn to play in (nothing the person said came before it).
    func show(reply id: String, in messages: [ChatMessage]) -> Bool {
        guard let i = messages.firstIndex(where: { $0.id == id }),
              let start = messages[..<i].lastIndex(where: \.fromUser) else { return false }
        let t = StageChunks.turn(messages, ask: messages[start].id)
        guard let at = t.chunks.firstIndex(where: { $0.scope == id })
                ?? (t.questions.contains { $0.scope == id } ? t.chunks.count : nil) else { return false }
        ask = messages[start].id
        self.at = at
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
    var manage: () -> Void
    var record: () -> Void
    /// + T and the mic (YUI-121). Its `type` is the stage's own; the view opens the field.
    var bar: BarActions
    var send: () -> Void
    var removePhoto: (ComposerPhoto) -> Void
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
    var words = ""
    /// Why it stopped, in plain words.
    var note: String?
}

struct StageFirstView: View {
    let store: ChatStore
    let model: StageFirstModel
    let agent: YuiAgent?
    let agents: [YuiAgent]
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
    /// How this agent moves (YUI-120): its character and the look said in words. Reduce Motion gives the still look.
    let look: MotionLook
    let actions: StageActions
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var phase
    /// When the mood on show began: the burst and the shake count from here.
    @State private var moodSince = Date()
    /// The visual's scrim follows the words (YUI-124): the top of the chunk's words and the
    /// stage's height, both in global points.
    @State private var wordsTop: CGFloat?
    @State private var stageHeight: CGFloat = 0
    /// Heard words so far: the mic ring beats on each change.
    @State private var voice = 0

    static let small = BarButtons.small, touch = BarButtons.touch

    var body: some View {
        let c = theme.swatch(scheme)
        let turn = model.ask.map { StageChunks.turn(store.messages, ask: $0) }
        let (mood, _) = StageMotion.mood(facts(turn))
        VStack(spacing: 0) {
            topBar(c)
            Group {
                if mic.live {
                    listening(c)
                } else if let turn, turn.ask != nil {
                    play(turn, c)
                } else {
                    greeting(c, title: "Hi. \(showMic ? "Tap the mic and talk." : "Tap T and type.")",
                             sub: "I answer right here, on the whole screen.")
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
        .background {
            ZStack {
                c.background
                if let plan = visualPlan(turn) {
                    // The agent's visual (YUI-124): a shader behind the chunks, or alone on the stage.
                    StageVisual(plan: plan)
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
        .onChange(of: mood) { moodSince = .now }
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

    // MARK: The visual (YUI-124)

    /// The thread's visual, or nil. DEBUG `-yuiDemoVisual "aurora tone=mint"` puts one up with no reply.
    private var visual: YLVisual? {
        #if DEBUG
        if let s = UserDefaults.standard.string(forKey: "yuiDemoVisual") {
            return YuiLines.visual(of: YuiLines.parse("visual " + s)) ?? store.visual
        }
        #endif
        return store.visual
    }

    /// What the visual draws now: dimmed with a scrim behind words, full strength alone
    /// (the agent working, nothing to read yet), still when the app is not on screen.
    private func visualPlan(_ turn: StageTurn?) -> VisualPlan? {
        guard let v = visual else { return nil }
        let p = theme.palette(for: scheme)
        let conditions = VisualConditions.shared
        return VisualPlan(v, accent: p.accent, ground: p.background, ink: p.ink, motion: look,
                          words: !working(turn), zone: wordsZone(turn), lowPower: conditions.lowPower, thermal: conditions.thermal,
                          hidden: phase != .active)
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
        return t.pages == 0 && store.waiting
    }

    // MARK: Top bar (YUI-122, TopBar.swift): the menu and the agent top left, the record top right

    private func topBar(_ c: Swatch) -> some View {
        HStack(spacing: theme.spacing.s) {
            // The drawer: the war room, the agent's controls and Settings.
            circle("line.3.horizontal", c, label: "Menu", id: "stage-menu", action: actions.menu)
                .modifier(WaitingDot(waiting: waiting > 0, reduceMotion: reduceMotion, x: 1, y: 1))
                .accessibilityValue(waiting > 0 ? "\(waiting) waiting on you" : "")
            AgentPicker(agent: agent, agents: agents, pick: actions.pick, manage: actions.manage)
                .accessibilityIdentifier("stage-agents")
            Spacer(minLength: 0)
            circle("bubble.left", c, label: "Chat", id: "stage-record", action: actions.record)
                .overlay(alignment: .topTrailing) {
                    if unread > 0 {
                        Text(unread > 99 ? "99+" : "\(unread)")
                            .font(.system(size: 11, weight: .heavy).monospacedDigit())
                            .foregroundStyle(c.onAccent)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(c.accent, in: Capsule())
                            .offset(x: 2, y: -2)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityValue(unread > 0 ? "\(unread) new" : "")
        }
        .padding(.horizontal, theme.spacing.l)
        .padding(.top, theme.spacing.xs)
    }

    private func circle(_ icon: String, _ c: Swatch, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(c.ink)
                .frame(width: 44, height: 44)
                .background(c.surface, in: Circle())
                .overlay(Circle().stroke(c.outline, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(BounceButtonStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    // MARK: The middle

    private func greeting(_ c: Swatch, title: String, sub: String) -> some View {
        VStack(spacing: theme.spacing.m) {
            if let agent {
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
        .accessibilityIdentifier("stage-greeting")
    }

    /// Hands-free is open: what it hears, big, as it hears it.
    private func listening(_ c: Swatch) -> some View {
        VStack(spacing: theme.spacing.m) {
            // listen: the mark shrinks toward the mic, bottom right.
            StageMark(color: c.accent, mood: .listen, flavor: nil, look: look, since: moodSince)
                .frame(width: 64, height: 64)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .transition(look.reduced ? .opacity : .scale(scale: 2.4, anchor: .bottomTrailing).combined(with: .opacity))
            Label("Listening", systemImage: "waveform")
                .font(theme.font(theme.type.caption, .heavy))
                .foregroundStyle(c.accent)
                .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
            let hint = mic.armed ? "Let go to cancel"
                : mic.held ? "Let go to send. Slide left to cancel." : "Just talk. A short pause sends it."
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

    private func play(_ t: StageTurn, _ c: Swatch) -> some View {
        let pages = t.pages
        let at = min(model.at, max(0, pages - 1))
        return VStack(alignment: .leading, spacing: theme.spacing.s) {
            if pages > 1 { segments(pages, at: at, c) }
            if let ask = t.ask {
                Text("\(Text("You: ").bold())\(ask.text)")
                    .font(theme.font(theme.type.caption))
                    .foregroundStyle(c.inkSoft)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: pages > 1 ? .leading : .trailing)
                    .accessibilityIdentifier("stage-you")
            }
            Group {
                if t.failed, pages == 0, !store.waiting {
                    failed(t, c)
                } else if pages == 0 || model.foundUntil != nil {
                    if store.waiting || model.foundUntil != nil { working(c) } else {
                        greeting(c, title: "Anything else?", sub: "Everything so far is in the chat, top right.")
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
            // More is coming: the working line stays under what already landed.
            if pages > 0, store.waiting { workingLine(c).frame(maxWidth: .infinity) }
        }
        .padding(.horizontal, theme.spacing.l)
        .padding(.top, theme.spacing.s)
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

    /// A line to read and its picture. A tap on the left third goes back, anywhere else on.
    private func chunk(_ k: StageChunk, _ c: Swatch) -> some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: theme.spacing.l) {
                    if let pic = k.pic {
                        PresetView(component: pic)
                            .environment(\.ylComponents, k.all)
                            .environment(\.ylScope, k.scope)
                    }
                    if let line = k.line, !line.isEmpty {
                        Text(line)
                            .font(theme.font(k.pic == nil ? theme.type.display + 4 : theme.type.display, .heavy))
                            .foregroundStyle(c.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("stage-line")
                            .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minY }) { wordsTop = $0 }
                    }
                    if let page = k.page {
                        if let body = page.string("body") {
                            Text(body).font(theme.font(theme.type.body)).foregroundStyle(c.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
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
                }
                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            // Buttons and drawings inside keep their own taps; a tap on words or space turns the page.
            .contentShape(.rect)
            .onTapGesture { p in step(p.x < geo.size.width / 3 ? -1 : 1) }
        }
    }

    private func step(_ by: Int) {
        let t = model.ask.map { StageChunks.turn(store.messages, ask: $0) } ?? StageTurn()
        let to = min(max(0, model.at + by), max(0, t.pages - 1))
        guard to != model.at else { return }
        model.back = to < model.at
        withAnimation(look.enterAnimation) { model.at = to }
    }

    /// The agent is on it: their words up top, a mark in its color breathing, and what it is doing.
    private func working(_ c: Swatch) -> some View {
        let (mood, flavor) = StageMotion.mood(facts(model.ask.map { StageChunks.turn(store.messages, ask: $0) }))
        return VStack(spacing: theme.spacing.xl) {
            // The orb visual sits where the mark lives: it is the mark then.
            StageMark(color: c.accent, mood: mood, flavor: flavor, look: look, since: moodSince)
                .opacity(visual != nil && (visual?.look ?? "orb") == "orb" ? 0 : 1)
                .frame(width: 170, height: 170)
            workingLine(c, big: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("stage-working")
    }

    /// error: a small shake, grey, and Try again. The words still say what happened.
    private func failed(_ t: StageTurn, _ c: Swatch) -> some View {
        VStack(spacing: theme.spacing.l) {
            StageMark(color: c.accent, mood: .error, flavor: nil, look: look, since: moodSince)
                .frame(width: 120, height: 120)
            Text("That didn't go through.")
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

    /// The turn as Stage motion reads it (StageMotion.mood).
    private func facts(_ t: StageTurn?) -> StageFacts {
        let pages = t?.pages ?? 0
        var f = StageFacts()
        f.failed = t?.failed == true && pages == 0 && !store.waiting
        f.listening = mic.live
        f.asking = t != nil && pages > 0 && model.foundUntil == nil && model.at >= (t?.chunks.count ?? 0)
        if pages > 0, model.foundUntil == nil, !f.asking { f.chunk = model.at }
        f.arrived = model.foundUntil != nil
        if store.waiting, let d = store.doing { f.doing = d.text ?? "" }
        f.sent = t?.ask != nil
        return f
    }

    private func workingLine(_ c: Swatch, big: Bool = false) -> some View {
        VStack(spacing: theme.spacing.s) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(WorkingNote.label(since: store.waitingSince, pickedUp: store.pickedUpAt, now: ctx.date,
                                       doing: store.doing.map { YLDoing(text: $0.text) }))
                    .font(theme.font(big ? theme.type.title : theme.type.caption, .bold))
                    .foregroundStyle(big ? c.ink : c.inkSoft)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            if let d = store.doing, let step = d.step, let of = d.of, of > 0 {
                ProgressView(value: Double(min(step, of)), total: Double(of))
                    .tint(c.accent)
                    .frame(width: big ? 160 : 100)
                    .animation(look.reduced ? nil : look.enterAnimation, value: step)
            }
        }
        .accessibilityIdentifier("stage-working-line")
    }

    // MARK: Questions: all at once, one Send

    private func questions(_ t: StageTurn, _ c: Swatch) -> some View {
        let sent = t.ask.map { model.sent.contains($0.id) } == true || alreadySent(t)
        let n = t.questions.count
        return ScrollView {
            VStack(alignment: .leading, spacing: theme.spacing.m) {
                Text(t.plan?.c.string("title") ?? (n == 1 ? "One question" : "Before I go"))
                    .font(theme.font(theme.type.display, .heavy))
                    .foregroundStyle(c.ink)
                Text(sent ? "Sent. It's in the chat." : n == 1 ? "One quick question." : "\(n) quick questions, one Send.")
                    .font(theme.font(theme.type.body))
                    .foregroundStyle(c.inkSoft)
                ForEach(Array(t.questions.enumerated()), id: \.element.id) { i, q in
                    PresetView(component: q.c)
                        .environment(\.ylComponents, q.all)
                        .environment(\.ylScope, q.scope)
                        .environment(\.ylOnStage, false)
                        .environment(\.ylHostedSubmit, true)
                        .environment(\.ylEmit, YLEmit { e in model.answers[q.id] = e })
                        .disabled(sent)
                        // ask: the questions come on one by one.
                        .modifier(StaggerIn(index: i, look: look))
                }
                if !sent {
                    // A form counts once a field has a value; one missing a required field holds Send.
                    let ready = t.questions.contains { model.answers[$0.id].flatMap(YLComponent.answerValue) != nil }
                        && !t.questions.contains { model.answers[$0.id]?.value["missing"] != nil }
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
            }
            .padding(.vertical, theme.spacing.m)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("stage-questions")
    }

    /// Answered before (a relaunch, the record): the plan, or every loose question, has an answer.
    private func alreadySent(_ t: StageTurn) -> Bool {
        guard !t.questions.isEmpty else { return false }
        if let p = t.plan, store.ylAnswers(p.scope, p.c.ylID)?["plan"] != nil { return true }
        return t.questions.allSatisfy { store.ylAnswers($0.scope, $0.c.ylID) != nil }
    }

    /// The plan's questions go as one `{plan: {...}}` event (its fold-back is the
    /// person's message in the record); loose ones as their own events, in line order.
    private func submit(_ t: StageTurn) {
        var inPlan: [StageQuestion] = []
        if let p = t.plan { inPlan = t.questions.filter { $0.scope == p.scope && $0.c.inGroup == p.c.ylID } }
        if let p = t.plan, !inPlan.isEmpty {
            var plan: [String: YLValue] = [:]
            for q in inPlan { if let e = model.answers[q.id], let v = YLComponent.answerValue(e) { plan[q.c.ylID] = v } }
            store.emit(p.c.event(["plan": .object(plan)], echo: YLComponent.foldText(inPlan.map(\.c), plan)))
        }
        let planned = Set(inPlan.map(\.id))
        for q in t.questions where !planned.contains(q.id) {
            if let e = model.answers[q.id], YLComponent.answerValue(e) != nil { store.emit(e) }
        }
        if let id = t.ask?.id { withAnimation(theme.spring) { _ = model.sent.insert(id) } }
    }

    // MARK: Bottom bar: back and on at the left, + T and the mic at the right

    @ViewBuilder private func bottom(_ turn: StageTurn?, _ c: Swatch) -> some View {
        VStack(alignment: .trailing, spacing: theme.spacing.s) {
            if let note = mic.note {
                Label(note, systemImage: "mic.slash")
                    .font(theme.font(theme.type.caption, .semibold))
                    .foregroundStyle(c.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityIdentifier("stage-mic-note")
            }
            if model.typing {
                typingField(c)
            } else {
                HStack(spacing: 8) {
                    let pages = turn?.pages ?? 0
                    if pages > 1, !mic.live {
                        let at = min(model.at, pages - 1)
                        small("chevron.left", c, filled: false, label: "Back", id: "stage-back") { step(-1) }
                            .opacity(at == 0 ? 0.35 : 1)
                            .disabled(at == 0)
                        small("chevron.right", c, filled: at < pages - 1, label: "Next", id: "stage-next") { step(1) }
                            .opacity(at == pages - 1 ? 0.35 : 1)
                            .disabled(at == pages - 1)
                    }
                    Spacer(minLength: 0)
                    BarButtons(prefix: "stage", showMic: showMic, showType: showType, showAttach: showAttach,
                               micOn: mic.on, micLive: mic.live, armed: mic.armed,
                               attachDisabled: sending || photos.count >= Attachments.maxPhotos,
                               reduceMotion: reduceMotion, actions: barActions, look: look, voice: voice)
                }
            }
        }
        .padding(.horizontal, theme.spacing.l)
        .padding(.bottom, theme.spacing.s)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : theme.spring, value: model.typing)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : theme.spring, value: mic.on)
    }

    private func small(_ icon: String, _ c: Swatch, filled: Bool, label: String, id: String,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(filled ? c.onAccent : c.ink)
                .frame(width: Self.small, height: Self.small)
                .background(filled ? c.accent : c.surface, in: Circle())
                .overlay(Circle().stroke(filled ? .clear : c.outline, lineWidth: 1.5))
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
                                .background(c.surface, in: Circle())
                                .overlay(Circle().stroke(c.outline, lineWidth: 1.5))
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
                    Button(action: actions.send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 17, weight: .black))
                            .foregroundStyle(c.onAccent)
                            .frame(width: Self.small, height: Self.small)
                            .background(c.accent, in: Circle())
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
            .background(c.surface, in: .rect(cornerRadius: theme.radius.card))
            .overlay(RoundedRectangle(cornerRadius: theme.radius.card).stroke(c.accent.opacity(0.5), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.08), radius: 14, y: 6)
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
