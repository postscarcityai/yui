import PhotosUI
import SwiftUI

/// The chat with the selected agent (one thread per agent, over the relay).
/// Agent replies in Yui Lines render inline as presets.
struct ChatView: View {
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(Account.self) private var account
    @Environment(AgentStore.self) private var agents
    @Environment(PushCenter.self) private var push
    @Environment(\.agentStyle) private var agentStyle
    /// Yui's own look (RESTYLE.md): sheets and Settings wear it, not the open agent's.
    @Environment(\.appTheme) private var appTheme
    @State private var draft = ""
    /// Bumped on every send: a fresh text field. Clearing `draft` alone can leave
    /// the sent words drawn in the field (TestFlight feedback APthnqcdHvqEP).
    @State private var composerID = 0
    @State private var store = ChatStore(messages: ChatView.seed)
    @State private var outbox = Outbox.shared
    @State private var showSettings = ProcessInfo.processInfo.arguments.contains("-yuiSettings")
    @State private var settingsDetent: PresentationDetent =
        ProcessInfo.processInfo.arguments.contains("-yuiSettingsLarge") ? .large : .medium
    @State private var showAgents = ProcessInfo.processInfo.arguments.contains("-yuiAgents")
    /// The agent's drawer (YUI-54): open, and where a drag has it (points from its resting place).
    @State private var drawerOpen = ProcessInfo.processInfo.arguments.contains("-yuiDrawer")
    @State private var drawerDrag: CGFloat?
    /// Controls, "Name, look and notifications": that agent's edit sheet.
    @State private var editingAgent: YuiAgent?
    /// The first-run button opens Add agent straight from the chat.
    @State private var addFirst = false
    /// The message open in Select text.
    @State private var selecting: ChatMessage?
    /// A reply's chip was tapped: the thread scrolls to this bubble (YUI-68).
    @State private var scrollTarget: String?
    @FocusState private var focused: Bool
    /// Photos waiting in the composer, and the pickers that fill it.
    @State private var photos: [ComposerPhoto] = []
    @State private var picked: [PhotosPickerItem] = []
    @State private var pickingPhotos = false
    @State private var shooting = false
    @State private var sending = false
    @State private var talk = PushToTalk()
    /// Hold to talk: the finger's sideways travel while it is on the mic, nil when it is up.
    @GestureState private var micPress: CGFloat?
    @State private var micHeld = false
    /// How far left the finger is, 0 or less. Past `cancelDistance` the trash is armed.
    @State private var micDragX: CGFloat = 0
    /// start() is still asking for the mic or warming up.
    @State private var micStarting = false
    @State private var holdStart: Task<Void, Never>?
    private static let cancelDistance: CGFloat = 110
    private var cancelArmed: Bool { talk.listening && micDragX <= -Self.cancelDistance }
    @State private var composerNote: String?
    /// The thread's scroll, and whether it is far enough up to offer the way back down (YUI-50).
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var scrolledUp = false
    /// The thread rests on the newest message (YUI-74): the composer changing height, the
    /// keyboard going or a new row keep it there. Only the person's own scroll up lets go.
    @State private var pinned = true
    /// A drag on the thread is under way. `dismissPin`: it started pinned with the keyboard
    /// up, so if it only lets the keyboard go, the thread goes back to the newest message.
    @State private var dragging = false
    @State private var dismissPin = false
    @State private var atBottom = true
    /// Agent messages that landed while scrolled up: the count on the arrow.
    @State private var unread = 0
    /// The page on show (YUI-31): 1 the chat, 2 to 12 the agent's screens. Follows `store.page`.
    @State private var page: Int? = 1
    /// Reduce Motion: pages cross-fade instead of sliding.
    @State private var pageFade = 1.0
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// The system setting, or `-yuiReduceMotion` for UI tests (a simulator can't flip it).
    private var reduceMotion: Bool {
        systemReduceMotion || ProcessInfo.processInfo.arguments.contains("-yuiReduceMotion")
    }

    /// The chat is on show (not a screen, and not the first run's welcome).
    private var onChat: Bool { firstRun || (page ?? 1) == 1 }

    /// The screen on show when the agent keeps the composer on it (`>2 talk`, YUI-62).
    private var talkPage: Int? {
        let n = page ?? 1
        return !firstRun && n != 1 && store.talks(on: n) ? n : nil
    }

    /// The composer is here: the chat, or a screen the agent talks on.
    private var composing: Bool { onChat || talkPage != nil }

    var body: some View {
        let c = theme.swatch(scheme)
        ZStack {
        NavigationStack {
            Group {
                if firstRun {
                    FirstRun(loaded: agents.loaded, error: agents.error) {
                        addFirst = true
                    } retry: {
                        Task { await agents.refresh() }
                    }
                } else {
                    // The chat, then each screen the agent put something on, a swipe apart (YUI-31).
                    PagedThread(store: store, screens: store.screens, page: $page, fade: pageFade, agent: store.agent, style: agentStyle) { thread }
                        // Drag right on the chat: the drawer follows the finger (YUI-54). On a
                        // screen the pager is scrolled along, so the drag pages back instead.
                        .gesture(DrawerPan(direction: .right, enabled: !drawerOpen && !store.stageShowing) { x in
                            focused = false
                            drawerDrag = max(0, x)
                        } ended: { x, v in
                            settleDrawer(open: x > drawerWidth * Drawer.threshold || v > Drawer.flick)
                        })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(c.background)
            .safeAreaInset(edge: .bottom) {
                if !firstRun {
                    VStack(spacing: theme.spacing.s) {
                        // A chat glyph and a dot per screen, in the composer's inset so every
                        // page clears it. Only there when there is somewhere to go.
                        let screens = store.screens
                        if screens.count > 1 {
                            PageTabs(page: page ?? 1, screens: screens) { store.goToPage($0) }
                                .transition(.scale(scale: 0.8).combined(with: .opacity))
                        }
                        // Screens are for reading: the composer stays with the chat,
                        // unless the agent keeps it on this screen (`>2 talk`).
                        if composing {
                            inputBar(c)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(theme.spring, value: composing)
                }
            }
            // Held bubble or card: the tapback bar (agent's only) and Reply, Copy,
            // Select text over a dimmed thread (YUI-49, YUI-68).
            .overlayPreferenceValue(ReactionAnchor.self) { anchor in
                GeometryReader { geo in
                    if let anchor, let m = store.reactingMessage {
                        ReactionOverlay(text: m.words, reacts: !m.fromUser, rect: geo[anchor], size: geo.size,
                                        current: m.fromUser ? nil : store.reaction(for: m)) { pick in
                            store.react(m.id, with: pick)
                            Task {
                                try? await Task.sleep(for: .milliseconds(260))
                                closeReactions()
                            }
                        } dismiss: {
                            closeReactions()
                        } select: {
                            closeReactions()
                            selecting = m
                        } reply: {
                            closeReactions()
                            startReply(m.id)
                        } lifted: {
                            if let yl = m.yl {
                                YLReplyItems(screen: yl, scope: m.id, style: agentStyle).allowsHitTesting(false)
                            } else {
                                Bubble.words(m)
                            }
                        }
                        .id(m.id)
                        .transition(.opacity)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                menuItem(c)
                ToolbarItem(placement: .principal) {
                    if let agent = store.agent {
                        Button { settleDrawer(open: true) } label: {
                            HStack(spacing: theme.spacing.s) {
                                AgentBadge(agent: agent, size: 26)
                                Text(agent.name)
                                    .font(theme.font(theme.type.body, theme.strong))
                                    .foregroundStyle(c.ink)
                                Circle().fill(agent.liveness == .online ? c.mint : agent.liveness == .asleep ? c.lavender
                                              : agent.liveness == .notListening ? c.butter : c.outline)
                                    .frame(width: 8, height: 8)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Talking to \(agent.name), \(agent.liveness.spoken)")
                    } else {
                        Wordmark(height: 26)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape.fill") { showSettings = true }
                        .tint(c.inkSoft)
                }
            }
            .toolbarBackground(c.background, for: .navigationBar)
            // A screen is full screen: the agent switcher and settings stay with the chat.
            .toolbar(onChat ? .visible : .hidden, for: .navigationBar)
            .animation(theme.spring, value: onChat)
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .presentationDetents([.medium, .large], selection: $settingsDetent)
                    .presentationCornerRadius(appTheme.radius.card)
                    .environment(\.yuiTheme, appTheme)
            }
            .sheet(isPresented: $addFirst) {
                // Paired and "Say hi": the new agent's thread is the chat.
                AddAgentSheet { id in
                    agents.selectedID = id
                    addFirst = false
                }
                .presentationDetents([.large])
                .presentationCornerRadius(appTheme.radius.card)
                .environment(\.yuiTheme, appTheme)
            }
            // Select text: the held message's words, read-only, to copy any part.
            .sheet(item: $selecting) { m in
                SelectTextSheet(text: m.words)
                    .presentationDetents([.medium, .large])
                    .presentationCornerRadius(theme.radius.card)
            }
            .sheet(isPresented: $showAgents) {
                AgentsView()
                    .presentationDetents([.medium, .large])
                    .presentationCornerRadius(appTheme.radius.card)
                    .environment(\.yuiTheme, appTheme)
            }
            .sheet(item: $editingAgent) { agent in
                EditAgentSheet(agent: agent)
                    .presentationDetents([.medium, .large])
                    .presentationCornerRadius(theme.radius.card)
            }
        }
        .overlay { drawer }
        // Belt and braces (YUI-80): while the chat is stepped back, a tap or a swipe on it
        // closes the stage. The stage covers it, so this only answers if the stage never drew.
        .overlay {
            if store.stageOpen {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(.rect)
                    .onTapGesture { store.closeStage() }
                    .gesture(DragGesture(minimumDistance: 20).onEnded { _ in store.closeStage() })
                    // Not for VoiceOver: the stage has its own close, and an element over
                    // the whole chat hid the stage's text from the accessibility tree.
                    .accessibilityHidden(true)
            }
        }
        // The chat steps back a little while the stage is up (YUI-13), and only while
        // it is actually on screen: the same test that mounts the StageView (YUI-80).
        .mask { RoundedRectangle(cornerRadius: store.stageShowing ? 38 : 0).ignoresSafeArea() }
        .scaleEffect(store.stageShowing ? 0.92 : 1)
        .background(Color.black.ignoresSafeArea())
        if let m = store.stageMessage, let yl = m.yl, !store.stageComponents.isEmpty {
            StageView(components: store.stageComponents, scope: m.id, agent: store.agent, open: store.stageOpen,
                      close: store.closeStage)
                .environment(\.ylEmit, m.id == store.reading?.id ? ChatStore.quiet : store.emit)
                .environment(\.ylComponents, yl.components)
                .id(m.id)
                .transition(.opacity)
        }
        }
        .environment(\.ylEmit, store.emit)
        .environment(\.ylShow, store.ylShow)
        .environment(\.ylPage, store.ylPage)
        .environment(\.ylAnswers, store.ylAnswers)
        .environment(\.yuiMedia, store.agent.flatMap { a in account.session?.userID == "demo" ? nil : YuiMedia(account: account, agentID: a.id) })
        .environment(\.ylTimers, store.timers)
        .environment(\.restyleNewest, store.messages.last { $0.yl?.restyle != nil }?.id)
        .onChange(of: agentStyle, initial: true) { store.style = agentStyle }
        // The stage's reply went, or its screens stopped being staged: close it (YUI-80).
        .onChange(of: store.stageShowing) { store.settleStage() }
        .onAppear {
            store.spring = theme.spring
            // A `theme` line in a reply restyles that agent, and the app with it.
            store.onLook = { id, props, at in Task { await agents.applyThemeLine(agentID: id, props: props, at: at) } }
        }
        .onChange(of: theme) { store.spring = theme.spring }
        // Pages (YUI-31): a swipe tells the store; the store (a tab, a pill, a
        // reply sent to a page) moves the pager with a spring, or a fade under Reduce Motion.
        .onChange(of: page) {
            if let page { store.showingPage(page) }
            // The composer goes with the chat, so does the keyboard.
            if !composing { focused = false }
        }
        // Streamed lines can ask for 2 and then 3 within a quarter second; a new
        // scroll animation cuts the last one short, so take only the newest ask.
        .task(id: store.pageTurns) {
            guard store.pageTurns > 0 else { return }
            try? await Task.sleep(for: .milliseconds(250))
            turnPage(to: store.page)
        }
        .onChange(of: store.agent?.id, initial: true) { turnPage(to: store.page) }
        // Screens come and go: a page emptied by `>N clear` is gone, so back to the
        // chat; a page remembered for this agent shows once its history loads.
        // (A reply that adds a page turns to it through `pageTurns` above, after layout.)
        .onChange(of: store.screens) { if !store.screens.contains(store.page), store.loaded { store.goToPage(1) } }
        .onChange(of: store.loaded) { keepPage() }
        #if DEBUG
        // -yuiReactDemo bar|select|<meaning> ("love it"): the reaction bar open, Select text open, or a reacted bubble, for screenshots.
        .task {
            guard let mode = UserDefaults.standard.string(forKey: "yuiReactDemo") else { return }
            try? await Task.sleep(for: .seconds(1))
            guard let m = store.messages.last(where: { !$0.fromUser && $0.yl == nil }) else { return }
            if mode == "select" { selecting = m; return }
            if mode == "bar" { openReactions(m.id) } else { store.react(m.id, with: Reaction.all.first { $0.meaning == mode } ?? Reaction.all[0]) }
        }
        // -yuiThemeDemo "say Autumn it is.\ntheme autumn": the agent restyles itself, live, for screenshots.
        // -yuiDemoPrompt "Tabata tonight?" puts the person's message above it, after
        // -yuiDemoDelay seconds [1.5] (demo clips wait for the recording to catch up).
        .task {
            guard let text = UserDefaults.standard.string(forKey: "yuiThemeDemo") else { return }
            if let prompt = UserDefaults.standard.string(forKey: "yuiDemoPrompt") {
                let delay = UserDefaults.standard.object(forKey: "yuiDemoDelay") == nil
                    ? 1.5 : UserDefaults.standard.double(forKey: "yuiDemoDelay")
                try? await Task.sleep(for: .seconds(delay))
                withAnimation(theme.spring) { store.messages.append(ChatMessage(text: prompt, fromUser: true)) }
                try? await Task.sleep(for: .seconds(1.2))
                store.stream(text.replacingOccurrences(of: "\\n", with: "\n"))
                return
            }
            try? await Task.sleep(for: .seconds(2.5))
            store.stream(text.replacingOccurrences(of: "\\n", with: "\n"))
        }
        // -yuiIncomingWhenUp <n>: n agent messages land a second after the thread is first scrolled up (YUI-50).
        .task(id: scrolledUp) {
            let n = UserDefaults.standard.integer(forKey: "yuiIncomingWhenUp")
            guard n > 0, scrolledUp, !store.messages.contains(where: { $0.text.hasPrefix("While you were up there") }) else { return }
            try? await Task.sleep(for: .seconds(1))
            for i in 1...n {
                withAnimation(theme.spring) {
                    store.messages.append(ChatMessage(text: "While you were up there, note \(i) of \(n).", fromUser: false))
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        // -yuiThreadRows <path>: a JSON array of yui_messages rows, loaded the way a
        // reopened thread loads them (answers-on-reopen tests, no network).
        .task {
            guard let path = UserDefaults.standard.string(forKey: "yuiThreadRows"),
                  let data = FileManager.default.contents(atPath: path),
                  let rows = try? JSONDecoder().decode([ThreadRow].self, from: data) else { return }
            store.load(rows)
            // -yuiShelfOpen <name>: tap that saved screen on the shelf, for screenshots.
            if let name = UserDefaults.standard.string(forKey: "yuiShelfOpen") {
                try? await Task.sleep(for: .seconds(1))
                store.reopen(name)
            }
        }
        #endif
        .task {
            // Presence changes on its own (a Mac falls asleep): keep it honest while the chat is up.
            // An agent that isn't listening yet is checked often: its gateway is about to start.
            while !Task.isCancelled {
                await agents.refresh()
                try? await Task.sleep(for: .seconds(agents.selected?.liveness == .notListening ? 5 : 30))
            }
        }
        .onChange(of: agents.selected?.id, initial: true) {
            // The demo account keeps the local demo chat, with the agent's face on it.
            if account.session?.userID == "demo" { store.demo(agents.selected); return }
            store.attach(agents.selected, account: account)
        }
        .onChange(of: agents.selected) { store.refreshAgent(agents.selected) }
        .onChange(of: store.agent?.id, initial: true) { push.visibleAgentID = store.agent?.id }
        // A notification tap or yui://agent/<id>/thread: straight to that thread.
        .onChange(of: push.pendingAgentID, initial: true) {
            guard let id = push.pendingAgentID else { return }
            push.pendingAgentID = nil
            showAgents = false
            showSettings = false
            settleDrawer(open: false)
            agents.selectedID = id
            if !agents.agents.contains(where: { $0.id == id }) { Task { await agents.refresh() } }
        }
        .tint(c.accent)
    }

    // MARK: The agent's drawer (YUI-54)

    /// Top left: the drawer, also a drag right on the chat away. What's waiting on
    /// you sits on the button's glass as a count.
    private func menuItem(_ c: Swatch) -> some ToolbarContent {
        let n = store.waitingCount
        return ToolbarItem(placement: .topBarLeading) {
            Button { settleDrawer(open: true) } label: {
                Image(systemName: "line.3.horizontal")
                    .overlay(alignment: .topTrailing) {
                        if n > 0 {
                            Text("\(n)")
                                .font(theme.font(10, .heavy)).foregroundStyle(c.onAccent)
                                .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
                                .background(c.accent, in: Capsule())
                                .offset(x: 8, y: -8)
                        }
                    }
            }
            .tint(c.inkSoft)
            .accessibilityLabel("Agent menu")
            .accessibilityValue(n > 0 ? "\(n) waiting on you" : "")
        }
    }

    private var drawerWidth: CGFloat { (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.width ?? 390 }

    /// How far out the drawer is, 0 closed to 1 open, following a drag when there is one.
    private var drawerShown: CGFloat {
        let w = drawerWidth * Drawer.fraction
        guard let d = drawerDrag else { return drawerOpen ? 1 : 0 }
        return min(1, max(0, drawerOpen ? 1 + d / w : d / w))
    }

    /// Springs open or shut from wherever the finger let go. Reduce Motion: a fade.
    private func settleDrawer(open: Bool) {
        if open { focused = false }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : theme.spring) {
            drawerOpen = open
            drawerDrag = nil
        }
    }

    /// Over the chat, from the left, stopping short so the chat peeks out on the right.
    /// A tap on that sliver or a drag back to the left closes it.
    @ViewBuilder private var drawer: some View {
        let p = drawerShown
        if !firstRun, p > 0 || drawerOpen {
            GeometryReader { geo in
                let w = geo.size.width * Drawer.fraction
                ZStack(alignment: .leading) {
                    Color.black.opacity(0.32 * p)
                        .ignoresSafeArea()
                        .contentShape(.rect)
                        .onTapGesture { settleDrawer(open: false) }
                        .accessibilityLabel("Close the menu")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { settleDrawer(open: false) }
                    AgentDrawer(store: store, close: { settleDrawer(open: false) },
                                compose: { draft = $0; focused = true },
                                manage: { settleDrawer(open: false); showAgents = true },
                                add: { settleDrawer(open: false); addFirst = true },
                                edit: { editingAgent = $0 },
                                reduceMotion: reduceMotion)
                        .frame(width: w)
                        .background {
                            UnevenRoundedRectangle(bottomTrailingRadius: 34, topTrailingRadius: 34)
                                .fill(theme.swatch(scheme).background)
                                .shadow(color: .black.opacity(0.18 * p), radius: 24, x: 6)
                                .ignoresSafeArea()
                        }
                        .offset(x: reduceMotion ? 0 : -w * (1 - p))
                        .opacity(reduceMotion ? p : 1)
                        .accessibilityAddTraits(.isModal)
                }
                .gesture(DrawerPan(direction: .left) { x in
                    drawerDrag = min(0, x)
                } ended: { x, v in
                    settleDrawer(open: !(x < -w * Drawer.threshold || v < -Drawer.flick))
                })
            }
            .transition(.identity)
        }
    }

    /// Page 1: the thread itself, or the empty chat before the first message.
    @ViewBuilder private var thread: some View {
        let c = theme.swatch(scheme)
        if store.messages.isEmpty && !store.waiting {
            EmptyChat(agent: store.agent, loading: store.agent != nil && !store.loaded) { store.send($0) }
        } else {
            ScrollView {
                // Not Lazy: LazyVStack drops preset cards from the accessibility tree (iOS 26/27),
                // so VoiceOver and UI tests saw only the plain bubbles.
                VStack(spacing: theme.spacing.m) {
                    // A reply with nothing left to draw gets no row, not a lone face (YUI-80).
                    ForEach(store.messages.filter { $0.yl?.isBlank != true }) { m in
                        Group {
                            if let yl = m.yl {
                                YLReply(screen: yl, scope: m.id, agent: store.agent, style: agentStyle,
                                        reaction: store.wearsReaction(m) ? store.reaction(for: m) : nil,
                                        lifted: store.reacting == m.id, reduceMotion: reduceMotion,
                                        open: { openReactions(m.id) },
                                        react: { store.react(m.id, with: $0) },
                                        select: { selecting = m },
                                        reply: { startReply(m.id) }) { store.openStage(m.id) }
                            } else {
                                Bubble(message: m, agent: m.from.map { f in agents.agents.first { $0.id == f.agentID } }
                                            ?? store.agent,
                                       pending: outbox.isPending(m.id),
                                       reaction: store.wearsReaction(m) ? store.reaction(for: m) : nil,
                                       lifted: store.reacting == m.id,
                                       reduceMotion: reduceMotion,
                                       open: { openReactions(m.id) },
                                       react: { store.react(m.id, with: $0) },
                                       select: { selecting = m },
                                       reply: { startReply(m.id) },
                                       goToQuote: { goToOriginal(of: $0) },
                                       openFrom: m.from.flatMap { f in
                                           agents.agents.contains { $0.id == f.agentID }
                                               ? { agents.selectedID = f.agentID } : nil
                                       },
                                       read: { store.readAsPages(m) })
                            }
                        }
                        // Scrolled to from a reply's chip: a short glow says "this one".
                        .background {
                            if store.flashing == m.id {
                                RoundedRectangle(cornerRadius: theme.radius.bubble)
                                    .fill(c.accent.opacity(0.18))
                                    .padding(-6)
                                    .transition(.opacity)
                                    .accessibilityElement()
                                    .accessibilityLabel("The message you replied to")
                                    .accessibilityIdentifier("reply-original")
                            }
                        }
                        .id(m.id)
                    }
                    if let agent = store.agent, outbox.offline, !outbox.pending(agentID: agent.id).isEmpty {
                        // On the phone, not on Yui yet: it sends itself when the connection is back.
                        QuietNote(text: "Not sent yet. It goes the moment you're back online.", icon: "clock")
                    } else if store.waiting, let agent = store.agent, agent.liveness == .notListening {
                        // Paired, but its gateway never started (YUI-64): it waits, no timer counting forever.
                        ListeningNote(agent: agent)
                    } else if store.waiting, let agent = store.agent, agent.liveness != .online {
                        // Delivered, but the agent's computer is away: say so instead of fake dots.
                        QuietNote(text: agent.liveness == .asleep
                                  ? "\(agent.name) is asleep. It gets this when its computer wakes."
                                  : "\(agent.name) is offline. It gets this when its gateway starts again.",
                                  icon: agent.liveness == .asleep ? "moon.zzz" : "powersleep")
                    } else if store.waiting {
                        WorkingNote(agent: store.agent, since: store.waitingSince, pickedUp: store.pickedUpAt).id("typing")
                    }
                    if let error = store.error {
                        Text(error)
                            .font(theme.font(theme.type.caption, .semibold))
                            .foregroundStyle(c.inkSoft)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, theme.spacing.l)
                .padding(.vertical, theme.spacing.m)
            }
            .defaultScrollAnchor(.bottom)
            .scrollPosition($position)
            // A reply's chip: back up to what it quoted, then it glows.
            .onChange(of: scrollTarget) {
                guard let id = scrollTarget else { return }
                scrollTarget = nil
                pinned = false
                withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.9)) {
                    position.scrollTo(id: id, anchor: .center)
                }
                store.flash(id)
            }
            .scrollDismissesKeyboard(.interactively)
            // How far above the newest message the view sits, in screens.
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                // containerSize is inside the insets (nav bar above, composer below).
                let below = geo.contentSize.height - geo.contentInsets.top - geo.contentOffset.y - geo.containerSize.height
                return below / max(geo.containerSize.height, 1)
            } action: { _, screens in
                atBottom = screens < 0.04
                followScroll(screens: screens)
            }
            // Content or insets changed size (a sent photo, the composer, the keyboard):
            // a pinned thread goes back to the newest message.
            .onScrollGeometryChange(for: CGSize.self) { geo in
                CGSize(width: geo.containerSize.height, height: geo.contentSize.height)
            } action: { _, _ in
                if pinned, !dragging, !atBottom { position.scrollTo(edge: .bottom) }
            }
            .onScrollPhaseChange { _, phase in settleScroll(phase) }
            // The keyboard often goes a moment after the drag settles.
            .onChange(of: focused) {
                guard !focused, dismissPin, !dragging else { return }
                dismissPin = false
                jumpToBottom()
            }
            .onChange(of: store.messages.map(\.id)) { old, new in countNew(old: old, new: new) }
            // The agent's saved screens, one tap from the stage (YUI-32).
            .safeAreaInset(edge: .top, spacing: 0) {
                if !store.shelf.screens.isEmpty {
                    ShelfBar(screens: store.shelf.screens, open: store.reopen, remove: store.unshelve)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottom) {
                if scrolledUp {
                    JumpToBottom(unread: unread, action: jumpToBottom)
                        .padding(.bottom, theme.spacing.m)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                }
            }
        }
    }

    /// Signed in with no agents yet (every new account): nothing here can answer,
    /// so the chat says how to connect one instead of pretending.
    /// The demo account shows it too when started with `-yuiNoAgents` (SOC-3 videos).
    private var firstRun: Bool {
        (account.session?.userID != "demo" || ProcessInfo.processInfo.arguments.contains("-yuiNoAgents"))
            && agents.agents.isEmpty
    }

    /// Typing / at the start: the agent's own commands (YUI-61). Hosts with no
    /// command list (MCP, the demo) show nothing.
    private var slashSuggestions: [Suggestion] {
        talk.listening ? [] : SlashCommands.suggestions(draft, in: store.agent?.commands)
    }

    /// Typing @ anywhere: your other agents, filtered as you type (YUI-44).
    private var mentionSuggestions: [Suggestion] {
        guard !talk.listening, talkPage == nil, account.session?.userID != "demo" || agents.agents.count > 1 else { return [] }
        return Mentions.suggestions(draft, agents: agents.agents, current: store.agent?.id)
    }

    /// The other agent this draft goes to, if it @s one.
    private var mentioning: YuiAgent? {
        guard !draft.hasPrefix("/"), talkPage == nil else { return nil }
        return Mentions.target(draft, agents: agents.agents, current: store.agent?.id)
    }

    private func inputBar(_ c: Swatch) -> some View {
        let mentions = mentionSuggestions
        let suggestions = mentions.isEmpty ? slashSuggestions : mentions
        let to = mentions.isEmpty ? mentioning : nil
        return VStack(alignment: .leading, spacing: theme.spacing.s) {
            if !suggestions.isEmpty {
                SuggestionPopover(items: suggestions, pick: { draft = $0.fill; focused = true },
                                  identifier: mentions.isEmpty ? "slash" : "mention")
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
            if let to {
                MentionBar(agent: to)
                    .transition(.opacity)
            }
            if let q = store.replying, talkPage == nil {
                ReplyBar(quote: q, agent: store.agent?.name) { store.cancelReply() }
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
            if !photos.isEmpty { attachmentStrip(c) }
            if let note = composerNote {
                Label(note, systemImage: "info.circle")
                    .font(theme.font(theme.type.caption, .semibold))
                    .foregroundStyle(c.inkSoft)
                    .transition(.opacity)
                    .accessibilityIdentifier("composer-note")
            }
            HStack(alignment: .bottom, spacing: theme.spacing.s) {
                if !talk.listening { attachMenu(c) }
                if talk.listening { listeningField(c) } else { field(c) }
                sendButton(c)
            }
        }
        .padding(.horizontal, theme.spacing.l)
        .padding(.vertical, theme.spacing.s)
        .background(c.background)
        .animation(theme.spring, value: talk.listening)
        .animation(theme.spring, value: photos)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : theme.spring, value: suggestions.isEmpty)
        .animation(.easeInOut(duration: 0.15), value: to?.id)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : theme.spring, value: store.replying)
        .fullScreenCover(isPresented: $shooting) {
            CameraCapture(front: false) { data in
                shooting = false
                if let data { add([data]) }
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $pickingPhotos, selection: $picked,
                      maxSelectionCount: max(Attachments.maxPhotos - photos.count, 1), matching: .images)
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task {
                var datas: [Data] = []
                for item in items { if let d = try? await item.loadTransferable(type: Data.self) { datas.append(d) } }
                add(datas)
            }
        }
        #if DEBUG
        // -yuiComposerPhoto <path>: a photo already in the composer (UI tests, screenshots).
        // -yuiPTTDemo "words": the hold-to-talk listening state.
        .task {
            if let path = UserDefaults.standard.string(forKey: "yuiComposerPhoto"),
               let data = FileManager.default.contents(atPath: path) { add([data]) }
            if let words = UserDefaults.standard.string(forKey: "yuiPTTDemo") { talk.demo(words) }
            // -yuiPTTDemoCancel: the demo, slid to the trash.
            if ProcessInfo.processInfo.arguments.contains("-yuiPTTDemoCancel") { micDragX = -Self.cancelDistance - 30 }
            talk.fakeWords = UserDefaults.standard.string(forKey: "yuiPTTFake")
        }
        #endif
    }

    private func field(_ c: Swatch) -> some View {
        TextField(!photos.isEmpty ? "Add a caption" : talkPage.map { "About screen \($0)" } ?? "Say something nice",
                  text: $draft, axis: .vertical)
            .font(theme.font(theme.type.body))
            .foregroundStyle(c.ink)
            .lineLimit(1...5)
            .focused($focused)
            .accessibilityIdentifier("composer")
            .onSubmit(send)
            .id(composerID)
            .padding(.horizontal, theme.spacing.l)
            .padding(.vertical, theme.spacing.m)
            .frame(minHeight: 46)
            .background(c.surface, in: .rect(cornerRadius: theme.radius.pill))
            .overlay(RoundedRectangle(cornerRadius: theme.radius.pill).stroke(c.outline, lineWidth: 1.5))
    }

    /// Held down: what it hears, live, where the words would be, with the trash on the
    /// left, a clock and the waveform. Slide the finger left to the trash to cancel.
    private func listeningField(_ c: Swatch) -> some View {
        let armed = cancelArmed
        return VStack(alignment: .leading, spacing: theme.spacing.xs) {
            Text(armed ? "Let go to cancel"
                 : talk.transcript.isEmpty ? "Let go to send. Slide left to cancel." : talk.transcript)
                .font(theme.font(theme.type.body, armed || talk.transcript.isEmpty ? .semibold : .regular))
                .foregroundStyle(armed ? c.accent : talk.transcript.isEmpty ? c.inkSoft : c.ink)
                .lineLimit(1...4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
            HStack(spacing: theme.spacing.s) {
                Image(systemName: armed ? "trash.fill" : "trash")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(armed ? c.onAccent : c.inkSoft)
                    .frame(width: 30, height: 30)
                    .background(armed ? c.accent : .clear, in: Circle())
                    .scaleEffect(armed && !reduceMotion ? 1.2 : 1)
                    .accessibilityIdentifier(armed ? "talk-trash-armed" : "talk-trash")
                if let start = talk.startedAt {
                    TimelineView(.periodic(from: start, by: 1)) { ctx in
                        let s = max(0, Int(ctx.date.timeIntervalSince(start)))
                        Text(String(format: "%d:%02d", s / 60, s % 60))
                            .font(theme.font(theme.type.caption, .semibold).monospacedDigit())
                            .foregroundStyle(c.inkSoft)
                    }
                }
                TalkWaveform(levels: talk.levels, level: talk.level,
                             color: armed ? c.inkSoft.opacity(0.4) : c.accent,
                             track: c.outline, reduceMotion: reduceMotion)
            }
        }
        .padding(.horizontal, theme.spacing.l)
        .padding(.vertical, theme.spacing.s)
        .frame(minHeight: 46)
        .background(c.surface, in: .rect(cornerRadius: theme.radius.bubble))
        .overlay(RoundedRectangle(cornerRadius: theme.radius.bubble).stroke(armed ? c.inkSoft : c.accent, lineWidth: 2))
        .animation(reduceMotion ? nil : theme.spring, value: armed)
        .sensoryFeedback(.impact(weight: .medium), trigger: armed)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("listening")
    }

    /// One + for everything that isn't words. Room for files and more later, no new buttons.
    private func attachMenu(_ c: Swatch) -> some View {
        Menu {
            Button { pickingPhotos = true } label: { Label("Photo library", systemImage: "photo.on.rectangle") }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { shooting = true } label: { Label("Camera", systemImage: "camera") }
            }
        } label: {
            Image(systemName: "plus")
                .font(theme.font(theme.type.title, .black))
                .foregroundStyle(c.ink)
                .frame(width: 46, height: 46)
                .background(c.surface, in: Circle())
                .overlay(Circle().stroke(c.outline, lineWidth: 1.5))
        }
        .disabled(sending || photos.count >= Attachments.maxPhotos)
        .accessibilityLabel("Attach")
        .accessibilityIdentifier("attach")
    }

    private func attachmentStrip(_ c: Swatch) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: theme.spacing.s) {
                ForEach(photos) { p in
                    Image(uiImage: p.preview)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 72, height: 72)
                        .clipShape(.rect(cornerRadius: theme.radius.bubbleTail + 6))
                        .overlay(alignment: .topTrailing) {
                            Button { photos.removeAll { $0.id == p.id } } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 20, weight: .bold))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(c.onAccent, c.ink.opacity(0.7))
                            }
                            .padding(3)
                            .disabled(sending)
                            .accessibilityLabel("Remove photo")
                        }
                        .overlay { if sending { c.background.opacity(0.4).overlay(ProgressView().tint(c.accent)) } }
                        .accessibilityIdentifier("attachment")
                }
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Send when there is something to send; otherwise the mic: hold to talk.
    private func sendButton(_ c: Swatch) -> some View {
        let ready = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty
        return Group {
            if ready || sending {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(theme.font(theme.type.title, .black))
                        .foregroundStyle(c.onAccent)
                        .frame(width: 46, height: 46)
                        .background(c.accent, in: Circle())
                }
                .buttonStyle(BounceButtonStyle())
                .disabled(sending)
                .accessibilityLabel("Send")
            } else {
                Image(systemName: cancelArmed ? "trash.fill" : talk.listening ? "waveform" : "mic.fill")
                    .font(theme.font(theme.type.title, .black))
                    .foregroundStyle(talk.listening ? c.onAccent : c.ink)
                    .symbolEffect(.variableColor.iterative, isActive: talk.listening && !cancelArmed && !reduceMotion)
                    .frame(width: 46, height: 46)
                    .background(talk.listening ? (cancelArmed ? c.inkSoft : c.accent) : c.surface, in: Circle())
                    .overlay(Circle().stroke(talk.listening ? .clear : c.outline, lineWidth: 1.5))
                    .scaleEffect(talk.listening ? 1.25 : 1)
                    .contentShape(Circle())
                    // Follows the finger left, like a thumb pulling it to the trash.
                    .offset(x: talk.listening ? max(micDragX, -Self.cancelDistance - 40) : 0)
                    // Global space: the button moves under the finger, so its own space would jitter.
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .updating($micPress) { v, state, _ in state = v.translation.width })
                    .onChange(of: micPress) { old, new in
                        if old == nil, new != nil { micDown() }
                        if let x = new { micDragX = min(0, x) }
                        if old != nil, new == nil { micUp() }
                    }
                    .sensoryFeedback(.impact(weight: .light), trigger: talk.listening) { _, now in now }
                    .accessibilityLabel(talk.listening ? "Listening" : "Hold to talk")
                    .accessibilityIdentifier("talk")
            }
        }
    }

    /// Finger on the mic: after a short hold it starts listening. A quick tap only explains.
    private func micDown() {
        micHeld = true
        micDragX = 0
        holdStart?.cancel()
        holdStart = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, micHeld else { return }
            micStarting = true
            await talk.start()
            micStarting = false
            // The first time, the system asks for the mic and the finger comes up while it does.
            if talk.listening && !micHeld {
                talk.cancel()
                flash("Ready. Hold the mic to talk.")
                return
            }
            note(for: talk.phase)
        }
    }

    /// Finger up: send what it heard, or throw it away if it was slid to the trash.
    private func micUp() {
        micHeld = false
        let cancel = cancelArmed
        micDragX = 0
        if talk.listening {
            if cancel {
                talk.cancel()
            } else {
                Task { let words = await talk.stop(); if !words.isEmpty { draft = words; send() } }
            }
        } else if !micStarting {
            holdStart?.cancel()
            if talk.phase == .idle { flash("Hold the mic to talk, let go to send.") }
        }
    }

    private func note(for phase: PushToTalk.Phase) {
        switch phase {
        case .denied: flash("Yui needs the mic and speech recognition. Turn them on in Settings.")
        case .failed: flash("Can't listen right now. Try typing.")
        default: break
        }
        talk.reset()
    }

    private func flash(_ text: String) {
        withAnimation { composerNote = text }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { if composerNote == text { composerNote = nil } }
        }
    }

    private func add(_ datas: [Data]) {
        let room = Attachments.maxPhotos - photos.count
        photos += datas.prefix(max(room, 0)).compactMap(ComposerPhoto.init)
        if datas.count > room { flash("Up to \(Attachments.maxPhotos) photos in one message.") }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !photos.isEmpty, !sending else { return }
        if account.session?.userID != "demo" {
            guard store.agent != nil else { return }
            let to = mentioning
            let screen = talkPage
            if photos.isEmpty {
                // Not sent (no agent, no session): the words stay in the field.
                guard store.send(text, mention: to, screen: screen) else { return }
                clearComposer()
                return
            }
            let outgoing = photos
            sending = true
            Task {
                defer { sending = false }
                do {
                    try await store.send(text, photos: outgoing, mention: to, screen: screen)
                    photos = []
                    clearComposer()
                } catch {
                    flash("Couldn't send the photo. Try again.")
                }
            }
            return
        }
        #if DEBUG
        // -yuiDemoReply: the demo account's agent answers through the store, working row and all (YUI-63).
        if photos.isEmpty, UserDefaults.standard.string(forKey: "yuiDemoReply") != nil, store.send(text, screen: talkPage) {
            clearComposer()
            return
        }
        #endif
        let body = Attachments.body(text: text, photos: photos.count)
        let screen = text.hasPrefix("/") ? nil : talkPage
        let q = text.hasPrefix("/") || screen != nil ? nil : store.replying
        if screen == nil { store.replying = nil }
        withAnimation(ChatStore.sendSpring) {
            store.messages.append(ChatMessage(text: Attachments.caption(body: body, photos: photos.count), fromUser: true,
                                              photos: photos.map { .local($0.preview) }, replyTo: q, fromScreen: screen))
        }
        photos = []
        clearComposer()
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation(theme.spring) {
                store.messages.append(ChatMessage(text: ChatView.replies.randomElement()!, fromUser: false))
            }
        }
    }

    private func openReactions(_ id: String) {
        focused = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { store.reacting = id }
    }

    private func closeReactions() {
        withAnimation(.easeOut(duration: 0.2)) { store.reacting = nil }
    }

    /// Reply (hold menu or left swipe): the quote goes above the composer and the keyboard comes up.
    private func startReply(_ id: String) {
        store.startReply(id)
        focused = true
    }

    /// A reply's chip: scroll back to the message it quotes, when it is still in the thread.
    private func goToOriginal(of q: ReplyQuote) {
        guard let id = store.original(of: q) else { return }
        focused = false
        scrollTarget = id
    }

    /// More than about a screen above the newest message: the arrow shows. It
    /// goes once you are back at the bottom, and the count goes with it.
    private func followScroll(screens: CGFloat) {
        let up = screens > 0.9 ? true : screens < 0.04 ? false : scrolledUp
        guard up != scrolledUp else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : theme.spring) {
            scrolledUp = up
            if !up { unread = 0 }
        }
    }

    /// New rows in the thread. Yours always brings you to the bottom; the
    /// agent's, while you read further up, add to the arrow's count.
    private func countNew(old: [String], new: [String]) {
        let before = Set(old)
        let added = store.messages.filter { !before.contains($0.id) }
        guard !added.isEmpty else { return }
        if added.contains(where: \.fromUser) {
            jumpToBottom()
        } else if scrolledUp {
            withAnimation(theme.spring) { unread += added.count }
        }
    }

    private func keepPage() {
        let screens = store.screens
        if !screens.contains(store.page) {
            if store.loaded { store.goToPage(1) }
        } else if page != store.page {
            turnPage(to: store.page)
        }
    }

    private func turnPage(to n: Int) {
        guard page != n else { return }
        guard reduceMotion else {
            withAnimation(theme.spring) { page = n }
            return
        }
        pageFade = 0
        page = n
        withAnimation(.easeInOut(duration: 0.25)) { pageFade = 1 }
    }

    /// A drag takes the pin away unless it ends at the bottom, or it let the keyboard
    /// go from a pinned thread; then the thread goes back to the newest message.
    private func settleScroll(_ phase: ScrollPhase) {
        switch phase {
        case .interacting, .tracking:
            if !dragging { dragging = true; dismissPin = pinned && focused }
        case .idle:
            guard dragging else { return }
            dragging = false
            if dismissPin, !focused {
                dismissPin = false
                jumpToBottom()
            } else {
                pinned = atBottom
            }
        default:
            break
        }
    }

    private func jumpToBottom() {
        pinned = true
        withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.9)) {
            position.scrollTo(edge: .bottom)
        }
    }

    /// Empties the field and swaps in a new one, keeping the keyboard up if it was.
    /// A hold-to-talk send leaves it down.
    private func clearComposer() {
        let keep = focused
        draft = ""
        composerID += 1
        // The new field mounts on the next pass; focus it then so the keyboard stays.
        if keep { Task { @MainActor in focused = true } }
    }

    /// The demo account's canned answers (screenshots only; real accounts never see them).
    static let replies = [
        "Noted! My agent friends move in soon, then I can really help.",
        "Mm, I heard you. Real answers arrive with the agents in Phase 1.",
        "Got it. Tucking that away for when my brain shows up.",
    ]

    static let demo = [
        ChatMessage(text: "Hi Yui!", fromUser: true),
        ChatMessage(text: "Hi hi! I'm Yui. Ask me anything, or tell me what you want to get done today.", fromUser: false),
        ChatMessage(text: "Can you set up a 20 minute tabata for me?", fromUser: true),
        ChatMessage(text: "", fromUser: false, yl: YLScreen(YLSamples.text("tabata")!)),
    ]

    /// The INT-18 report as it landed on build 82: one wall of about 300 words (YUI-79).
    static let longReport = "A2A bridge: add any A2A agent to Yui by its Agent Card. node adapters/a2a/yui-a2a.ts pair <code> --card <url>, then run; add --card <url> puts more agents on the same machine. Runtime-neutral TypeScript client (src/a2a.ts + src/sse.ts, fetch and an SSE parser only, so the hosted step runs the same code in a Durable Object): A2A 1.0 SendMessage / SendStreamingMessage / SubscribeToTask / GetTask / CancelTask and 0.3 message/send, message/stream, tasks/resubscribe, tasks/get, one version-free shape for callers; 1.0 wins when a card lists both. The bridge keeps the relay's rules (delivered on pickup, handled after the answer, meta.turn, outbox on disk, one turn at a time per agent, a clean stop reads offline): contextId = the Yui agent, the channel guide rides as a context part on each new task, working states are the app's working row, text artifacts plus the final status message become the answer, input-required keeps the task open for the person's next message, failed/rejected/canceled say so. The running task's id is on disk, so a restart resubscribes (then GetTask) instead of sending the turn again; agents without streaming are sent returnImmediately and polled. Connector kind http, no server changes. Tests: client.test.ts 42/42 (SSE, both versions' shapes, errors, live against the scripted tests/echo-agent.ts in 1.0 and 0.3, resubscribe, GetTask polling); sdk_interop.test.ts 4/4 against the official a2a-sdk servers (1.1.5 and 0.3.26); a2a_e2e.py 66/66 live on throwaway accounts (1.0, 0.3, 1.0 without streaming: turns, a long task working then done, kill -9 mid-task resumes the same task and answers once, input-required, taps, failed) plus the phone run 6/6 with YuiUITests/A2ATests on the iPhone 18 Pro sim (working row, long answer, an A2A agent's screen and a tap, light; a question continuing the task, dark). No app binary change (INT-18)"

    /// What the Hermes gateway answers /status with: markdown (YUI-76).
    static let statusAnswer = """
        📊 **Hermes Gateway Status**

        **Session ID:** `20260925_051515_4f2a`
        **Created:** 2026-09-25 05:15
        **Model:** `claude-opus-5-5` (custom)
        **Agent Running:** No

        **Connected Platforms:** yui
        """

    /// Short lines, many of them: a bubble taller than any phone (YUI-78).
    static let holdChecklist = """
        **Before build 95**
        - Captions
        - Voice
        - Pauses
        - Takes
        - Acronyms
        - Stitch
        - Cut
        - Cleanup
        - Menu
        - Replies
        - Copy
        - Select
        - Share
        - Dark
        - Small
        - Type
        - Top
        - Bottom
        - Cards
        - Remove
        - Outside
        - Haptics
        - Shots
        - Progress
        """

    /// One of each element a host sends: bold, italic, code, a block, lists, a link.
    static let markdownSample = """
        ## Build 92
        **Bold**, *italic*, ~~gone~~ and `inline code`.
        - Chat bubbles read markdown
        - Copy takes the plain words
          - nested items step in
        1. Pull main
        2. Run `xcodegen`
        ```
        swift test --filter BubbleMarkdown
        ```
        Details on [yuigui.com](https://www.yuigui.com).
        """

    /// A card this build draws, then a drawing in presets it doesn't know (as build 96 got a sketch).
    static let newerPresets = """
        card "Not yet + You decide" body="Every Needs you ask now ends with both."
        hologram "INT-7 ask" frame=phone
        beam "Works | Phone only | Connector failed" +x note="assumed you'd tested"
        split
        beam "Not yet | You decide" +hi note="new, on every ask"
        """

    /// The message from TestFlight feedback on build 96 (YUI-82): a card-it answer
    /// with a list, word for word, so the pages it folds into can be shot before and after.
    static let cardedAnswer = """
        I've carded it as YUI-81 (backlog), with the other Yui app cards, next to YUI-79 (no text bombs). It fixes the pages in the "What's in build" deck:

        - Each page gets a real title, like "Hold menu fits".
        - Each page says in plain words what you can do now. No card or feedback ids.
        - Changes that only matter to people building on Yui share one page.
        - Nothing gets cut off mid-sentence.

        It's done when a test run on build 96's changes gives pages you can read at a glance, with before and after shown. It waits its turn like any other backlog card.
        """

    /// A build-ready ping as yui_build_ping.py writes it (YUI-82), without the pictures
    /// so a run with no network draws the same pages.
    static let buildReady = """
        card "Build 96" body="3 changes: the hold menu fits, answers read clean and 1 more" cta="Open TestFlight" url=https://testflight.apple.com/join/ykrYHwet
        deck "What's in build 96" +inline
        page "The hold menu fits any message" body="Reactions on top, the message, the menu underneath. All on screen, never touching."
        page "Agent answers read clean" body="Bold, code, lists, headings and links draw the way they were written."
        page "For builders" body="Outside the app: n8n workflows, LangGraph agents, Meta's Muse Spark and Grok. How to set them up is on yuigui.com."
        end
        """

    /// The "No card or feedback ids" idea drawn, not told (YUI-84): a story page whose
    /// picture is a chat bubble with the id struck and the plain words highlighted, a
    /// page that is only a drawing, and one sketch on its own in the chat.
    static let drawnPages = """
        deck "Plain words" +inline
        page "No card or feedback ids" body="Each page says what changed in words you already use."
        sketch Yui frame=bubble
        row "Parked YUI-83 (t_2f464301) in the backlog" +x note="an id tells you nothing"
        after
        row "Parked the drawing card in the backlog" +hi note="plain words"
        page "Every button does something"
        sketch "Build ready" frame=phone
        row "Build 97 is ready"
        row +dim
        row "Got it" +button +x note="does nothing"
        row "Install" +button +hi note="does the thing"
        end
        end
        sketch "What's in build 96" frame=window
        row "Hold menu fits" +hi
        row "YUI-78 ALUttyXBpVz3" +x +dim note="ids go"
        row
        """

    /// `-yuiDemo` seeds a chat; `-yuiYL <sample>` seeds one YL reply (see `YLSamples`).
    static var seed: [ChatMessage] {
        if UserDefaults.standard.string(forKey: "yuiReactDemo") != nil {
            return [ChatMessage(text: "Saturday workout?", fromUser: true),
                    ChatMessage(text: "Want me to set up Saturday? Squats 5x5 at 185, then a 20 minute tabata, done by 10.",
                                fromUser: false)]
        }
        // -yuiLongThread <n>: n back-and-forth messages, enough to scroll (YUI-50).
        let long = UserDefaults.standard.integer(forKey: "yuiLongThread")
        if long > 0 {
            return (1...long).map { i in
                i.isMultiple(of: 2)
                    ? ChatMessage(text: "Message \(i). Here's a longer answer so the thread fills the screen the way a real one does.",
                                  fromUser: false)
                    : ChatMessage(text: "Message \(i)", fromUser: true)
            }
        }
        // -yuiDemoMarkdown: a /status answer and one of each markdown element, drawn (YUI-76).
        if ProcessInfo.processInfo.arguments.contains("-yuiDemoMarkdown") {
            return [ChatMessage(text: "/status", fromUser: true),
                    ChatMessage(text: statusAnswer, fromUser: false),
                    ChatMessage(text: "Show me **everything** you can format", fromUser: true),
                    ChatMessage(text: markdownSample, fromUser: false)]
        }
        // -yuiDemoHold: things to hold (YUI-78): a short answer at the top, a checklist
        // taller than the screen (under the fold count, so it stays whole), a card,
        // and a short answer at the bottom.
        if ProcessInfo.processInfo.arguments.contains("-yuiDemoHold") {
            return [ChatMessage(text: "Morning! Ready when you are.", fromUser: false),
                    ChatMessage(text: "What's left before the build?", fromUser: true),
                    ChatMessage(text: holdChecklist, fromUser: false),
                    ChatMessage(text: "Show me everything you can draw", fromUser: true),
                    ChatMessage(text: "", fromUser: false, yl: YLScreen(YLSamples.text("tour") ?? "")),
                    ChatMessage(text: "Anything else?", fromUser: true),
                    ChatMessage(text: "Last one: the hold menu fits now.", fromUser: false)]
        }
        // -yuiDemoLong: a short answer, then the long report that folds into pages (YUI-79).
        if ProcessInfo.processInfo.arguments.contains("-yuiDemoLong") {
            return [ChatMessage(text: "How did the A2A bridge go?", fromUser: true),
                    ChatMessage(text: "It went well. Every test is green and the phone run passed in light and dark. Want the whole report?",
                                fromUser: false),
                    ChatMessage(text: "Yes, all of it", fromUser: true),
                    ChatMessage(text: longReport, fromUser: false)]
        }
        // -yuiDemoPages: the build 96 feedback message that folds, the pages drawn (YUI-84), and a build-ready deck (YUI-82).
        if ProcessInfo.processInfo.arguments.contains("-yuiDemoPages") {
            return [ChatMessage(text: "Can the build pages read better?", fromUser: true),
                    ChatMessage(text: cardedAnswer, fromUser: false),
                    ChatMessage(text: "Show me what no ids means", fromUser: true),
                    ChatMessage(text: "", fromUser: false, yl: YLScreen(drawnPages)),
                    ChatMessage(text: "And the build ping?", fromUser: true),
                    ChatMessage(text: "Yui build 96 is ready in TestFlight.", fromUser: false),
                    ChatMessage(text: "", fromUser: false, yl: YLScreen(buildReady))]
        }
        // -yuiDemoRestyle: an agent offers Yui a new look twice (YUI-96): the first card
        // retired, the second the live preview.
        if ProcessInfo.processInfo.arguments.contains("-yuiDemoRestyle") {
            return [ChatMessage(text: "Can Yui look cooler?", fromUser: true),
                    ChatMessage(text: "", fromUser: false, yl: YLScreen("say Ocean, maybe?\ntheme app ocean")),
                    ChatMessage(text: "Warmer. Make Yui feel like autumn", fromUser: true),
                    ChatMessage(text: "", fromUser: false,
                                yl: YLScreen("say Here's autumn, next to Yui as it is now.\ntheme app autumn"))]
        }
        // -yuiDemoUnknown: a reply with presets from a newer Yui (beta feedback ANJPrtB7CHynwGR5mqNVPSM).
        if ProcessInfo.processInfo.arguments.contains("-yuiDemoUnknown") {
            return [ChatMessage(text: "What changed on the INT-7 ask?", fromUser: true),
                    ChatMessage(text: "", fromUser: false, yl: YLScreen(newerPresets))]
        }
        if let name = UserDefaults.standard.string(forKey: "yuiYL"), let text = YLSamples.text(name) {
            return [ChatMessage(text: "Show me the \(name) one", fromUser: true),
                    ChatMessage(text: "", fromUser: false, yl: YLScreen(text))]
        }
        return ProcessInfo.processInfo.arguments.contains("-yuiDemo") ? demo : []
    }
}

/// An agent reply in Yui Lines: the presets in line order, errors underneath.
/// Components that open on the stage show here as one pill that reopens it.
/// Hold it for reactions and Reply, Copy, Select text; swipe it left to reply (YUI-68).
private struct YLReply: View {
    let screen: YLScreen
    let scope: String
    var agent: YuiAgent?
    var style: [String: String] = [:]
    var reaction: Reaction?
    var lifted = false
    var reduceMotion = false
    var open: () -> Void = {}
    var react: (Reaction?) -> Void = { _ in }
    var select: () -> Void = {}
    var reply: () -> Void = {}
    let openStage: () -> Void
    @Environment(\.yuiTheme) private var theme

    var body: some View {
        let words = ReplyQuote.words(screen)
        HStack(alignment: .top, spacing: theme.spacing.s) {
            // VoiceOver: the card's Reply, reactions, Copy and Select text sit on the face beside it.
            AgentFace(agent: agent)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(agent?.name ?? "Yui")'s screen\(words.isEmpty ? "" : ", " + ReplyQuote.firstLine(words))")
                .accessibilityValue(reaction.map { "Reacted \($0.emoji), \($0.meaning)" } ?? "")
                .accessibilityActions {
                    ReactActions(text: words, reaction: reaction, react: react, select: select, reply: reply)
                }
            VStack(alignment: .leading, spacing: theme.spacing.m) {
                YLReplyItems(screen: screen, scope: scope, style: style, openStage: openStage)
                    .modifier(Reactable(text: words, reaction: reaction, lifted: lifted,
                                        open: open, react: react, select: select, reply: reply, card: true))
                    .modifier(SwipeToReply(reply: reply, reduceMotion: reduceMotion))
                // Presets this build can't draw fold into one Update chip, never raw lines (ANJPrtB7CHynwGR5mqNVPSM).
                if screen.errors.contains(where: UpdateChip.covers) { UpdateChip() }
                ForEach(Array(screen.errors.filter { !UpdateChip.covers($0) }.enumerated()), id: \.offset) {
                    YLErrorRow(node: $1)
                }
                ForEach(Array(screen.looks.enumerated()), id: \.offset) { _ in LookNote(agent: agent) }
                // Yui's own look, offered (RESTYLE.md). A shared agent never restyles: nothing drawn.
                if let props = screen.restyle, agent?.isShared != true {
                    RestyleCard(props: props, scope: scope, agent: agent)
                }
            }
            .environment(\.ylScope, scope)
            .environment(\.ylComponents, screen.components)
        }
        .transition(.opacity)
    }
}

/// A reply's presets in line order: in the thread, and lifted over it while held.
struct YLReplyItems: View {
    let screen: YLScreen
    let scope: String
    var style: [String: String] = [:]
    var openStage: () -> Void = {}
    @Environment(\.yuiTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.m) {
            YLItemsView(items: YLItem.layout(screen.top, pills: style), openStage: openStage)
        }
        .environment(\.ylScope, scope)
        .environment(\.ylComponents, screen.components)
    }
}

private struct Bubble: View {
    let message: ChatMessage
    var agent: YuiAgent?
    /// Still in the outbox: on the phone, not on Yui yet.
    var pending = false
    /// Agent bubbles: the reaction it wears, and the reaction bar (YUI-49).
    var reaction: Reaction?
    var lifted = false
    /// The system setting or `-yuiReduceMotion`: a left swipe doesn't slide the bubble.
    var reduceMotion = false
    var open: () -> Void = {}
    var react: (Reaction?) -> Void = { _ in }
    var select: () -> Void = {}
    /// Hold menu Reply or a left swipe (YUI-68).
    var reply: () -> Void = {}
    /// The chip on a sent reply: back to the message it quotes.
    var goToQuote: (ReplyQuote) -> Void = { _ in }
    /// Another agent's answer to a mention: opens its own thread (YUI-44).
    var openFrom: (() -> Void)? = nil
    /// "Read as pages" under a folded answer (YUI-79).
    var read: () -> Void = {}
    @Environment(\.yuiTheme) private var theme

    /// An agent's plain answer past `LongText.foldWords` folds: never a wall in the thread.
    /// Counted on the words as drawn, markdown marks off (YUI-76).
    static func folds(_ m: ChatMessage) -> Bool { !m.fromUser && m.yl == nil && LongText.folds(m.plain) }

    /// What the bubble shows: the words, or a folded answer's first sentences.
    static func shown(_ m: ChatMessage) -> String { folds(m) ? LongText.excerpt(m.plain) : m.text }

    /// The bubble for what shows: an agent's markdown drawn, an excerpt already plain.
    static func words(_ m: ChatMessage) -> BubbleText {
        BubbleText(text: shown(m), fromUser: m.fromUser, markdown: !m.fromUser && !folds(m))
    }

    var body: some View {
        if message.from != nil, let agent {
            // Another agent's answer: drawn in its own look, whatever thread it's in.
            content.environment(\.yuiTheme, agent.yuiTheme)
        } else {
            content
        }
    }

    /// The words in their bubble, holdable. VoiceOver reads what shows.
    private var text: some View {
        let shown = Self.folds(message) ? Self.shown(message) : message.plain
        return Self.words(message)
            .accessibilityLabel(pending ? "\(shown), not sent yet" : shown)
            .modifier(Reactable(text: message.words, reacts: !message.fromUser, reaction: reaction,
                                lifted: lifted, open: open, react: react, select: select, reply: reply))
    }

    private var content: some View {
        HStack(alignment: .bottom, spacing: theme.spacing.s) {
            if message.fromUser { Spacer(minLength: 48) } else { AgentFace(agent: agent) }
            VStack(alignment: message.from == nil ? .trailing : .leading, spacing: theme.spacing.xs) {
                if let from = message.from {
                    MentionHeader(from: from, open: openFrom)
                }
                if let label = message.mentionTo {
                    MentionChip(label: label)
                }
                if let n = message.fromScreen {
                    ScreenChip(screen: n)
                }
                if let q = message.replyTo {
                    ReplyChip(quote: q, agent: agent?.name) { goToQuote(q) }
                }
                ForEach(Array(message.photos.enumerated()), id: \.offset) { BubblePhoto(photo: $1) }
                if Self.folds(message) {
                    // Folded: the first sentences, then the whole answer a page at a time.
                    // Copy and Select text still get every word.
                    VStack(alignment: .leading, spacing: theme.spacing.s) {
                        text
                        ReadAsPages(pages: LongText.story(message.plain).count, action: read)
                    }
                } else if !message.text.isEmpty {
                    text
                }
            }
            .modifier(SwipeToReply(reply: reply, reduceMotion: reduceMotion))
            .opacity(pending ? 0.6 : 1)
            if !message.fromUser { Spacer(minLength: 48) }
        }
        .animation(.easeInOut(duration: 0.3), value: pending)
        .transition(reduceMotion ? .opacity : message.fromUser
            // Sent: lifts off the composer and floats up into the thread. Reduce Motion: a fade.
            ? .asymmetric(insertion: .offset(y: 56).combined(with: .scale(scale: 0.8, anchor: .bottomTrailing))
                .combined(with: .opacity), removal: .opacity)
            : .scale(scale: 0.85, anchor: .bottomLeading).combined(with: .opacity))
    }
}

/// Under a folded answer (YUI-79): the whole text as a deck on the stage, a page at a time.
private struct ReadAsPages: View {
    let pages: Int
    let action: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        Button(action: action) {
            HStack(spacing: theme.spacing.s) {
                Image(systemName: "rectangle.stack.fill")
                    .font(theme.font(theme.type.caption, .heavy))
                    .foregroundStyle(c.onAccent)
                    .frame(width: 30, height: 30)
                    .background(c.accent, in: Circle())
                Text("Read as pages")
                    .font(theme.font(theme.type.body, .bold))
                    .foregroundStyle(c.ink)
                Text("\(pages) pages")
                    .font(theme.font(theme.type.caption, .heavy))
                    .foregroundStyle(c.inkSoft)
            }
            .padding(.leading, theme.spacing.xs)
            .padding(.trailing, theme.spacing.m)
            .padding(.vertical, theme.spacing.xs)
            .background(c.surface, in: Capsule())
            .overlay(Capsule().stroke(c.outline, lineWidth: 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(BounceButtonStyle())
        .accessibilityLabel("Read as pages")
        .accessibilityValue("\(pages) pages")
        .accessibilityIdentifier("read-as-pages")
    }
}

/// Scrolled up in a long thread: one round arrow back to the newest message,
/// with a count of the agent's messages that arrived meanwhile (YUI-50).
private struct JumpToBottom: View {
    let unread: Int
    let action: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(theme.font(theme.type.body, .black))
                .foregroundStyle(c.ink)
                .frame(width: 44, height: 44)
                .background(c.surface, in: Circle())
                .overlay(Circle().stroke(c.outline, lineWidth: 1.5))
                .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.12), radius: 8, y: 3)
                .overlay(alignment: .topTrailing) {
                    if unread > 0 {
                        Text(unread > 99 ? "99+" : "\(unread)")
                            .font(theme.font(theme.type.caption, .black))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .foregroundStyle(c.onAccent)
                            .padding(.horizontal, 6)
                            .frame(minWidth: 22, minHeight: 22)
                            .background(c.accent, in: Capsule())
                            .overlay(Capsule().stroke(c.background, lineWidth: 2))
                            .offset(x: 8, y: -6)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
        }
        .buttonStyle(BounceButtonStyle())
        .accessibilityLabel("Jump to newest")
        .accessibilityValue(unread > 0 ? "\(unread) new" : "")
        .accessibilityIdentifier("jump-to-bottom")
    }
}

/// A `theme` line landed: one quiet line, the new look does the talking.
private struct LookNote: View {
    var agent: YuiAgent?
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        Label("\(agent?.name ?? "Yui") changed its look", systemImage: "paintbrush.pointed.fill")
            .font(theme.font(theme.type.caption, .bold))
            .foregroundStyle(c.inkSoft)
            .padding(.horizontal, theme.spacing.m)
            .padding(.vertical, theme.spacing.s)
            .background(c.surface, in: Capsule())
            .overlay(Capsule().stroke(c.outline, lineWidth: 1))
    }
}

/// The agent's face next to its messages: its badge, or Yui's mark in the demo.
private struct AgentFace: View {
    var agent: YuiAgent?
    var body: some View {
        if let agent { AgentBadge(agent: agent, size: 34) } else { YuiAvatar(size: 34) }
    }
}

/// Sent to an agent whose gateway hasn't started (YUI-64): it waits, and here's
/// the one command that starts it. Replaces the working row, which would count forever.
private struct ListeningNote: View {
    let agent: YuiAgent
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .trailing, spacing: theme.spacing.s) {
            Label("\(agent.name) isn't listening yet. This waits and goes the moment its gateway starts.",
                  systemImage: "hourglass")
                .font(theme.font(theme.type.caption, .semibold))
                .foregroundStyle(theme.swatch(scheme).inkSoft)
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier("quiet-note")
            CommandBox(command: agent.restartCommand)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .transition(.opacity)
    }
}

/// One quiet status line in the thread: not sent yet, the agent is asleep.
private struct QuietNote: View {
    let text: String
    let icon: String
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Label(text, systemImage: icon)
            .font(theme.font(theme.type.caption, .semibold))
            .foregroundStyle(theme.swatch(scheme).inkSoft)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .transition(.opacity)
            .accessibilityIdentifier("quiet-note")
    }
}

private struct EmptyChat: View {
    var agent: YuiAgent? = nil
    var loading = false
    /// A starter tap sends it as your first message.
    var send: (String) -> Void = { _ in }
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        if loading {
            ProgressView().tint(c.inkSoft)
        } else if let agent, agent.avatar != "yui" {
            VStack(spacing: theme.spacing.l) {
                AgentBadge(agent: agent, size: 96)
                Text("Say hi to \(agent.name)!")
                    .font(theme.font(theme.type.display, theme.strong))
                    .foregroundStyle(c.ink)
                    .multilineTextAlignment(.center)
                Text(agent.liveness == .notListening ?
                        "\(agent.name) isn't listening yet. Messages wait until its gateway starts.\nOn its computer, run \(agent.restartCommand)." :
                        agent.liveness == .asleep ?
                        "\(agent.name) is asleep right now. Messages wait and arrive when its computer wakes." :
                        agent.liveness == .offline ?
                        "\(agent.name) is offline right now. Messages wait until it's back.\nTo wake it, run hermes gateway restart on its computer." :
                        "Same agent as everywhere else,\nnow with buttons.")
                    .font(theme.font(theme.type.body))
                    .foregroundStyle(c.inkSoft)
                    .multilineTextAlignment(.center)
                HStack(spacing: theme.spacing.s) {
                    ForEach(["Hi!", "What can you show me?"], id: \.self) { text in
                        Button { send(text) } label: { Chip(text: text, color: c.surface, outline: c.outline) }
                            .buttonStyle(BounceButtonStyle())
                    }
                }
                .padding(.top, theme.spacing.s)
            }
            .padding(theme.spacing.xl)
        } else {
            greeting(c)
        }
    }

    private func greeting(_ c: Swatch) -> some View {
        VStack(spacing: theme.spacing.l) {
            Wordmark(height: 110)
                .phaseAnimator([false, true]) { view, up in
                    view.offset(y: up ? -6 : 0)
                } animation: { _ in .easeInOut(duration: 1.1) }
            Text("is here, and happy to see you!")
                .font(theme.font(theme.type.display, theme.strong))
                .foregroundStyle(c.ink)
                .multilineTextAlignment(.center)
            Text("Say hi, ask a question, or tell me\nwhat you want to get done.")
                .font(theme.font(theme.type.body))
                .foregroundStyle(c.inkSoft)
                .multilineTextAlignment(.center)
            HStack(spacing: theme.spacing.s) {
                Chip(text: "Plan my day", color: c.mint)
                Chip(text: "Start a timer", color: c.butter)
                Chip(text: "Surprise me", color: c.lavender)
            }
            .padding(.top, theme.spacing.s)
        }
        .padding(theme.spacing.xl)
    }
}

private struct Chip: View {
    let text: String
    let color: Color
    /// Set: an outlined chip in the scheme's own ink (a tappable starter).
    var outline: Color? = nil
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(text)
            .font(theme.font(theme.type.caption, .bold))
            .foregroundStyle(outline == nil ? Color(hex: theme.light.ink) : theme.swatch(scheme).ink)
            .padding(.horizontal, theme.spacing.m)
            .padding(.vertical, theme.spacing.s)
            .background(color, in: Capsule())
            .overlay(Capsule().stroke(outline ?? .clear, lineWidth: 1.5))
    }
}

/// A new account: no agents yet. Says what Yui needs and the one next step.
private struct FirstRun: View {
    let loaded: Bool
    let error: String?
    let add: () -> Void
    let retry: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        if !loaded, error == nil {
            ProgressView().tint(c.inkSoft)
        } else if !loaded {
            VStack(spacing: theme.spacing.m) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 40, weight: .bold)).foregroundStyle(c.inkSoft)
                Text("Couldn't load your agents")
                    .font(theme.font(theme.type.title, .bold)).foregroundStyle(c.ink)
                Text("Check your connection, then try again.")
                    .font(theme.font(theme.type.body)).foregroundStyle(c.inkSoft)
                PillButton(title: "Try again", systemImage: "arrow.clockwise", action: retry)
            }
            .multilineTextAlignment(.center)
            .padding(theme.spacing.xl)
        } else {
            VStack(spacing: theme.spacing.l) {
                Spacer(minLength: 0)
                Wordmark(height: 90)
                Text("Let's connect your first agent")
                    .font(theme.font(theme.type.display, theme.strong)).foregroundStyle(c.ink)
                Text("Yui is where your own agent answers you, with screens you can tap. It runs on your computer, like a Hermes profile, and connecting it takes about five minutes.")
                    .font(theme.font(theme.type.body)).foregroundStyle(c.inkSoft)
                VStack(alignment: .leading, spacing: theme.spacing.s) {
                    row(1, "Add an agent here and get a code")
                    row(2, "Run three commands on your computer")
                    row(3, "Say hi")
                }
                .padding(theme.spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(c.surface, in: .rect(cornerRadius: theme.radius.card))
                .overlay(RoundedRectangle(cornerRadius: theme.radius.card).stroke(c.outline, lineWidth: 1.5))
                PillButton(title: "Add your first agent", systemImage: "plus", action: add)
                GuideLink()
                Spacer(minLength: 0)
            }
            .multilineTextAlignment(.center)
            .padding(theme.spacing.xl)
        }
    }

    private func row(_ n: Int, _ text: String) -> some View {
        let c = theme.swatch(scheme)
        return HStack(spacing: theme.spacing.m) {
            Text("\(n)")
                .font(theme.font(theme.type.caption, .black)).foregroundStyle(c.onAccent)
                .frame(width: 24, height: 24)
                .background(c.accent, in: Circle())
            Text(text).font(theme.font(theme.type.body, .semibold)).foregroundStyle(c.ink)
                .multilineTextAlignment(.leading)
        }
    }
}

/// The agent owes a reply: one row, its face, a small moving mark and one
/// line, a working word and the time ("Pondering · 12s"). Before the host
/// picks it up it is "On its way". Long turns are normal (TestFlight: "assume
/// it's always going to take a little while"), so there is no time limit and
/// no fix-it advice here; an agent whose computer is away gets its own
/// asleep/offline note instead. Later the host's own few words take the
/// word's place (YUI-63 step 2).
struct WorkingNote: View {
    var agent: YuiAgent?
    var since: Date?
    var pickedUp: Date?
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool {
        systemReduceMotion || ProcessInfo.processInfo.arguments.contains("-yuiReduceMotion")
    }

    /// Friendly, short, no AI talk. One at a time, in this order.
    static let words = ["Pondering", "Figuring it out", "Mulling it over", "Tinkering",
                        "Piecing it together", "Working on it", "Noodling", "Almost there, maybe"]
    /// Seconds each word stays.
    static let wordEvery: TimeInterval = 4

    /// The word for this moment of the turn: "On its way" until the host picks it up.
    static func word(pickedUp: Date?, now: Date) -> String {
        guard let pickedUp else { return "On its way" }
        let n = Int(max(0, now.timeIntervalSince(pickedUp)) / wordEvery)
        return words[n % words.count]
    }

    /// "Pondering · 1m 24s", or "On its way · 3s" before pickup.
    static func label(since: Date?, pickedUp: Date?, now: Date) -> String {
        let word = Self.word(pickedUp: pickedUp, now: now)
        guard let start = pickedUp ?? since else { return word }
        return "\(word) · \(elapsed(now.timeIntervalSince(start)))"
    }

    /// 12s, 1m 24s, 1h 3m.
    static func elapsed(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }

    /// After this long, add that it's fine to leave.
    static let longTurn: TimeInterval = 120

    var body: some View {
        let c = theme.swatch(scheme)
        let name = agent?.name ?? "Your agent"
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let word = Self.word(pickedUp: pickedUp, now: ctx.date)
            let took = (pickedUp ?? since).map { Self.elapsed(ctx.date.timeIntervalSince($0)) }
            HStack(alignment: .top, spacing: theme.spacing.s) {
                AgentFace(agent: agent)
                VStack(alignment: .leading, spacing: theme.spacing.xs) {
                    HStack(spacing: theme.spacing.s) {
                        Dots(color: c.accent, still: reduceMotion)
                        HStack(spacing: 0) {
                            Text(word)
                                .id(word)
                                .transition(reduceMotion ? .identity : .push(from: .bottom).combined(with: .opacity))
                            if let took {
                                Text(" · \(took)")
                                    .monospacedDigit()
                                    .contentTransition(reduceMotion ? .identity : .numericText())
                            }
                        }
                        .foregroundStyle(c.inkSoft)
                        .animation(reduceMotion ? nil : .snappy, value: word)
                    }
                    .font(theme.font(theme.type.caption, .semibold))
                    .padding(.horizontal, theme.spacing.m)
                    .padding(.vertical, theme.spacing.s + 2)
                    .background(c.agentBubble, in: RoundedRectangle(cornerRadius: theme.radius.bubble))
                    .overlay(RoundedRectangle(cornerRadius: theme.radius.bubble).stroke(c.outline, lineWidth: 1.5))
                    if let start = pickedUp ?? since, ctx.date.timeIntervalSince(start) > Self.longTurn {
                        Text("Long jobs are fine. Leave any time, the answer lands here.")
                            .font(theme.font(theme.type.caption, .semibold))
                            .foregroundStyle(c.inkSoft)
                            .padding(.leading, theme.spacing.xs)
                            .transition(.opacity)
                    }
                }
                Spacer(minLength: 48)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibility(name: name, label: Self.label(since: since, pickedUp: pickedUp, now: ctx.date),
                                                   long: (pickedUp ?? since).map { ctx.date.timeIntervalSince($0) > Self.longTurn } ?? false))
            .accessibilityIdentifier("working")
        }
        .transition(.opacity)
    }

    /// VoiceOver: who, then the row. "Yui: Pondering · 12s".
    static func accessibility(name: String, label: String, long: Bool) -> String {
        "\(name): \(label)" + (long ? ". Long jobs are fine. Leave any time, the answer lands here." : "")
    }

    /// Three small dots that breathe; still under Reduce Motion.
    private struct Dots: View {
        let color: Color
        let still: Bool
        var body: some View {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    if still {
                        Circle().fill(color).frame(width: 5, height: 5)
                    } else {
                        Circle().fill(color).frame(width: 5, height: 5)
                            .phaseAnimator([0.3, 1.0]) { dot, o in dot.opacity(o) } animation: { _ in
                                .easeInOut(duration: 0.5).delay(Double(i) * 0.15)
                            }
                    }
                }
            }
            .accessibilityHidden(true)
        }
    }
}
