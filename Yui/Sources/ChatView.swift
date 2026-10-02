import PhotosUI
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import YuiLines

/// The chat with the selected agent (one thread per agent, over the relay).
/// Agent replies in Yui Lines render inline as presets.
struct ChatView: View {
    #if DEBUG
    /// -yuiComposerPhoto has placed its photo (once per launch).
    @MainActor static var composerPhotoPlaced = false
    #endif
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(Account.self) private var account
    @Environment(AgentStore.self) private var agents
    @Environment(PushCenter.self) private var push
    @Environment(GroupStore.self) private var groups
    @Environment(\.agentStyle) private var agentStyle
    /// Yui's own look (RESTYLE.md): sheets and Settings wear it, not the open agent's.
    @Environment(\.appTheme) private var appTheme
    /// The words being typed (YUI-99). Only the composer's views read them, so a
    /// key never re-evaluates this body; `send()` and friends read them when they run.
    @State private var composer = ComposerModel()
    @State private var store = ChatStore(messages: ChatView.seed)
    @State private var outbox = Outbox.shared
    /// "Pin as widget" on the shelf: the saved screen the two steps are for (YUI-40).
    @State private var pinning: PinName?
    /// A widget tap's saved screen, waiting for its thread (YUI-40).
    @State private var showLanding: (agent: String, name: String)?
    /// The Talk to Yui control (YUI-40): this agent's thread opens with hands-free voice on.
    @State private var talkLanding: String?
    @State private var snapLanding: String?
    @State private var showSettings = ProcessInfo.processInfo.arguments.contains("-yuiSettings")
    /// A section to scroll to when Settings opens from a link (`yui://settings/search`).
    @State private var settingsFocus: String?
    @State private var settingsDetent: PresentationDetent =
        ProcessInfo.processInfo.arguments.contains("-yuiSettingsLarge") ? .large : .medium
    @State private var showAgents = ProcessInfo.processInfo.arguments.contains("-yuiAgents")
    /// The agent's drawer (YUI-54): open, and where a drag has it (points from its resting place).
    @State private var drawerOpen = ProcessInfo.processInfo.arguments.contains("-yuiDrawer")
    /// Only the drawer's own layer reads the drag, so a drag frame never re-runs this body (YUI-101).
    @State private var drawerMotion = DrawerMotion()
    /// Controls, "Name, look and notifications": that agent's edit sheet.
    @State private var editingAgent: YuiAgent?
    /// The chip's item, open read only (YUI-69).
    @State private var aboutOpen: TalkItem?
    /// The first-run button opens Add agent straight from the chat.
    @State private var addFirst = false
    /// A new account picks its crew before anything else (YUI-216).
    @State private var pickCrew = false
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
    /// Hold to snap and say (YUI-166): the camera and the mic, one press.
    @State private var snapping = false
    /// + > Files: pictures from Files join the message like photos (YUI-121).
    @State private var importingFiles = false
    @State private var sending = false
    @State private var talk = PushToTalk()
    /// Hands-free (YUI-14): tap the mic once and it stays open between turns.
    @State private var handsFree = HandsFree()
    @State private var handsFreeWatch: Task<Void, Never>?
    /// The words hands-free is sending, shown while they go.
    @State private var handsFreeWords = ""
    @Environment(\.scenePhase) private var scenePhase
    /// Hold to talk: the finger's sideways travel while it is on the mic, nil when it is up.
    @GestureState private var micPress: CGFloat?
    @State private var micHeld = false
    /// How far left the finger is, 0 or less. Past `cancelDistance` the trash is armed.
    @State private var micDragX: CGFloat = 0
    /// start() is still asking for the mic or warming up.
    @State private var micStarting = false
    @State private var holdStart: Task<Void, Never>?
    /// The bar's mic went down while hands-free was on: its let-go is a tap, never a hold.
    @State private var micTapOnly = false
    /// How far up the finger is, 0 or more. Past `lockDistance` (and not on the trash) the lock is armed.
    @State private var micLift: CGFloat = 0
    private static var cancelDistance: CGFloat {
        BarButtons.trashReach(width: UIScreen.main.bounds.width, inset: 16)
    }
    private static let lockDistance: CGFloat = 80
    private var cancelArmed: Bool { talk.listening && micDragX <= -Self.cancelDistance }
    private var lockArmed: Bool { talk.listening && !handsFree.on && !cancelArmed && micLift >= Self.lockDistance }
    @State private var composerNote: String?
    /// Key-shaped words in the composer, held (YUI-34): Move it to Keys, or Send anyway for a mere lookalike.
    @State private var keyHeld: KeyShape?
    @State private var keySendAnyway = false
    @State private var keyMove: KeyShape?
    /// A word in plain language over the top of the screen (a chat Yui refused), for a few seconds.
    @State private var chatNotice: String?
    /// Stage first (YUI-119): Yui lives on the full screen and the chat is the record.
    @State private var stageFirst = StageFirstModel()
    /// A notification tap waiting for its thread to load: the agent and the message it came with (YUI-199).
    @State private var pushLanding: (agent: String, message: String?, since: Date)?
    /// The agent whose pending first plan this open thread already landed on (YUI-231).
    @State private var firstPlanLanded: String?
    @AppStorage(StageFirstModel.key) private var stageFirstStored = true
    @AppStorage(StageFirstModel.micKey) private var stageMic = true
    @AppStorage(StageFirstModel.typeKey) private var stageType = true
    @AppStorage(StageFirstModel.attachKey) private var stageAttach = true
    /// The stage's own T field: the chat's composer keeps `focused`.
    @FocusState private var stageFocused: Bool
    /// The record's T is out (YUI-121): the whole field, until a tap away folds it.
    @State private var recordTyping = false
    /// The record shows the bar (mic, T, +) in place of the field.
    private var recordBar: Bool { stageFirstOn && talkPage == nil && !recordTyping }
    private var stageFirstOn: Bool { StageFirstModel.enabled(stored: stageFirstStored) }
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
    /// How many of the newest rows the thread draws (YUI-101). A long thread opens
    /// on its last screens only; scrolling near the top draws the next batch above,
    /// and the bottom anchor keeps what you are reading where it is.
    @State private var window = Self.windowStep
    @State private var nearTop = false
    /// One older batch per arrival at the top; the next drag or a trip away re-arms it (YUI-260).
    @State private var topGrown = false
    static let windowStep = 60
    /// The page on show (YUI-31): 1 the chat, 2 to 12 the agent's screens. Follows `store.page`.
    @State private var page: Int? = 1
    /// Reduce Motion: pages cross-fade instead of sliding.
    @State private var pageFade = 1.0
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// The system setting, or `-yuiReduceMotion` for UI tests (a simulator can't flip it).
    private var reduceMotion: Bool {
        systemReduceMotion || ProcessInfo.processInfo.arguments.contains("-yuiReduceMotion")
    }

    /// The chat pages sideways to the agent's screens only with stage first off. With it on
    /// (Chris, 2026-09-27: "The chat is just the chat ... I want that navigation on the full
    /// screen view"), the screens and their dots live on the stage and the chat is one page.
    private var pagedChat: Bool { !stageFirstOn }

    /// The chat is on show (not a screen, and not the first run's welcome).
    private var onChat: Bool { firstRun || !pagedChat || (page ?? 1) == 1 }

    /// The screen on show when the agent keeps the composer on it (`>2 talk`, YUI-62).
    private var talkPage: Int? {
        let n = page ?? 1
        if !pagedChat && !stageFirst.open { return nil }  // the chat is one page: nothing to talk about there
        return !firstRun && n != 1 && store.talks(on: n) ? n : nil
    }

    /// The composer is here: the chat, or a screen the agent talks on.
    private var composing: Bool { onChat || talkPage != nil }

    var body: some View {
        chatBody
        // A quick action on the icon (YUI-191): that agent's thread, its words sent as if typed.
        .onChange(of: QuickActionTap.shared.pending, initial: true) { openQuickAction() }
        .onChange(of: store.loaded ? store.agent?.id : nil) { sendQuickAction() }
        // The icon menu follows the drawer: a new or finished shortcut redraws it.
        .onChange(of: store.menu) { QuickActions.refresh(agents: agents.agents, signedIn: account.isSignedIn) }
    }

    @ViewBuilder private var chatBody: some View {
        let c = theme.swatch(scheme)
        let _ = BodyLog.hit("ChatView")
        // The layers and the thread are erased (AnyView): as one type, the body nested
        // 129 deep and the runtime ran the phone's 1 MB main stack out building it
        // (build 229, feedback AGjOqLXN). ViewTypeDepthTests keeps it shallow.
        AnyView(ZStack {
        NavigationStack {
            Group {
                if firstRun {
                    FirstRun(loaded: agents.loaded, error: agents.error, crew: agents.crew) {
                        addFirst = true
                    } retry: {
                        Task { await agents.refresh() }
                    }
                } else {
                    // The chat, then each screen the agent put something on, a swipe apart (YUI-31).
                    // Stage first: just the chat; the screens are on the stage.
                    PagedThread(store: store, screens: pagedChat ? store.screens : [1], page: pagedChat ? $page : .constant(1),
                                fade: pageFade, agent: store.agent, style: agentStyle) { AnyView(thread) }
                        // Drag right on the chat: the drawer follows the finger (YUI-54). On a
                        // screen the pager is scrolled along, so the drag pages back instead.
                        // The record's field is out: a tap on the thread lets the keyboard go and folds it (YUI-121).
                        .simultaneousGesture(TapGesture().onEnded { focused = false },
                                             including: stageFirstOn && recordTyping ? .all : .subviews)
                        .gesture(DrawerPan(direction: .right, enabled: !drawerOpen && !store.stageShowing) { x in
                            focused = false
                            drawerMotion.drag = max(0, x)
                        } ended: { x, v in
                            settleDrawer(open: x > drawerWidth * Drawer.threshold || v > Drawer.flick)
                        })
                        // Stage first: the screens are on the full screen, so a drag left on the
                        // chat opens it on the first of them (feedback AC0r0OFGJiJOcbFdbXMgHms).
                        .gesture(DrawerPan(direction: .left, enabled: !pagedChat && !drawerOpen && store.screens.count > 1) { _ in
                        } ended: { x, v in
                            guard StageFirstView.turns(x, v, by: -1), let next = store.screens.first(where: { $0 > 1 }) else { return }
                            focused = false
                            store.goToPage(next)
                            openStageFirst()
                        })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(c.background)
            // A screen is full screen, but it is not a dead end (YUI-235): a plan lands the pager on
            // its last screen, and the nav bar is off there, so the drawer and the chat were pages away.
            .overlay(alignment: .top) {
                if pagedChat, !onChat, !firstRun { screenBar(c) }
            }
            .safeAreaInset(edge: .bottom) {
                if !firstRun {
                    VStack(spacing: theme.spacing.s) {
                        // No dots (YUI-168, Chris: "let the user rely on instinct that they can
                        // swipe"): VoiceOver still hears where it is and pages with a swipe up or down.
                        let screens = store.screens
                        if pagedChat, screens.count > 1 {
                            PagePosition(page: page ?? 1, screens: screens, first: "Chat") { store.goToPage($0) }
                        }
                        // Screens are for reading: the composer stays with the chat,
                        // unless the agent keeps it on this screen (`>2 talk`).
                        if composing {
                            // Erased: its type nested under the body's ran the phone's
                            // main stack out when the runtime built it (feedback AGjOqLXN).
                            AnyView(inputBar(c))
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
            // The top bar (YUI-122): the menu and who you talk to top left. The title is plain; the drawer is the one picker.
            // Settings is in the menu's drawer; top right is the way back to the full screen.
            .toolbar {
                menuItem(c)
                ToolbarItem(placement: .topBarLeading) {
                    AgentTitle(agent: store.agent, title: store.chatTitle)
                }
                if stageFirstOn {
                    // The record's way back to the full screen (YUI-119).
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Full screen", systemImage: "arrow.up.left.and.arrow.down.right") { openStageFirst() }
                            .tint(c.inkSoft)
                            .accessibilityIdentifier("back-to-stage")
                    }
                }
                // The pen on a page: a new chat (YUI-169). The chat you are in is the record.
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New chat", systemImage: "square.and.pencil") { startNewChat() }
                        .tint(c.inkSoft)
                        .accessibilityIdentifier("record-new-chat")
                }
            }
            .toolbarBackground(c.background, for: .navigationBar)
            // A screen is full screen: the agent switcher and settings stay with the chat.
            // No agents yet: no agent picker or menu, nothing looks signed in to a thread (feedback AFFVLA66).
            .toolbar(onChat && !firstRun ? .visible : .hidden, for: .navigationBar)
            .animation(theme.spring, value: onChat)
            .sheet(isPresented: $showSettings) {
                SettingsView(focus: settingsFocus)
                    .presentationDetents([.medium, .large], selection: $settingsDetent)
                    .presentationCornerRadius(appTheme.radius.card)
                    .environment(\.yuiTheme, appTheme)
            }
            .sheet(item: $pinning) { name in
                PinWidgetSheet(name: name.id, agent: store.agent?.name ?? "your agent")
                    .presentationDetents([.medium])
                    .presentationCornerRadius(theme.radius.card)
            }
            .sheet(item: $keyMove) { shape in
                KeyMoveSheet(text: shape.key) {
                    composer.draft = composer.draft.replacingOccurrences(of: shape.key, with: "")
                    keyHeld = nil
                }
                .environment(\.yuiTheme, appTheme)
            }
            .sheet(item: Binding(get: { store.keyAsk }, set: { store.keyAsk = $0 })) { ask in
                KeyAskSheet(ask: ask, agent: store.agent) { answer in await store.answerKeyAsk(answer, purpose: ask.purpose) }
                    .presentationDetents([.medium, .large])
                    .presentationCornerRadius(appTheme.radius.card)
                    .environment(\.yuiTheme, appTheme)
            }
            .onChange(of: agents.crewPending, initial: true) { _, pending in
                if pending { pickCrew = true }
            }
            .fullScreenCover(isPresented: $pickCrew) {
                CrewPickView { id in
                    if let id { agents.selectedID = id }
                    pickCrew = false
                    #if DEBUG
                    demoCrewHello()
                    #endif
                }
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
            .fullScreenCover(isPresented: Binding(get: { groups.openID != nil }, set: { if !$0 { groups.openID = nil } })) {
                if let id = groups.openID { GroupThreadView(groupID: id).environment(\.appTheme, appTheme) }
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
            .sheet(item: $aboutOpen) { item in
                AboutPreview(item: item)
                    .presentationDetents([.medium, .large])
                    .presentationCornerRadius(theme.radius.card)
            }
        }
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
                      sentAt: m.sentAt, close: store.closeStage)
                .environment(\.ylEmit, m.id == store.reading?.id ? ChatStore.quiet : store.emit)
                .environment(\.ylComponents, yl.components)
                .id(m.id)
                .transition(.opacity)
        }
        stageFirstHooks
        if stageFirstOn, stageFirst.open, !firstRun, store.agent != nil {
            stageFirstLayer
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .zIndex(2)
        }
        // Over the chat and over the full screen: both top bars open it (YUI-54, YUI-122).
        DrawerLayer(motion: drawerMotion, open: drawerOpen, shows: !firstRun, width: drawerWidth * Drawer.fraction,
                    reduceMotion: reduceMotion, settle: settleDrawer) { drawerContent }
            .zIndex(3)
        })
        .environment(\.ylEmit, store.emit)
        .environment(\.ylShow, store.ylShow)
        .environment(\.ylPage, store.ylPage)
        .environment(\.ylAnswers, store.ylAnswers)
        .environment(\.ylAgent, store.agent?.id ?? "")
        .environment(\.yuiMedia, store.agent.flatMap { a in account.session?.userID == "demo" ? nil : YuiMedia(account: account, agentID: a.id) })
        .environment(\.ylTimers, store.timers)
        .environment(\.restyleNewest, store.restyleNewest)
        .onChange(of: agentStyle, initial: true) { store.style = agentStyle }
        // The stage's reply went, or its screens stopped being staged: close it (YUI-80).
        .onChange(of: store.stageShowing) { store.settleStage() }
        // A full screen takes the keyboard down with it, however it opened: a tap, a pill,
        // the agent. Closing it leaves the keyboard down (feedback ACbsyYSZ).
        .onChange(of: store.stageOpen) { _, open in
            guard open else { return }
            focused = false
            Keyboard.dismiss()
        }
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
        // Talk about this (YUI-69): the item lands on the composer with the keyboard up.
        .onChange(of: store.about?.id) { _, new in if new != nil { typeHere() } }
        // Screens come and go: a page emptied by `>N clear` is gone, so back to the
        // chat; a page remembered for this agent shows once its history loads.
        // (A reply that adds a page turns to it through `pageTurns` above, after layout.)
        .onChange(of: store.screens) { if !store.screens.contains(store.page), store.loaded { store.goToPage(1) } }
        .onChange(of: store.loaded) { keepPage() }
        #if DEBUG
        // -yuiReactDemo bar|select|<meaning> ("love it"): the reaction bar open, Select text open, or a reacted bubble, for screenshots.
        .task { await Attachments.refreshLimit(account) }
        .task {
            guard let mode = UserDefaults.standard.string(forKey: "yuiReactDemo") else { return }
            try? await Task.sleep(for: .seconds(1))
            guard let m = store.messages.last(where: { !$0.fromUser && $0.yl == nil }) else { return }
            if mode == "select" { selecting = m; return }
            if mode == "bar" { openReactions(m.id) } else { store.react(m.id, with: Reaction.all.first { $0.meaning == mode } ?? Reaction.all[0]) }
        }
        // -yuiAutoScroll (YUI-101): 4 s after the thread shows, it scrolls itself up and
        // back the way a finger does, so frames can be timed with no test touching the app.
        .task(id: store.loaded) {
            guard store.loaded, ProcessInfo.processInfo.arguments.contains("-yuiAutoScroll"), !Self.autoScrolled else { return }
            Self.autoScrolled = true
            try? await Task.sleep(for: .seconds(4))
            AutoScroll.run()
        }
        // -yuiThemeDemo "say Autumn it is.\ntheme autumn": the agent restyles itself, live, for screenshots.
        // -yuiDemoPrompt "Tabata tonight?" puts the person's message above it, after
        // -yuiDemoDelay seconds [1.5] (demo clips wait for the recording to catch up).
        .task {
            guard let text = ChatStore.demoText("yuiThemeDemo") else { return }
            if let prompt = UserDefaults.standard.string(forKey: "yuiDemoPrompt") {
                let delay = UserDefaults.standard.object(forKey: "yuiDemoDelay") == nil
                    ? 1.5 : UserDefaults.standard.double(forKey: "yuiDemoDelay")
                try? await Task.sleep(for: .seconds(delay))
                var ask = ChatMessage(text: prompt, fromUser: true)
                // -yuiDemoPromptPhotos "URL URL": the person's message carries these photos (AM6xGDZ3 shots).
                for link in (UserDefaults.standard.string(forKey: "yuiDemoPromptPhotos") ?? "").split(separator: " ") {
                    if let url = URL(string: String(link)), let (data, _) = try? await URLSession.shared.data(from: url),
                       let image = UIImage(data: data) { ask.photos.append(.local(image)) }
                }
                withAnimation(theme.spring) { store.messages.append(ask) }
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
            guard let rows = Self.debugRows() else { return }
            store.load(rows)
            Perf.shared.threadShown()
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
                // An empty list is a new person whose crew is still being made: ask again soon.
                try? await Task.sleep(for: .seconds(agents.agents.isEmpty ? 3 : agents.selected?.liveness == .notListening ? 5 : 30))
            }
        }
        .onChange(of: agents.selected?.id, initial: true) { old, new in
            // A click still going is Gouda's practice: it goes to him before the thread moves on (YUI-184).
            if old != new { MusicHost.shared.leavingAgent() }
            // The demo account keeps the local demo chat, with the agent's face on it.
            if account.session?.userID == "demo" {
                store.demo(agents.selected)
                #if DEBUG
                // -yuiThreadRows: each thread switch loads the rows again, timed (YUI-101).
                // Not the first showing: that keeps the seeded chat the rows load under.
                if old != new, !store.messages.isEmpty, let rows = Self.debugRows() { store.reopen(rows) }
                // -yuiDemoFirstLaunch (YUI-145): each thread opens on the agent's first message,
                // the row yui_native_provision writes, so a new person lands on Yui talking.
                // Its home comes first (YUI-168), the row yui-agents writes. -yuiDemoHome alone: a
                // returning person's thread, the home and nothing said yet, no hello to play.
                let args = ProcessInfo.processInfo.arguments
                let firstLaunch = args.contains("-yuiDemoFirstLaunch"), homeOnly = args.contains("-yuiDemoHome")
                // A -yuiThreadRows file is the whole thread, its home row too (YUI-183: a relaunch mid-flow).
                if firstLaunch || homeOnly, Self.debugRows() == nil, old != new || store.messages.isEmpty, let a = agents.selected {
                    let at = ISO8601DateFormatter().string(from: .now)
                    var rows: [ThreadRow] = []
                    if let home = AgentStore.demoHome[a.handle] {
                        rows.append(ThreadRow(id: "home-\(a.handle)", sender: "agent", body: home, kind: "text",
                                              meta: .object(["native": .string("home")]), createdAt: at))
                    }
                    // -yuiDemoWaiting: two notes the agent put in Review, for the home's Waiting on you.
                    if args.contains("-yuiDemoWaiting") {
                        rows.append(ThreadRow(id: "waiting-\(a.handle)", sender: "agent", body: """
                            ```yui
                            menu review@sat "Saturday: legs or a rest day?" sub="You slept 5h last night"
                            menu review@max "New squat max?" sub="Last three sets looked easy"
                            ```
                            """, kind: "text", meta: .object(["native": .string("home")]), createdAt: at))
                    }
                    // Pick your crew (YUI-216): Yui's hello waits for the pick and names who joined.
                    if firstLaunch, !agents.crewPending, let first = AgentStore.demoFirst[a.handle] {
                        rows.append(ThreadRow(id: "first-\(a.handle)", sender: "agent", body: first, kind: "text",
                                              meta: .object(["native": .string("first")]), createdAt: at))
                    }
                    if !rows.isEmpty { store.reopen(rows) }
                }
                #endif
                return
            }
            store.attach(agents.selected, account: account)
        }
        .onChange(of: agents.selected) { store.refreshAgent(agents.selected) }
        .modifier(ChatsHooks(store: store, composer: composer, window: $window, pinned: $pinned, notice: $chatNotice,
                             phase: scenePhase))
        .onChange(of: store.agent?.id, initial: true) {
            push.visibleAgentID = store.agent?.id
            firstPlanLanded = nil
            window = Self.windowStep
            // Each thread keeps its own unsent words (feedback AK-9fNEZU), on every device the person signs in on (YUI-249).
            composer.attach(account: account)
            composer.show(agent: store.agent?.id)
        }
        // yui://settings/search (the invite to add a Firecrawl key, YUI-142): Settings, at that section.
        .onChange(of: push.pendingSettings, initial: true) {
            guard let section = push.pendingSettings else { return }
            push.pendingSettings = nil
            showAgents = false
            settleDrawer(open: false)
            settingsFocus = section.isEmpty ? nil : section
            settingsDetent = .large
            showSettings = true
        }
        .onChange(of: showSettings) { if !showSettings { settingsFocus = nil } }
        // A notification tap or yui://agent/<id>/thread: straight to that thread.
        .onChange(of: push.pendingAgentID, initial: true) { openPushedThread() }
        // ...and on the message that came (YUI-199), once that thread has loaded.
        .onChange(of: [store.loaded ? store.agent?.id : nil, store.messages.last?.id]) { landPushed(); landFirstPlan(); landShow(); landTalk(); landSnap(); landSetup() }
        .tint(c.accent)
    }

    /// A widget tap: the saved screen on the stage, with no turn, once that thread's shelf is in.
    private func landShow() {
        guard let want = showLanding, store.loaded, store.agent?.id == want.agent else { return }
        showLanding = nil
        if store.shelf[want.name] != nil { store.reopen(want.name) }
    }

    /// The Talk to Yui control: hands-free voice on, once that thread is up.
    private func landTalk() {
        guard let want = talkLanding, store.loaded, store.agent?.id == want else { return }
        talkLanding = nil
        if PushToTalk.allowed, !handsFree.on { handsFreeDo(.tap) }
    }

    /// Start blank (YUI-138): the setup flow's greeting is the agent's name, look and model arriving. Ask for the list
    /// at once, so the header and the drawer say who it is now, not on the next 30 s tick.
    private func landSetup() {
        guard let a = agents.selected, a.kind == "hosted", a.handle.hasPrefix("new"), a.name == "New agent",
              let last = store.messages.last, !last.fromUser, !last.hello, !last.home else { return }
        Task { await agents.refresh() }
    }

    /// Siri's Log my food: the camera, once that thread is up.
    private func landSnap() {
        guard let want = snapLanding, store.loaded, store.agent?.id == want else { return }
        snapLanding = nil
        settleDrawer(open: false)
        openSnap()
    }

    /// A notification tap or yui://agent/<id>/thread: straight to that thread (and chat).
    private func openPushedThread() {
            guard let id = push.pendingAgentID else { return }
            push.pendingAgentID = nil
            showAgents = false
            showSettings = false
            settleDrawer(open: false)
            // A hand-off card names the agent by handle (yui://agent/basil, YUI-144).
            let target = agents.idFor(id)
            // A widget tap names a saved screen: it goes on the stage, nothing else lands (YUI-40).
            if let name = push.pendingShow {
                push.pendingShow = nil
                showLanding = (agent: target, name: name)
                pushLanding = nil
            } else {
                pushLanding = (agent: target, message: push.pendingMessageID, since: .now)
            }
            push.pendingMessageID = nil
            if push.pendingTalk { push.pendingTalk = false; talkLanding = target }
            if push.pendingSnapAgent != nil { push.pendingSnapAgent = nil; snapLanding = target }
            // Siri's Start my workout: the same tap as the drawer's "Start a workout" on Arnold.
            if push.pendingWorkout {
                push.pendingWorkout = false
                QuickActionTap.shared.pending = QuickActionTap.Tap(agentID: target, itemID: "workout", say: "Start today's workout", label: "Start a workout")
            }
            // A push names the chat it came from (YUI-169): that one opens, not the newest.
            if let chat = push.pendingChatID {
                push.pendingChatID = nil
                store.wantedChat = chat
                if store.agent?.id == target { store.openPushed(chat) }
            }
            agents.selectedID = target
            if !agents.agents.contains(where: { $0.id == target }) { Task { await agents.refresh() } }
            if store.agent?.id == target { Task { await store.refresh(); landPushed() } }
            #if DEBUG
            // -yuiDemoHandoffReply "<lines>": on the demo account the agent handed to answers with these (YUI-144 shots).
            if account.session?.userID == "demo", let reply = UserDefaults.standard.string(forKey: "yuiDemoHandoffReply") {
                Task { try? await Task.sleep(for: .seconds(0.6)); store.demoAnswer(reply) }
            }
            #endif
    }

    /// A quick action tapped: go to its agent's thread, then send once that thread is up.
    private func openQuickAction() {
        guard let tap = QuickActionTap.shared.pending else { return }
        showAgents = false
        showSettings = false
        settleDrawer(open: false)
        let target = agents.idFor(tap.agentID)
        if agents.selectedID != target { agents.selectedID = target }
        if !agents.agents.contains(where: { $0.id == target }) { Task { await agents.refresh() } }
        sendQuickAction()
    }

    /// Same path as a drawer shortcut tap: words ending in a space fill the composer, the rest send.
    private func sendQuickAction() {
        guard let tap = QuickActionTap.shared.pending, store.loaded, store.agent?.id == agents.idFor(tap.agentID) else { return }
        QuickActionTap.shared.pending = nil
        // The words the icon showed win; the drawer's item adds `url=` and the rest.
        var item = store.menu.shortcuts.first { $0.id == tap.itemID } ?? YLMenuItem(id: tap.itemID, label: tap.label)
        if let say = tap.say { item.say = say }
        // The composer still holds the last thread's words: hand it this thread first, or its own draft wins.
        composer.show(agent: store.agent?.id)
        MenuAction.shortcut(item, store: store, compose: { composer.draft = $0; stageFirstOn && stageFirst.open ? typeOnStage() : typeHere() })
    }

    /// A tap on a notification lands on what came, not on the agent's home (YUI-199, Chris: "I was
    /// taken JUST to the home screen and nothing opened up"): the stage plays that message, or the
    /// newest thing the agent said when it is not in the thread. Waits for the thread to load.
    private func landPushed() {
        guard let want = pushLanding, store.loaded, store.agent?.id == want.agent else { return }
        // The message the push names has not reached the thread yet (a cold start, a slow fetch): wait for it,
        // never open the older turn in its place. After PushLanding.patience the newest thing said stands in.
        if let named = want.message, !store.messages.contains(where: { PushLanding.isRow($0.id, named) }),
           Date.now.timeIntervalSince(want.since) < PushLanding.patience {
            Task { try? await Task.sleep(for: .seconds(PushLanding.patience)); landPushed() }
            return
        }
        guard let id = PushLanding.message(store.messages, want: want.message) else { return }
        pushLanding = nil
        // A message with nothing staged (a hello's words, the plan is its next part) has nothing to open: opening
        // it would only pull the stage off the first plan `landFirstPlan` just put up, and settle shut (YUI-234).
        // With stage first the stage plays the reply's chunks, not its staged parts, so the guard is the chat's alone
        // (YUI-262: it left every stage-first tap on the home, whatever the reply held).
        guard stageFirstOn || store.messages.first(where: { $0.id == id })?.yl?.staged(store.style).isEmpty == false else { return }
        openStage(id, toPlan: true)
    }

    /// Something the agent said just landed in the thread on screen, and the stage is on the home (no turn
    /// playing, no field out, nothing else asked for): it comes up full screen on that message. The record
    /// (chat) and a turn already playing are left alone; another agent's thread only ever gets the badge.
    private func landArrival(after old: String?) {
        guard stageFirstOn, stageFirst.open, store.loaded, scenePhase == .active,
              stageFirst.ask == nil, stageFirst.hello == nil, !stageFirst.typing, !store.waiting, pushLanding == nil,
              !stageFocused, !focused, !showSettings, !showAgents else { return }
        // From an empty thread everything is new, so a history that just loaded must be told from a fresh row: by its age.
        let from = store.messages.lastIndex { $0.id == old }.map { $0 + 1 } ?? (old == nil ? 0 : store.messages.count)
        let added = store.messages[from...].filter { old != nil || $0.sentAt.timeIntervalSinceNow > -PushLanding.patience * 4 }
        guard let id = PushLanding.arrival(Array(added)) else { return }
        openStage(id)
    }

    /// A thread that opens with its first plan still to answer (chat first, YUI-231: Open on Yui's card, the
    /// agent bar, a relaunch) puts the first question on screen, not a collapsed "Your first plan" chip.
    /// Its Skip card stays in the record under it. Once per opening: closing the stage keeps it closed.
    /// Does not wait for the network (`loaded`): the hello is in the thread as soon as its rows are, and a slow
    /// refresh must not leave the chip collapsed.
    private func landFirstPlan() {
        guard !stageFirstOn, let agent = store.agent, firstPlanLanded != agent.id,
              !store.stageOpen, let id = PushLanding.firstPlan(store.messages, answered: { store.ylAnswers($0, $1)?["plan"] != nil })
        else { return }
        firstPlanLanded = agent.id
        openStage(id, toPlan: true)
    }

    // MARK: The agent's drawer (YUI-54)

    /// Top left: the drawer (the war room, the agent's controls, Settings), also a drag
    /// right on the chat away. Something waiting on you puts a dot on it (`WaitingDot`).
    /// VoiceOver still hears how many.
    private func menuItem(_ c: Swatch) -> some ToolbarContent {
        let n = store.waitingCount
        return ToolbarItem(placement: .topBarLeading) {
            Button { settleDrawer(open: true) } label: {
                Image(systemName: "line.3.horizontal")
                    .modifier(WaitingDot(waiting: n > 0, reduceMotion: reduceMotion))
            }
            .tint(c.inkSoft)
            .accessibilityLabel("Agent menu")
            .accessibilityValue(n > 0 ? "\(n) waiting on you" : "")
        }
    }

    /// The way out of a screen: the drawer top left, the chat top right.
    private func screenBar(_ c: Swatch) -> some View {
        func circle(_ icon: String, _ label: String, _ id: String, _ action: @escaping () -> Void) -> some View {
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
        return HStack {
            circle("line.3.horizontal", "Screen menu", "screen-menu") { settleDrawer(open: true) }
                .modifier(WaitingDot(waiting: store.waitingCount > 0, reduceMotion: reduceMotion))
            Spacer()
            circle("bubble.left", "Back to chat", "screen-back-to-chat") { store.goToPage(1) }
        }
        .padding(.horizontal, theme.spacing.l)
        .transition(.opacity)
    }

    private var drawerWidth: CGFloat { (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.width ?? 390 }

    /// Springs open or shut from wherever the finger let go. Reduce Motion: a fade.
    private func settleDrawer(open: Bool) {
        if open { focused = false }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : theme.spring) {
            drawerOpen = open
            drawerMotion.drag = nil
        }
    }

    /// The drawer shuts. Opened over the full screen (YUI-122), a row that went to a
    /// screen or a pinned full screen takes the person to the record, where those live.
    private func closeDrawer() {
        settleDrawer(open: false)
        guard stageFirstOn, stageFirst.open else { return }
        Task { @MainActor in
            await Task.yield()
            if store.page != 1 || store.stageOpen { closeStageFirst() }
        }
    }

    /// The drawer itself; `DrawerLayer` slides it and dims the chat.
    private var drawerContent: some View {
        AgentDrawer(store: store, agents: agents.agents, unshared: agents.unshared, close: closeDrawer,
                    pick: { agents.selectedID = $0 }, add: agents.onlyShared ? nil : { addFirst = true },
                    compose: { composer.draft = $0; stageFirstOn && stageFirst.open ? typeOnStage() : typeHere() },
                    manage: { settleDrawer(open: false); showAgents = true },
                    edit: { editingAgent = $0 },
                    settings: { settleDrawer(open: false); showSettings = true },
                    newChat: startNewChat, openChat: pickChat,
                    reduceMotion: reduceMotion, isOpen: drawerOpen)
    }

    // MARK: Chats (YUI-169)

    /// New chat: an empty one, nothing saved until something is said in it. With stage first it
    /// opens on the full screen, where the mic is; tapping again gives the same empty chat.
    private func startNewChat() {
        store.newChat()
        settleDrawer(open: false)
        focused = false
        store.goToPage(1)
        if stageFirstOn, !stageFirst.open { openStageFirst() }
    }

    /// A chat from the drawer's list. The chat is the record: from the full screen it comes up there.
    private func pickChat(_ id: String) {
        store.openChat(id)
        settleDrawer(open: false)
        if stageFirstOn, stageFirst.open { closeStageFirst() }
    }

    /// Page 1: the thread itself, or the empty chat before the first message.
    @ViewBuilder private var thread: some View {
        let c = theme.swatch(scheme)
        let _ = BodyLog.hit("thread")
        if store.messages.isEmpty && !store.waiting {
            EmptyChat(agent: store.agent, loading: store.agent != nil && !store.loaded) { store.send($0) }
        } else {
            ScrollView {
                // Not Lazy: LazyVStack drops preset cards from the accessibility tree (iOS 26/27),
                // so VoiceOver and UI tests saw only the plain bubbles.
                VStack(spacing: theme.spacing.m) {
                    // A reply with nothing left to draw gets no row, not a lone face (YUI-80).
                    let all = store.shown
                    let visible = all.count > window ? Array(all.suffix(window)) : all
                    let marks = SentTimes.marks(visible)
                    ForEach(visible) { m in
                        VStack(spacing: theme.spacing.xs) {
                        if let day = marks.day[m.id] { DayDivider(label: day) }
                        Group {
                            if m.stopped {
                                QuietNote(text: "Stopped", icon: "stop.circle", id: "stopped-note")
                            } else if let yl = m.yl {
                                YLReply(screen: yl, scope: m.id, agent: store.agent, style: agentStyle,
                                        reaction: store.wearsReaction(m) ? store.reaction(for: m) : nil,
                                        lifted: store.reacting == m.id,
                                        open: { openReactions(m.id) },
                                        react: { store.react(m.id, with: $0) },
                                        select: { selecting = m },
                                        reply: { startReply(m.id) }) { openStage(m.id) }
                                    .equatable()
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
                                    .equatable()
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
                        if let time = marks.time[m.id] { SentTime(text: time, fromUser: m.fromUser) }
                        }
                    }
                    if let agent = store.agent, outbox.offline, !outbox.pending(agentID: agent.id).isEmpty {
                        // On the phone, not on Yui yet: it sends itself when the connection is back.
                        QuietNote(text: "Not sent yet. It goes the moment you're back online.", icon: "clock")
                    } else if store.waiting, let agent = store.agent, agent.liveness == .notListening {
                        // Paired, but its gateway never started (YUI-64): it waits, no timer counting forever.
                        ListeningNote(agent: agent)
                            .transition(.identity)
                    } else if store.waiting, let agent = store.agent, agent.liveness != .online {
                        // Delivered, but the agent's computer is away: say so instead of fake dots.
                        QuietNote(text: agent.liveness == .asleep
                                  ? "\(agent.name) is asleep. It gets this when its computer wakes."
                                  : "\(agent.name) is offline. It gets this when its gateway starts again.",
                                  icon: agent.liveness == .asleep ? "moon.zzz" : "powersleep")
                            .transition(.identity)
                    } else if store.waiting {
                        WorkingNote(agent: store.agent, since: store.waitingSince, pickedUp: store.pickedUpAt, doing: store.doing,
                                    usual: WorkingNote.usual(store.turnTimes)).id("typing")
                            .transition(.identity)  // on the send's spring now (YUI-108), but it still just appears
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
            .background { if !store.waiting { WorkingNoteWarmer(agent: store.agent) } }
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
                // Every frame of a scroll lands here: write state only when it changes.
                let bottom = screens < 0.04
                if atBottom != bottom {
                    atBottom = bottom
                    // Arrived by the arrow or a programmatic scroll: no drag ends here, so the
                    // older rows drawn on the way up would stay alive (YUI-207).
                    if bottom, !dragging, window > Self.windowStep { window = Self.windowStep }
                }
                followScroll(screens: screens)
            }
            // Content or insets changed size (a sent photo, the composer, the keyboard):
            // a pinned thread goes back to the newest message.
            .onScrollGeometryChange(for: CGSize.self) { geo in
                CGSize(width: geo.containerSize.height, height: geo.contentSize.height)
            } action: { _, _ in
                if pinned, !dragging, !atBottom { position.scrollTo(edge: .bottom) }
            }
            // Each chat keeps where it was scrolled to for this session (YUI-169).
            .onScrollGeometryChange(for: CGSize.self) { geo in
                CGSize(width: geo.contentOffset.y,
                       height: geo.contentSize.height - geo.contentInsets.top - geo.contentOffset.y - geo.containerSize.height)
            } action: { _, now in
                guard let id = store.chatID, store.loaded else { return }
                if now.height < 24 { store.places[id] = nil } else { store.places[id] = now.width }
            }
            .task(id: "\(store.chatID ?? "")-\(store.loaded)") {
                guard store.loaded, let id = store.chatID, let y = store.places[id], !store.messages.isEmpty else { return }
                try? await Task.sleep(for: .milliseconds(80))
                pinned = false
                position.scrollTo(y: y)
            }
            // Within a screen of the top of what's drawn: draw the next older batch.
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top < geo.containerSize.height
            } action: { _, near in
                nearTop = near
                if !near { topGrown = false }
                if near, !topGrown, store.shown.count > window { window += Self.windowStep; topGrown = true }
            }
            // Everything held is drawn and the top is near: the next older batch comes from the server (YUI-254).
            .task(id: "\(nearTop)-\(window)-\(store.shown.count)-\(store.hasOlder)-\(store.chatID ?? "")") {
                // Rows came in while the top stayed near: the flag never flipped, so draw them here.
                guard nearTop else { return }
                if store.shown.count > window {
                    if !topGrown { window += Self.windowStep; topGrown = true }
                    return
                }
                guard store.hasOlder else { return }
                await store.loadOlder()
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { topGrown = false }
                settleScroll(phase)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                if atBottom { window = Self.windowStep }
            }
            // The keyboard often goes a moment after the drag settles.
            .onChange(of: focused) {
                guard !focused, dismissPin, !dragging else { return }
                dismissPin = false
                jumpToBottom()
            }
            // The newest row's id, not every id: one string compared per pass (YUI-101).
            .onChange(of: store.messages.last?.id) { old, _ in countNew(after: old) }
            // The agent's saved screens, one tap from the stage (YUI-32).
            .safeAreaInset(edge: .top, spacing: 0) {
                if !store.shelf.screens.isEmpty {
                    ShelfBar(screens: store.shelf.screens, open: store.reopen, remove: store.unshelve,
                             pin: { name in
                                 if let id = store.agent?.id { WidgetSync.pinNext(agent: id, name: name) }
                                 pinning = PinName(id: name)
                             })
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

    #if DEBUG
    /// -yuiDemoPickCrew: the pick is saved, so Yui says hello naming who joined (crew_choose writes it on the account).
    private func demoCrewHello() {
        guard account.session?.userID == "demo", ProcessInfo.processInfo.arguments.contains("-yuiDemoPickCrew"),
              agents.selected?.handle == "yui" else { return }
        let at = ISO8601DateFormatter().string(from: .now)
        var rows: [ThreadRow] = []
        if let home = AgentStore.demoHome["yui"] {
            rows.append(ThreadRow(id: "home-yui", sender: "agent", body: home, kind: "text",
                                  meta: .object(["native": .string("home")]), createdAt: at))
        }
        rows.append(ThreadRow(id: "first-yui", sender: "agent", body: AgentStore.demoHello(agents.agents.map(\.handle)),
                              kind: "text", meta: .object(["native": .string("first")]), createdAt: at))
        store.reopen(rows)
    }
    #endif

    /// Signed in with no agents yet (every new account): nothing here can answer,
    /// so the chat says how to connect one instead of pretending.
    /// The demo account shows it too when started with `-yuiNoAgents` (SOC-3 videos).
    private var firstRun: Bool {
        (account.session?.userID != "demo" || ProcessInfo.processInfo.arguments.contains("-yuiNoAgents"))
            && agents.agents.isEmpty
    }

    /// @ suggestions (YUI-44) and the bar saying who an @ goes to: not on a screen,
    /// and the demo only with more than one agent.
    private var mentionsOn: Bool {
        talkPage == nil && (account.session?.userID != "demo" || agents.agents.count > 1)
    }

    /// The other agent this draft goes to, if it @s one. Read at send, never in the body.
    private var mentioning: YuiAgent? {
        let draft = composer.draft
        guard !draft.hasPrefix("/"), talkPage == nil else { return nil }
        return Mentions.target(draft, agents: agents.agents, current: store.agent?.id)
    }

    /// Nothing here reads the draft (YUI-99): the hints, the field and the send
    /// button do, in their own views, so a key never re-evaluates the chat.
    private func inputBar(_ c: Swatch) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.s) {
            ComposerHints(composer: composer, commands: store.agent?.commands, mentions: mentionsOn,
                          agents: agents.agents, current: store.agent?.id, listening: talk.listening || handsFree.on,
                          reduceMotion: reduceMotion, focused: $focused)
            if let a = store.about, talkPage == nil {
                AboutChip(item: a, open: { aboutOpen = a }, remove: { store.talkAbout(nil) })
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            } else if let q = store.replying, talkPage == nil {
                ReplyBar(quote: q, agent: store.agent?.name) { store.cancelReply() }
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
            if !photos.isEmpty { attachmentStrip(c) }
            if let held = keyHeld {
                KeyHoldBanner(shape: held, move: { keyMove = held }, sendAnyway: { keySendAnyway = true; send() })
                    .transition(.opacity)
            }
            KeyHoldWatch(composer: composer, held: $keyHeld)
            if let note = composerNote {
                Label(note, systemImage: "info.circle")
                    .font(theme.font(theme.type.caption, .semibold))
                    .foregroundStyle(c.inkSoft)
                    .transition(.opacity)
                    .accessibilityIdentifier("composer-note")
            }
            inputRow(c)
        }
        .padding(.horizontal, theme.spacing.l)
        .padding(.vertical, theme.spacing.s)
        .background(c.background)
        .animation(theme.spring, value: talk.listening)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : theme.spring, value: handsFree.on)
        .background(recordBarHooks)
        .sensoryFeedback(.impact(weight: .light), trigger: handsFree.state) { _, now in now == .listening }
        // The reply landing is what reopens the mic: a new agent bubble, or the turn ending.
        .onChange(of: store.messages.last?.id) {
            if let m = store.messages.last, !m.fromUser { handsFreeDo(.replyLanded) }
        }
        .onChange(of: store.waiting) { was, now in
            if was, !now, store.messages.last?.fromUser == false { handsFreeDo(.replyLanded) }
        }
        .onChange(of: talk.interrupted) { _, now in handsFreeDo(now ? .interrupted : .interruptionEnded) }
        .onChange(of: scenePhase) { _, now in if now != .active { handsFreeDo(.stop) } }
        // A new thread starts how its agent is set: Talk opens hands-free (YUI-14).
        .task(id: store.agent?.id) {
            #if DEBUG
            if UserDefaults.standard.string(forKey: "yuiHandsFreeDemo") != nil { return }  // screenshots hold a state
            #endif
            handsFreeDo(.stop)
            guard let id = store.agent?.id, TalkMode.of(id) == .talk, !firstRun else { return }
            #if DEBUG
            if talk.fakeWords != nil { handsFreeDo(.tap); return }
            #endif
            if PushToTalk.allowed { handsFreeDo(.tap) }
        }
        .onDisappear {
            handsFreeDo(.stop)
            MusicHost.shared.leavingAgent()
        }
        .animation(theme.spring, value: photos)
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
                // One photo at a time, shrunk as it loads: a full pick never holds every original in memory (or the main thread).
                var over = false
                for item in items {
                    guard let d = try? await item.loadTransferable(type: Data.self) else { continue }
                    guard photos.count < Attachments.maxPhotos else { over = true; break }
                    if let photo = await Task.detached(priority: .userInitiated, operation: { ComposerPhoto(d) }).value { photos.append(photo) }
                }
                if over { flash("Up to \(Attachments.maxPhotos) photos in one message.") }
            }
        }
        #if DEBUG
        // -yuiComposerPhoto <path>: a photo already in the composer (UI tests, screenshots).
        // -yuiPTTDemo "words": the hold-to-talk listening state.
        .task {
            // Several paths split by `|` put several in (YUI-121's two-picture send).
            // Once per launch: the task runs again when the thread changes, and a second copy went out.
            if !Self.composerPhotoPlaced, let paths = UserDefaults.standard.string(forKey: "yuiComposerPhoto") {
                Self.composerPhotoPlaced = true
                add(paths.split(separator: "|").compactMap { FileManager.default.contents(atPath: String($0)) })
            }
            if let words = UserDefaults.standard.string(forKey: "yuiPTTDemo") { talk.demo(words) }
            // -yuiPTTDemoCancel: the demo, slid to the trash.
            if ProcessInfo.processInfo.arguments.contains("-yuiPTTDemoCancel") { micDragX = -Self.cancelDistance - 30 }
            if ProcessInfo.processInfo.arguments.contains("-yuiPTTDemoLock") { micLift = Self.lockDistance + 10 }
            talk.fakeWords = UserDefaults.standard.string(forKey: "yuiPTTFake")
            // -yuiHandsFreeDemo listening|sending|waiting|reading|paused: that state, for screenshots.
            if let at = UserDefaults.standard.string(forKey: "yuiHandsFreeDemo"), let hf = HandsFree.demo(at) {
                let words = UserDefaults.standard.string(forKey: "yuiPTTDemo") ?? "Is my morning free tomorrow?"
                if hf.state == .listening { talk.demo(words) }
                handsFreeWords = words
                handsFree = hf
            }
        }
        #endif
    }

    /// The field and its buttons, or with stage first the bar (YUI-121). The fields and
    /// buttons it picks from return AnyView: build 229 crashed building this row's type.
    private func inputRow(_ c: Swatch) -> some View {
        HStack(alignment: .bottom, spacing: theme.spacing.s) {
            if recordBar {
                // Stage first (YUI-121): the record has the stage's bar, mic bottom right.
                if handsFree.on { handsFreeField(c) } else if talk.listening { listeningField(c) } else { Spacer(minLength: 0) }
                BarButtons(prefix: "record", showMic: stageMic || !stageType, showType: stageType || !stageMic,
                           showAttach: stageAttach, micOn: handsFree.on || talk.listening, micLive: talk.listening,
                           armed: cancelArmed, held: talk.listening && !handsFree.on, lockArmed: lockArmed,
                           attachDisabled: sending || photos.count >= Attachments.maxPhotos,
                           reduceMotion: reduceMotion, actions: barActions(tap: stageMicTap, type: typeHere))
            } else if handsFree.on {
                handsFreeField(c)
                stopTalkingButton(c)
            } else {
                if !talk.listening { attachMenu(c) }
                if talk.listening { listeningField(c) } else { field(c) }
                sendButton(c)
            }
        }
        // The field grows out of T and folds back into it.
        .transition(reduceMotion ? .opacity : .scale(scale: 0.2, anchor: .bottomTrailing).combined(with: .opacity))
        .id(recordBar)
    }

    /// The record bar's own hooks and the Files picker, apart so the input bar's
    /// chain stays type-checkable.
    private var recordBarHooks: some View {
        Color.clear
            .accessibilityHidden(true)
            .onChange(of: focused) { was, now in if was, !now { foldRecordField() } }
            .onChange(of: photos.isEmpty) { _, empty in
                if !empty, stageFirstOn, talkPage == nil { withAnimation(theme.spring) { recordTyping = true } }
            }
            .onChange(of: store.replying) { _, q in if q != nil, recordBar { typeHere() } }
            .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                add(urls.compactMap { url in
                    let open = url.startAccessingSecurityScopedResource()
                    defer { if open { url.stopAccessingSecurityScopedResource() } }
                    return try? Data(contentsOf: url)
                })
            }
    }

    private func field(_ c: Swatch) -> some View {
        ComposerField(composer: composer,
                      prompt: !photos.isEmpty ? "Add a caption" : talkPage.map { "About screen \($0)" } ?? "Say something nice",
                      focused: $focused, submit: send)
    }

    /// Held down: what it hears, live, where the words would be, with the trash on the
    /// left, a clock and the waveform. Slide the finger left to the trash to cancel.
    private func listeningField(_ c: Swatch) -> AnyView {
        let armed = cancelArmed
        return AnyView(VStack(alignment: .leading, spacing: theme.spacing.xs) {
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
        .accessibilityIdentifier("listening"))
    }

    /// One + for everything that isn't words. Room for files and more later, no new buttons.
    private func attachMenu(_ c: Swatch) -> AnyView {
        AnyView(Menu {
            if SnapCamera.available { Button { openSnap() } label: { Label("Snap and say", systemImage: "camera.viewfinder") } }
            Button { pickingPhotos = true } label: { Label("Photo library", systemImage: "photo.on.rectangle") }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { shooting = true } label: { Label("Camera", systemImage: "camera") }
            }
            Button { importingFiles = true } label: { Label("Files", systemImage: "folder") }
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
        .accessibilityIdentifier("attach"))
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
    private func sendButton(_ c: Swatch) -> AnyView {
        AnyView(SendOrMic(composer: composer, send: !photos.isEmpty || sending) {
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
        } mic: {
            Image(systemName: talk.listening ? "waveform" : "mic.fill")
                .font(theme.font(theme.type.title, .black))
                .foregroundStyle(talk.listening ? c.onAccent : c.ink)
                .symbolEffect(.variableColor.iterative, isActive: talk.listening && !reduceMotion)
                .frame(width: 46, height: 46)
                .background(talk.listening ? c.accent : c.surface, in: Circle())
                .overlay(Circle().stroke(talk.listening ? .clear : c.outline, lineWidth: 1.5))
                .scaleEffect(talk.listening ? 1.25 : 1)
                .contentShape(Circle())
                // The trash is the one in the listening bar on the left; the mic stays where it is.
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
        })
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
    private func micUp(quick: (() -> Void)? = nil) {
        micHeld = false
        let cancel = cancelArmed
        micDragX = 0
        if talk.listening {
            if cancel {
                talk.cancel()
            } else {
                Task { let words = await talk.stop(); if !words.isEmpty { composer.draft = words; send() } }
            }
        } else if !micStarting {
            // A quick tap: hands-free (YUI-14). Holding still talks once and sends on let go.
            holdStart?.cancel()
            if let quick { quick() } else if talk.phase == .idle { handsFreeDo(.tap) }
        }
    }

    // MARK: Hands-free (YUI-14)

    /// Tells hands-free what happened and does what it answers.
    private func handsFreeDo(_ e: HandsFree.Event) {
        guard let effect = handsFree.handle(e) else {
            if handsFree.state != .listening { handsFreeWatch?.cancel() }
            return
        }
        switch effect {
        case .openMic:
            Task {
                await talk.start()
                if talk.listening {
                    handsFreeDo(.micOpen)
                    if handsFree.state == .listening { watchForEndOfTurn() } else { talk.cancel() }
                } else {
                    handsFreeDo(.micFailed(denied: talk.phase == .denied))
                    talk.reset()
                }
            }
        case .finishMic:
            handsFreeWatch?.cancel()
            Task { handsFreeDo(.heard(await talk.stop())) }
        case .closeMic:
            handsFreeWatch?.cancel()
            talk.cancel()
        case .send(let words):
            handsFreeWords = words
            composer.draft = words
            send()
            // send() clears the composer once the words are out; still there means they didn't go.
            handsFreeDo(composer.hasWords ? .sendFailed : .sent)
        case .readBeat:
            Task {
                try? await Task.sleep(for: HandsFree.readBeat)
                handsFreeDo(.readDone)
            }
        }
    }

    /// While the mic is open: a quiet spell after words ends the turn; a long silence pauses.
    private func watchForEndOfTurn() {
        handsFreeWatch?.cancel()
        handsFreeWatch = Task {
            while !Task.isCancelled, handsFree.state == .listening {
                if EndOfSpeech.ended(words: talk.transcript, lastSound: talk.lastSound) { handsFreeDo(.endOfSpeech); return }
                if EndOfSpeech.tooQuiet(words: talk.transcript, startedAt: talk.startedAt) { handsFreeDo(.quietTooLong); return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Where the words go, hands-free: what it hears, what it sent, and what's next, in plain words.
    private func handsFreeField(_ c: Swatch) -> AnyView {
        let name = store.agent?.name ?? "Your agent"
        let (status, icon, words): (String, String, String) = switch handsFree.state {
        case .off, .starting: ("Opening the mic", "mic.fill", "One sec.")
        case .listening: ("Listening", "waveform", talk.transcript.isEmpty ? "Just talk. A short pause sends it." : talk.transcript)
        case .finishing, .sending: ("Sending", "arrow.up.circle.fill", handsFreeWords.isEmpty ? talk.transcript : handsFreeWords)
        case .waiting: ("\(name) is on it", "ellipsis.bubble.fill", "The mic opens again when the answer lands.")
        case .reading: ("Your turn", "text.bubble.fill", "Mic's back in a sec.")
        case .paused(.interrupted): ("Paused", "pause.circle.fill", "Picks up when the call or alarm is done.")
        case .paused(.quiet): ("Paused", "pause.circle.fill", "Tap here to keep talking.")
        case .paused(.failed): ("Can't listen right now", "mic.slash.fill", "Tap here to try again, or stop and type.")
        case .paused(.denied): ("Mic is off for Yui", "mic.slash.fill", "Turn on the mic and speech recognition for Yui in Settings.")
        }
        let paused = if case .paused = handsFree.state { true } else { false }
        let live = handsFree.state == .listening
        return AnyView(Button { if paused { handsFreeDo(.tap) } } label: {
            VStack(alignment: .leading, spacing: theme.spacing.xs) {
                Label(status, systemImage: icon)
                    .font(theme.font(theme.type.caption, .bold))
                    .foregroundStyle(paused ? c.inkSoft : c.accent)
                    .symbolEffect(.variableColor.iterative, isActive: live && !reduceMotion)
                    .contentTransition(.opacity)
                    .accessibilityIdentifier("hands-free-status")
                Text(words)
                    .font(theme.font(theme.type.body, live && !talk.transcript.isEmpty ? .regular : .semibold))
                    .foregroundStyle(live && !talk.transcript.isEmpty || handsFree.state == .sending ? c.ink : c.inkSoft)
                    .lineLimit(1...4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
                if live {
                    TalkWaveform(levels: talk.levels, level: talk.level, color: c.accent, track: c.outline,
                                 reduceMotion: reduceMotion)
                }
            }
            .padding(.horizontal, theme.spacing.l)
            .padding(.vertical, theme.spacing.s)
            .frame(minHeight: 46)
            .background(c.surface, in: .rect(cornerRadius: theme.radius.bubble))
            .overlay(RoundedRectangle(cornerRadius: theme.radius.bubble)
                .stroke(paused ? c.outline : c.accent, lineWidth: live ? 2 : 1.5))
        }
        .buttonStyle(.plain)
        // Not .disabled: that dims the live words. Only a paused bar takes the tap.
        .allowsHitTesting(paused)
        .animation(reduceMotion ? nil : theme.spring, value: handsFree.state)
        .accessibilityElement(children: .combine)
        .accessibilityHint(paused ? "Double tap to keep talking." : "")
        .accessibilityIdentifier("hands-free")
        .accessibilityValue(handsFree.accessibilityState))
    }

    /// Ends hands-free and goes back to typing.
    private func stopTalkingButton(_ c: Swatch) -> AnyView {
        AnyView(Button { handsFreeDo(.stop) } label: {
            Image(systemName: "xmark")
                .font(theme.font(theme.type.title, .black))
                .foregroundStyle(c.ink)
                .frame(width: 46, height: 46)
                .background(c.surface, in: Circle())
                .overlay(Circle().stroke(c.outline, lineWidth: 1.5))
        }
        .buttonStyle(BounceButtonStyle())
        .accessibilityLabel("Stop talking")
        .accessibilityIdentifier("hands-free-stop"))
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
        // send_bubble (YUI-102): the tap to the frame with the bubble. Photo sends wait on
        // the upload before their bubble, so they are not timed.
        let tapped = CACurrentMediaTime()
        let text = composer.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !photos.isEmpty, !sending else { return }
        // Key-shaped words never leave the phone in the composer (YUI-34): held, and a known provider's shape can't be sent at all.
        if let shape = KeyShape.find(in: text), shape.isKnown || !keySendAnyway {
            keySendAnyway = false
            withAnimation { keyHeld = shape }
            return
        }
        keySendAnyway = false
        keyHeld = nil
        // Picks waiting on the stage's last page (YUI-208): the words go in with them, one answer.
        if photos.isEmpty, stageFirst.open, let bundle = stageFirst.bundle, bundle(text) {
            clearComposer()
            return
        }
        if account.session?.userID != "demo" {
            guard store.agent != nil else { return }
            let to = mentioning
            let screen = talkPage
            if photos.isEmpty {
                // Not sent (no agent, no session): the words go back in the field.
                let words = emptyField()
                guard store.send(text, mention: to, screen: screen) else { composer.draft = words; return }
                Perf.shared.span(.sendBubble, from: tapped)
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
        if photos.isEmpty, ChatStore.demoText("yuiDemoReply") != nil {
            let words = emptyField()
            guard store.send(text, screen: talkPage) else { composer.draft = words; return }
            Perf.shared.span(.sendBubble, from: tapped)
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
                                              photos: photos.map { .local($0.preview) }, replyTo: q, fromScreen: screen,
                                              about: screen == nil && !text.hasPrefix("/") ? store.about?.title : nil))
        }
        photos = []
        clearComposer()
        #if DEBUG
        // -yuiDemoReply answers a photo too (YUI-141: Basil reading a meal).
        if let reply = ChatStore.demoText("yuiDemoReply") {
            withAnimation(ChatStore.sendSpring) { store.demoAnswer(reply) }
            return
        }
        #endif
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation(theme.spring) {
                store.messages.append(ChatMessage(text: ChatView.replies.randomElement()!, fromUser: false))
            }
        }
    }

    /// Hold to snap and say: hands-free lets go of the mic, the camera comes up.
    private func openSnap() {
        handsFreeDo(.stop)
        focused = false
        stageFocused = false
        snapping = true
    }

    /// The photo and what was said over it, as one message: the words ride with the picture.
    private func sendSnap(_ said: SnapSaid) {
        guard let photo = ComposerPhoto(said.photo) else { flash("Couldn't read that photo. Try again."); return }
        let words = said.words.trimmingCharacters(in: .whitespacesAndNewlines)
        if account.session?.userID != "demo" {
            guard store.agent != nil, !sending else { return }
            sending = true
            Task {
                defer { sending = false }
                do { try await store.send(words, photos: [photo]) } catch { flash("Couldn't send the photo. Try again.") }
            }
            return
        }
        let body = Attachments.body(text: words, photos: 1)
        withAnimation(ChatStore.sendSpring) {
            store.messages.append(ChatMessage(text: Attachments.caption(body: body, photos: 1), fromUser: true,
                                              photos: [.local(photo.preview)]))
        }
        #if DEBUG
        if let reply = ChatStore.demoText("yuiDemoReply") {
            withAnimation(ChatStore.sendSpring) { store.demoAnswer(reply) }
        }
        #endif
    }

    // MARK: Stage first (YUI-119)

    /// A send puts the stage up on it, working; a new thread starts at the greeting.
    /// Its own view, so the chat's long modifier chain stays type-checkable.
    private var stageFirstHooks: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: stageFirstOn, initial: true) { _, on in
                store.stageFirst = on
                withAnimation(theme.spring) { stageFirst.open = on }
            }
            .onChange(of: store.owed) {
                guard stageFirstOn else { return }
                focused = false
                stageFocused = false
                withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : theme.spring) {
                    stageFirst.follow(store.messages.last(where: \.fromUser)?.id)
                }
            }
            // A new thread starts at the greeting, unless its agent's hello is still unseen:
            // then the hello plays (YUI-167). Keyed on the hello too, since it can land
            // after the thread opens.
            .onChange(of: [store.agent?.id, store.messages.first(where: \.hello)?.id], initial: true) { old, new in
                // A hello already playing for this thread stays (SwiftUI can report the agent's
                // change after the hello it opened on has started).
                let playing = stageFirst.hello.map { id in store.messages.contains { $0.id == id } } ?? false
                if old.first != new.first, !playing {
                    stageFirst.home()
                    stageFirst.seen = store.shown.count
                }
                guard stageFirstOn else { return }
                withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : theme.spring) {
                    if stageFirst.meet(store.messages, agent: store.agent?.id) { focused = false }
                }
            }
            .onChange(of: store.loaded) { if store.loaded { stageFirst.seen = store.shown.count } }
            // A reply that lands while the agent's home is up plays at once (YUI-262), no tap on a badge.
            .onChange(of: store.messages.last?.id) { old, _ in landArrival(after: old) }
            #if DEBUG
            .task(id: store.loaded) {
                guard store.loaded, let text = ChatStore.demoText("yuiDemoArrive") else { return }
                store.demoArrive(text)
            }
            #endif
            // Hold to snap and say (YUI-166): the photo and the words go as one message.
            .fullScreenCover(isPresented: $snapping) {
                SnapSayView { said in
                    snapping = false
                    if let said { sendSnap(said) }
                }
            }
            // yui://snap (a shortcut such as Basil's "Log a meal"): straight to the camera.
            .onChange(of: push.pendingSnap, initial: true) {
                guard push.pendingSnap, store.agent != nil else { return }
                push.pendingSnap = false
                settleDrawer(open: false)
                openSnap()
            }
            // The chat is one page, so a pill or drawer row for a screen opens the stage on it.
            .onChange(of: store.screenAsks) { if !pagedChat, !stageFirst.open, store.page > 1 { openStageFirst() } }
    }

    private var stageFirstLayer: some View {
        StageFirstView(
            store: store, model: stageFirst, agent: store.agent, agents: agents.agents, unshared: agents.unshared, composer: composer,
            focus: $stageFocused, photos: photos, sending: sending, mic: stageMicState,
            showMic: stageMic || !stageType, showType: stageType || !stageMic, showAttach: stageAttach,
            unread: max(0, store.shown.count - stageFirst.seen), waiting: store.waitingCount, reduceMotion: reduceMotion,
            screens: store.screens, screen: store.screens.contains(page ?? 1) ? (page ?? 1) : 1,
            screenTitle: { store.pageTitle($0) }, style: agentStyle,
            look: store.agent?.motionLook(reduced: reduceMotion) ?? MotionLook(character: "bouncy", reduced: reduceMotion),
            actions: StageActions(
                menu: { settleDrawer(open: true) },
                pick: { agents.selectedID = $0 },
                add: agents.onlyShared ? nil : { addFirst = true },
                manage: { showAgents = true },
                record: closeStageFirst,
                newChat: startNewChat,
                openDrawer: { settleDrawer(open: true) },
                bar: barActions(tap: stageMicTap, type: {}) { withAnimation(theme.spring) { stageFirst.typing = true } },
                send: send,
                removePhoto: { p in photos.removeAll { $0.id == p.id } },
                // A hello playing sits on screen 1 (YUI-225); leaving it for a screen ends it.
                goScreen: { if $0 != 1 { stageFirst.hello = nil }; store.goToPage($0) },
                drawerDrag: { x in
                    guard !drawerOpen else { return }
                    stageFocused = false
                    drawerMotion.drag = x
                },
                drawerSettle: { x, v in
                    guard !drawerOpen else { return }
                    settleDrawer(open: x > drawerWidth * Drawer.threshold || v > Drawer.flick)
                },
                retry: { words in composer.draft = words; send() }))
    }

    /// The mic as the stage draws it: hands-free's state and what it hears.
    private var stageMicState: StageMic {
        let note: String? = switch handsFree.state {
        case .paused(.denied): "Turn on the mic for Yui in Settings."
        case .paused(.failed): "Can't listen right now. Tap the mic to try again."
        case .paused(.quiet): "Paused. Tap the mic to keep talking."
        case .paused(.interrupted): "Paused for the call or alarm."
        default: nil
        }
        let held = talk.listening && !handsFree.on
        let live = handsFree.micOpen || handsFree.state == .finishing || handsFree.state == .sending || held
        return StageMic(on: handsFree.on && note == nil || held, live: live, held: held, armed: cancelArmed,
                        locking: lockArmed, words: talk.transcript, note: note)
    }

    /// The bar's buttons (YUI-121), on the stage and in the record. `tap` is the mic's
    /// tap; a hold talks until the finger lets go. `attaching` runs before a picker opens.
    private func barActions(tap: @escaping () -> Void, type: @escaping () -> Void,
                            attaching: @escaping () -> Void = {}) -> BarActions {
        BarActions(
            type: type,
            photos: { attaching(); pickingPhotos = true },
            camera: UIImagePickerController.isSourceTypeAvailable(.camera) ? { attaching(); shooting = true } : nil,
            snap: SnapCamera.available ? { attaching(); openSnap() } : nil,
            files: { attaching(); importingFiles = true },
            micDown: {
                if handsFree.on { micTapOnly = true; return }
                micDown()
            },
            micDrag: { x in if !micTapOnly { micDragX = x } },
            micUp: {
                if micTapOnly { micTapOnly = false; micDragX = 0; micLift = 0; tap(); return }
                // Dropped on the lock: the mic stays open and hands-free takes it from here.
                if lockArmed {
                    micHeld = false
                    micDragX = 0
                    micLift = 0
                    handsFreeDo(.tap)
                    return
                }
                micLift = 0
                micUp(quick: tap)
            },
            micTap: tap,
            stop: canStop ? { stopTurn() } : nil,
            micLift: { y in if !micTapOnly { micLift = y } })
    }

    /// The agent is on something and the mic is free (YUI-190): the mic is a stop square.
    /// Hands-free waiting on the reply counts; listening or a held mic does not.
    private var canStop: Bool {
        store.working && !talk.listening && (!handsFree.on || handsFree.state == .waiting)
    }

    /// Stop: the turn ends where it is, and hands-free waiting on it goes off.
    private func stopTurn() {
        if handsFree.state == .waiting { handsFreeDo(.stop) }
        store.stop()
    }

    /// Tap: talk, hands-free. Tap while it hears words: send them now. Tap otherwise: stop.
    private func stageMicTap() {
        if handsFree.state == .listening, !talk.transcript.isEmpty { handsFreeDo(.endOfSpeech) }
        else if handsFree.on, stageMicState.note == nil { handsFreeDo(.stop) }
        else { handsFreeDo(.stop); handsFreeDo(.tap) }
    }

    /// The chat is the record: the stage goes down and the thread is there.
    private func closeStageFirst() {
        stageFocused = false
        stageFirst.seen = store.shown.count
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : theme.spring) { stageFirst.open = false }
    }

    private func openStageFirst() {
        focused = false
        stageFirst.seen = store.shown.count
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : theme.spring) { stageFirst.open = true }
    }

    /// A pill in the record: with stage first, the reply plays again from its chunk.
    private func openStage(_ id: String, toPlan: Bool = false) {
        guard stageFirstOn else { store.openStage(id); return }
        focused = false
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : theme.spring) {
            if !stageFirst.show(reply: id, in: store.messages, toPlan: toPlan) { store.openStage(id) }
            #if DEBUG
            // -yuiDemoStageAt <n>: the stage opens on that page of the answer (0 the first), for a shot of each.
            if UserDefaults.standard.object(forKey: "yuiDemoStageAt") != nil { stageFirst.at = UserDefaults.standard.integer(forKey: "yuiDemoStageAt") }
            #endif
        }
    }

    private func openReactions(_ id: String) {
        focused = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { store.reacting = id }
    }

    private func closeReactions() {
        withAnimation(.easeOut(duration: 0.2)) { store.reacting = nil }
    }

    /// Reply (hold menu): the quote goes above the composer and the keyboard comes up.
    private func startReply(_ id: String) {
        store.startReply(id)
        typeHere()
    }

    /// The keyboard up on the field. With the bar in the record, T comes out first
    /// and the field takes the focus once it is there.
    private func typeHere() {
        guard recordBar else { focused = true; return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : theme.spring) { recordTyping = true }
        DispatchQueue.main.async { focused = true }
    }

    /// A drawer shortcut opened over the full screen: its words land in the stage's T field.
    private func typeOnStage() {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : theme.spring) { stageFirst.typing = true }
        DispatchQueue.main.async { stageFocused = true }
    }

    /// Tap away: the record's field folds back to mic, T and +. The words stay for next
    /// time. A picker on its way up takes the focus too, so that doesn't count.
    private func foldRecordField() {
        guard stageFirstOn, recordTyping, photos.isEmpty, !pickingPhotos, !shooting, !importingFiles else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : theme.spring) { recordTyping = false }
    }

    /// A reply's chip: scroll back to the message it quotes, when it is still in the thread.
    private func goToOriginal(of q: ReplyQuote) {
        guard let id = store.original(of: q) else { return }
        focused = false
        // An old message above what's drawn: draw down to it first, then go.
        if let i = store.shown.firstIndex(where: { $0.id == id }), store.shown.count - i > window {
            window = store.shown.count - i + Self.windowStep / 2
            Task { @MainActor in scrollTarget = id }
            return
        }
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
    private func countNew(after old: String?) {
        let from = old.flatMap { id in store.messages.lastIndex { $0.id == id } }.map { $0 + 1 } ?? 0
        let added = store.messages[min(from, store.messages.count)...]
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
        Perf.shared.scrollMoving(phase != .idle)
        switch phase {
        case .interacting, .tracking:
            if !dragging { dragging = true; dismissPin = pinned && focused }
        case .idle:
            // Back at the newest message: the older rows drawn on the way up go again (YUI-100),
            // so one long scroll up does not keep the whole thread alive.
            if atBottom, window > Self.windowStep { window = Self.windowStep }
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

    /// Empties the field before the bubble goes in and hands back what it held
    /// (YUI-108). Emptied after, the field's change made SwiftUI lay out the new row
    /// right there in the button's action, then again for the frame: about a third
    /// of the send tap.
    private func emptyField() -> String {
        let words = composer.draft
        composer.draft = ""
        return words
    }

    /// Empties the field, keeping the keyboard up if it was. A hold-to-talk send leaves it down.
    private func clearComposer() {
        let keep = focused
        if !composer.draft.isEmpty { composer.draft = "" }
        guard keep else { composer.fieldID += 1; return }
        // A fresh field is how the sent words are sure to go (TestFlight feedback
        // APthnqcdHvqEP, device only: the text view kept drawing them). It makes UIKit
        // reload the keyboard, about half the send tap (YUI-106), so it waits until the
        // frame with the bubble is on screen (YUI-108: one turn of the run loop wasn't
        // enough, the reload still ran before that frame's display tick).
        AfterFrames.run(2) {
            composer.fieldID += 1
            // The new field mounts on this turn's pass; focus it on the next so the keyboard stays.
            DispatchQueue.main.async { focused = true }
        }
    }

    #if DEBUG
    /// -yuiAutoScroll runs once per launch.
    @MainActor private static var autoScrolled = false

    /// -yuiThreadRows <path>: a JSON array of yui_messages rows.
    static func debugRows() -> [ThreadRow]? {
        guard let path = UserDefaults.standard.string(forKey: "yuiThreadRows"),
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode([ThreadRow].self, from: data)
    }
    #endif

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

    /// A deck with a short page, a long one and points (feedback AK2rJFQ9).
    static let whereItLanded = """
        deck "Where it landed" +inline
        page "Feel first" body="The next build is about how Yui feels in the hand."
        page "What goes first" body="Scrolling, then typing, memory and taps. Every card on the board that makes the app feel slow moves ahead of the rest, and integrations wait in the backlog until the feel is right. The design stays as it is, so nothing you like about the look changes while this happens."
        page "On the board" points="YUI-101 taps and scroll"|"YUI-99 typing"|"YUI-102 speed numbers"
        page "Taps and scroll" body="YUI-101. Taps react on the same frame and the network catches up after. Scrolling at 120 fps and threads that open fast. Your design doesn't change."
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

    /// Ideas drawn with shapes that move (YUI-104): a flow in one row with arrows,
    /// a crowded row whose labels wrap, placed shapes with a dashed arrow and a path,
    /// and a card that glides from one column to the next.
    static let shapesDemo = [
        """
        shapes "How an ask reaches your phone" caption="You ask, it lands on the board, a lane builds it, and it ships to your phone."
        shape@you circle You +grow
        shape arrow
        shape box Board +fill
        shape arrow
        shape pill Lane +pulse
        shape arrow label=ships
        shape circle Phone tone=mint +grow
        """,
        """
        say Cold air still holds heat. The pump grabs it, squeezes it hot, and lets it out inside.
        shapes "Heat pump loop" caption="Refrigerant colder than the outdoor air soaks up heat, the compressor squeezes it hot, and the indoor coil lets it out into the house."
        shape blob "Outside air" tone=mute
        shape arrow
        shape box "Outdoor coil" tone=lavender +fill
        shape arrow
        shape pill Compressor +pulse
        shape arrow
        shape box "Indoor coil" tone=butter +fill
        """,
        """
        shapes "Picture or shapes" caption="A generated picture is a round trip to a GPU for every idea. Shapes are drawn on the phone from a few lines."
        shape@img box Picture at=2.2,1.5 size=3,1.4 tone=mute +dash
        shape@gpu blob GPU at=7.7,1.5 size=2.8,2 tone=butter +fill +grow
        shape arrow from=img to=gpu label="wait" tone=mute +dash
        shape@lines box Lines at=2.2,4.5 size=3,1.4 +fill +grow
        shape@phone circle Phone at=7.7,4.5 size=1.8 tone=mint +pulse
        shape arrow from=lines to=phone label="drawn here"
        """,
        """
        shapes "Where your idea is" h=4 caption="Your shapes idea left the backlog. A lane is building it now."
        shape text Backlog at=1.7,0.5 tone=mute
        shape text Running at=5,0.5 tone=mute
        shape text Shipped at=8.3,0.5 tone=mute
        shape line at=3.35,0.2 to=3.35,3.8 tone=mute +dash
        shape line at=6.65,0.2 to=6.65,3.8 tone=mute +dash
        shape pill Shapes at=1.7,2.3 size=2.6 +fill move=5,2.3
        shape@dot dot at=5,3.4 tone=mint +pulse
        """,
    ]

    /// Drawings (DRAW-2): a flowchart with a group and a way back, a sequence with a loop
    /// and a note, a state diagram, and three mock-ups (a phone with marks and notes, a
    /// sign-in with a keyboard, a browser page).
    static let drawDemo = [
        """
        say "Here is how an ask ships."
        diagram "How an ask ships" caption="You ask. A lane builds it. It rides the next build."
        flowchart LR
          you([You]) --> board[Board]
          subgraph fleet [The fleet]
            board --> lane[Lane]
            lane --> check{Checks green?}
          end
          check -->|yes| ship((TestFlight))
          check -.->|no| lane
        end
        """,
        """
        diagram "What happens when you send a message"
        sequenceDiagram
          autonumber
          actor U as You
          participant A as Yui app
          participant G as Agent
          U->>A: type and send
          A->>G: your words
          loop while it thinks
            A-->>U: working row
          end
          Note over A,G: one round trip
          G-->>A: yl lines
          A-->>U: the screen
        end
        """,
        """
        diagram "A TestFlight build"
        stateDiagram-v2
          [*] --> Uploaded
          Uploaded --> Processing: Apple receives it
          Processing --> Valid: passes
          Processing --> Invalid: fails
          Valid --> [*]
        end
        """,
        """
        say "The Agents screen, with what to change."
        mock "Agents" frame=phone
        part nav Agents action=Edit
        part text "Who do you want to talk to?" size=h2
        part row Basil sub="Groceries and meals" icon=B +chev +hi note="new badge goes here"
        part row Penny sub="Budget" icon=P +chev
        part row Old value=Soon +x +dim
        part button "New agent" +hi note="the one thing to tap"
        part tabs items=Home|Agents|Me tab=Agents
        """,
        """
        mock "Sign in" frame=phone
        part nav "Sign in" back=Back
        part field Email value="chris@example.com"
        part field Password ph="at least 8 characters" +hi note="show a meter here"
        part toggle "Keep me signed in" +on
        part slider Volume value=0.7
        part button Continue
        part keyboard
        """,
        """
        mock frame=browser url=yuigui.com/pricing
        part text "Pricing" size=h1
        part segmented items=Monthly|Yearly tab=Yearly
        part card Crew sub="$12 a month" body="Every agent, every device" +hi note="the one we sell"
        part grid items=Voice|Drawings|Timers|Games cols=2
        part button "Start free"
        """,
    ]

    /// Places on a map (YUI-158; Chris on the Mongol Empire answer: "this should be a Map"):
    /// a drawn empire with a pin and four ways out, a trip with a route through pins,
    /// and countries by code across the date line.
    static let mapDemo = [
        """
        say "At its peak, 1279, it ran from Korea to Hungary's edge."
        map "The Mongol Empire, 1279" caption="24M km². The biggest land empire there has been."
        area "Mongol Empire" 53,140|43,131|38.5,128.5|34.7,126.5|37.5,122.5|31,121.8|25,119.5|22.3,114|20.5,110.2|21.8,108|22.5,103|24,98|28,97|28,86|30,80|34,74|34,70|30,66|26,62|25.5,57|28,51|30,48|33,44|36,38.5|37,36|36.5,32|41,31|41.5,41.5|45,37|46,30.5|48,27|50.5,24|54,23|57,28|60,31|62,40|60,56|58,65|56,80|55,95|53,108|55,120 tone=butter
        area Raided PL|HU +dash
        pin@ka Karakorum 47.2,102.8 +pulse
        route East ka|37.6,127 +arrow
        route West ka|50.4,30.5 +arrow
        route South ka|33.3,44.4 +arrow
        route North ka|60,100 +arrow
        """,
        """
        map "Lisbon to Rome by train" caption="Three nights, four trains."
        area Iberia PT|ES tone=mint
        pin@li Lisbon 38.7,-9.1
        pin@ma Madrid 40.4,-3.7
        pin@ba Barcelona 41.4,2.2
        pin@ro Rome 41.9,12.5 +pulse
        route li|ma|ba|ro +arrow
        """,
        """
        map "Bering Strait" caption="Russia and Alaska are 82 km apart."
        area RU|US tone=lavender
        pin Anchorage 61.2,-149.9
        pin Magadan 59.6,150.8
        """,
    ]

    /// `-yuiDemo` seeds a chat; `-yuiYL <sample>` seeds one YL reply (see `YLSamples`).
    static var seed: [ChatMessage] {
        // -yuiDemoDays (YUI-202): a thread across three days, for the day dividers and times.
        if ProcessInfo.processInfo.arguments.contains("-yuiDemoDays") {
            let cal = Calendar.current
            func at(_ daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
                let day = cal.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
                return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
            }
            return [ChatMessage(text: "Can you set up Saturday?", fromUser: true, sentAt: at(3, 9, 15)),
                    ChatMessage(text: "Squats 5x5 at 185, then a 20 minute tabata.", fromUser: false, sentAt: at(3, 9, 16)),
                    ChatMessage(text: "Make it lighter", fromUser: true, sentAt: at(1, 18, 40)),
                    ChatMessage(text: "Done. Squats 5x5 at 165 now.", fromUser: false, sentAt: at(1, 18, 41)),
                    ChatMessage(text: "Anything new today?", fromUser: true, sentAt: at(0, 7, 5)),
                    ChatMessage(text: "Chats are built and on main. Tests pass.", fromUser: false, sentAt: at(0, 7, 6))]
        }
        if UserDefaults.standard.string(forKey: "yuiReactDemo") != nil {
            return [ChatMessage(text: "Saturday workout?", fromUser: true),
                    ChatMessage(text: "Want me to set up Saturday? Squats 5x5 at 185, then a 20 minute tabata, done by 10.",
                                fromUser: false)]
        }
        // -yuiLongThread <n>: n back-and-forth messages, enough to scroll (YUI-50).
        let long = UserDefaults.standard.integer(forKey: "yuiLongThread")
        if long > 0 {
            // -yuiLongThreadCards: every tenth answer is a card, the way a real thread mixes them (YUI-99).
            let cards = ProcessInfo.processInfo.arguments.contains("-yuiLongThreadCards")
            return (1...long).map { i in
                cards && i.isMultiple(of: 10)
                    ? ChatMessage(text: "", fromUser: false, yl: YLScreen(YLSamples.text("tabata")!))
                    : i.isMultiple(of: 2)
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
        // -yuiDemoDeckFit: the inline deck from TestFlight feedback AK2rJFQ9 (build 96), four
        // pages of mixed length, so the card's height can be seen following each page.
        if ProcessInfo.processInfo.arguments.contains("-yuiDemoDeckFit") {
            return [ChatMessage(text: "Where did my asks land?", fromUser: true),
                    ChatMessage(text: "", fromUser: false, yl: YLScreen(whereItLanded))]
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
        // -yuiDemoShapes: ideas drawn with shapes that move (YUI-104).
        if ProcessInfo.processInfo.arguments.contains("-yuiDemoShapes") {
            let asks = ["How does an ask reach my phone?", "How does a heat pump work?",
                        "Why shapes and not pictures?", "Where's my shapes idea?"]
            return zip(asks, shapesDemo).flatMap { ask, yl in
                [ChatMessage(text: ask, fromUser: true), ChatMessage(text: "", fromUser: false, yl: YLScreen(yl))]
            }
        }
        // -yuiDemoMap: places on a map (YUI-158).
        if ProcessInfo.processInfo.arguments.contains("-yuiDemoMap") {
            let asks = ["Give me a brief geographic explanation of the Mongol Empire", "Plan me a train trip, Lisbon to Rome",
                        "How close are Russia and Alaska?"]
            return zip(asks, mapDemo).flatMap { ask, yl in
                [ChatMessage(text: ask, fromUser: true), ChatMessage(text: "", fromUser: false, yl: YLScreen(yl))]
            }
        }
        // -yuiDemoDraw: a flowchart, a sequence, a state diagram and three mock-ups (DRAW-2).
        if ProcessInfo.processInfo.arguments.contains("-yuiDemoDraw") {
            let asks = ["How does an ask ship?", "What happens when I send a message?", "Show me the TestFlight build states",
                        "Redraw the Agents screen with the changes", "Mock up the sign-in", "Sketch the pricing page"]
            return zip(asks, drawDemo).flatMap { ask, yl in
                [ChatMessage(text: ask, fromUser: true), ChatMessage(text: "", fromUser: false, yl: YLScreen(yl))]
            }
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
/// Hold it for reactions and Reply, Copy, Select text (YUI-68).
private struct YLReply: View, @MainActor Equatable {
    let screen: YLScreen
    let scope: String
    var agent: YuiAgent?
    var style: [String: String] = [:]
    var reaction: Reaction?
    var lifted = false
    var open: () -> Void = {}
    var react: (Reaction?) -> Void = { _ in }
    var select: () -> Void = {}
    var reply: () -> Void = {}
    let openStage: () -> Void
    @Environment(\.yuiTheme) private var theme

    /// What it draws, closures aside: a row that didn't change skips its body (YUI-101).
    static func == (a: Self, b: Self) -> Bool {
        a.scope == b.scope && a.screen == b.screen && a.agent == b.agent && a.style == b.style
            && a.reaction == b.reaction && a.lifted == b.lifted
    }

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

private struct Bubble: View, @MainActor Equatable {
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
    /// Hold menu Reply (YUI-68).
    var reply: () -> Void = {}
    /// The chip on a sent reply: back to the message it quotes.
    var goToQuote: (ReplyQuote) -> Void = { _ in }
    /// Another agent's answer to a mention: opens its own thread (YUI-44).
    var openFrom: (() -> Void)? = nil
    /// "Read as pages" under a folded answer (YUI-79).
    var read: () -> Void = {}
    @Environment(\.yuiTheme) private var theme

    /// What it draws, closures aside: a row that didn't change skips its body (YUI-101).
    static func == (a: Self, b: Self) -> Bool {
        a.message == b.message && a.agent == b.agent && a.pending == b.pending && a.reaction == b.reaction
            && a.lifted == b.lifted && a.reduceMotion == b.reduceMotion && (a.openFrom == nil) == (b.openFrom == nil)
    }

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
                if let a = message.about {
                    AboutTag(title: a)
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
                        ReadAsPages(pages: LongText.pageCount(message.plain), action: read)
                    }
                } else if !message.text.isEmpty {
                    text
                }
            }
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
    var id = "quiet-note"
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Label(text, systemImage: icon)
            .font(theme.font(theme.type.caption, .semibold))
            .foregroundStyle(theme.swatch(scheme).inkSoft)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .transition(.opacity)
            .accessibilityIdentifier(id)
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

/// No agents in the list. With native Yui on (a crew offer), it offers the crew: everyone
/// in one tap, or pick who you want. Only without it does it explain pairing your own.
private struct FirstRun: View {
    let loaded: Bool
    let error: String?
    var crew: [CrewStarter]? = nil
    let add: () -> Void
    let retry: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    /// A new person's crew can land a few seconds after their first list (the list asks
    /// again every 3 s while empty). Until then they wait for Yui, not the pairing pitch
    /// (Chris saw that pitch on build 229 while native Yui was switched off).
    @State private var waited = false

    var body: some View {
        let c = theme.swatch(scheme)
        if !loaded, error == nil {
            ProgressView().tint(c.inkSoft)
        } else if loaded, crew == nil, !waited {
            VStack(spacing: theme.spacing.l) {
                Wordmark(height: 72)
                ProgressView().tint(c.inkSoft)
                Text("Getting Yui ready")
                    .font(theme.font(theme.type.body, .semibold)).foregroundStyle(c.inkSoft)
            }
            .accessibilityIdentifier("first-run-waiting")
            .task {
                try? await Task.sleep(for: .seconds(ProcessInfo.processInfo.arguments.contains("-yuiNoAgents") ? 0 : 12))
                waited = true
            }
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
        } else if let crew, !crew.isEmpty {
            ScrollView {
                VStack(spacing: theme.spacing.l) {
                    Wordmark(height: 72)
                    CrewPicker(crew: crew, open: { _ in })
                    Button("Or connect your own agent", action: add)
                        .font(theme.font(theme.type.body, .semibold)).tint(c.inkSoft)
                        .accessibilityIdentifier("first-run-pair")
                }
                .padding(theme.spacing.xl)
            }
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
                    row(2, "Run one command on your computer")
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

/// Runs `work` on the main thread once `frames` display ticks have gone by, so
/// what the current pass changed is on screen first (YUI-108). The link holds it until then.
@MainActor private final class AfterFrames: NSObject {
    private var left: Int
    private let work: () -> Void

    private init(_ frames: Int, _ work: @escaping () -> Void) {
        left = frames
        self.work = work
    }

    static func run(_ frames: Int, _ work: @escaping () -> Void) {
        CADisplayLink(target: AfterFrames(frames, work), selector: #selector(tick(_:))).add(to: .main, forMode: .common)
    }

    @objc private func tick(_ l: CADisplayLink) {
        left -= 1
        guard left <= 0 else { return }
        l.invalidate()
        work()
    }
}

/// The working row, drawn once, unseen, soon after the thread shows (YUI-108): the first send of a
/// launch paid for building the working row's view types in the frame with the
/// bubble (about a fifth of that tap); now it doesn't.
private struct WorkingNoteWarmer: View {
    var agent: YuiAgent?
    @State private var warming = false
    @State private var warmed = false

    var body: some View {
        if !warmed {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .task {
                    try? await Task.sleep(for: .seconds(2))
                    warming = true
                    try? await Task.sleep(for: .milliseconds(500))
                    warmed = true
                }
            if warming {
                WorkingNote(agent: agent, since: .now, pickedUp: nil)
                    .opacity(0.001)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .offset(x: -2000)
            }
        }
    }
}

/// The agent owes a reply: one row, its face, a small moving mark and one
/// line, a working word and the time ("Pondering · 12s"). Before the host
/// picks it up it is "On its way". Long turns are normal (TestFlight: "assume
/// it's always going to take a little while"), so there is no time limit and
/// no fix-it advice here; an agent whose computer is away gets its own
/// asleep/offline note instead. When the agent says what it is doing
/// (`doing`, YL.md section 5, The working row; YUI-63 step 2) its words take
/// the word's place, and a thin bar in its accent shows the step when it
/// knows how many there are. The seconds keep counting from the start.
/// Under the row, how long this agent usually takes, from its recent turns
/// ("Usually 1 to 3 min", TestFlight AE1JyD1P: "like when you install new
/// software on an iPhone, it tells you how long it takes").
struct WorkingNote: View {
    var agent: YuiAgent?
    var since: Date?
    var pickedUp: Date?
    /// The agent's newest `doing`: its words and step. Nil: the working word.
    var doing: YLDoing? = nil
    /// How long this agent's turns usually take. Nil: too few to say.
    var usual: ClosedRange<TimeInterval>? = nil
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

    /// "Pondering · 1m 24s", or "On its way · 3s" before pickup. With a doing:
    /// "Reading your calendar, step 2 of 5 · 12s".
    static func label(since: Date?, pickedUp: Date?, now: Date, doing: YLDoing? = nil) -> String {
        var word = shown(doing, pickedUp: pickedUp, now: now)
        if let d = doing, let step = d.step, let of = d.of { word += ", step \(step) of \(of)" }
        guard let start = pickedUp ?? since else { return word }
        return "\(word) · \(elapsed(now.timeIntervalSince(start)))"
    }

    /// The agent's own words when it said what it is doing, else the working word.
    static func shown(_ doing: YLDoing?, pickedUp: Date?, now: Date) -> String {
        doing?.text ?? word(pickedUp: pickedUp, now: now)
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

    /// Turns needed before the row guesses a range.
    static let usualNeeds = 3

    /// The usual range from recent turn times: the middle of them (20th to
    /// 80th percentile), so one odd turn doesn't stretch it. Nil under three.
    static func usual(_ times: [TimeInterval]) -> ClosedRange<TimeInterval>? {
        guard times.count >= usualNeeds else { return nil }
        let t = times.sorted()
        func at(_ p: Double) -> TimeInterval { t[Int((Double(t.count - 1) * p).rounded())] }
        return at(0.2)...at(0.8)
    }

    /// "10 to 25s", "40s to 2 min", "1 to 3 min", "about 2 min". The low end
    /// rounds down and the high end up, so the range never promises too much.
    static func range(_ r: ClosedRange<TimeInterval>) -> String {
        func low(_ t: TimeInterval) -> (Int, Bool) {
            t < 60 ? (max(5, Int(t) / 5 * 5), false) : (Int(t) / 60, true)
        }
        func high(_ t: TimeInterval) -> (Int, Bool) {
            t < 60 ? (min(60, max(5, Int((t / 5).rounded(.up)) * 5)), false) : (Int((t / 60).rounded(.up)), true)
        }
        let (lo, loMin) = low(r.lowerBound)
        var (hi, hiMin) = high(r.upperBound)
        if !hiMin, hi == 60 { (hi, hiMin) = (1, true) }
        if loMin, hiMin, lo == hi { return "about \(hi) min" }
        if !loMin, !hiMin, lo == hi { return "about \(hi)s" }
        if loMin, hiMin { return "\(lo) to \(hi) min" }
        if !loMin, !hiMin { return "\(lo) to \(hi)s" }
        return "\(lo)s to \(hi) min"
    }

    /// The line under the row, or nil: how long it usually takes, then past
    /// that, that it's running long; after two minutes, that leaving is fine.
    static func note(elapsed: TimeInterval, usual: ClosedRange<TimeInterval>?) -> String? {
        let leave = "Leave any time, the answer lands here."
        guard let usual else { return elapsed > longTurn ? "Long jobs are fine. \(leave)" : nil }
        if elapsed > usual.upperBound { return "Longer than usual (\(range(usual))). \(leave)" }
        let said = "Usually \(range(usual))."
        return elapsed > longTurn ? "\(said) \(leave)" : said
    }

    var body: some View {
        let c = theme.swatch(scheme)
        let name = agent?.name ?? "Your agent"
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let word = Self.shown(doing, pickedUp: pickedUp, now: ctx.date)
            let took = (pickedUp ?? since).map { Self.elapsed(ctx.date.timeIntervalSince($0)) }
            let note = (pickedUp ?? since).flatMap { Self.note(elapsed: ctx.date.timeIntervalSince($0), usual: usual) }
            HStack(alignment: .top, spacing: theme.spacing.s) {
                AgentFace(agent: agent)
                VStack(alignment: .leading, spacing: theme.spacing.xs) {
                    VStack(alignment: .leading, spacing: theme.spacing.xs) {
                        HStack(spacing: theme.spacing.s) {
                            Dots(color: c.accent, still: reduceMotion)
                            HStack(spacing: 0) {
                                // One line: long words end in an ellipsis, the seconds always show.
                                Text(word)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .id(word)
                                    .transition(reduceMotion ? .identity : .push(from: .bottom).combined(with: .opacity))
                                if let took {
                                    Text(" · \(took)")
                                        .monospacedDigit()
                                        .fixedSize()
                                        .layoutPriority(1)
                                        .contentTransition(reduceMotion ? .identity : .numericText())
                                }
                            }
                            .foregroundStyle(c.inkSoft)
                            .animation(reduceMotion ? nil : .snappy, value: word)
                        }
                        if let progress = doing?.progress {
                            StepBar(progress: progress, color: c.accent, track: c.outline, still: reduceMotion)
                        }
                    }
                    .font(theme.font(theme.type.caption, .semibold))
                    .padding(.horizontal, theme.spacing.m)
                    .padding(.vertical, theme.spacing.s + 2)
                    .background(c.agentBubble, in: RoundedRectangle(cornerRadius: theme.radius.bubble))
                    .overlay(RoundedRectangle(cornerRadius: theme.radius.bubble).stroke(c.outline, lineWidth: 1.5))
                    if let note {
                        Text(note)
                            .font(theme.font(theme.type.caption, .semibold))
                            .foregroundStyle(c.inkSoft)
                            .padding(.leading, theme.spacing.xs)
                            .contentTransition(.opacity)
                            .transition(.opacity)
                            .accessibilityIdentifier("working-usual")
                    }
                }
                Spacer(minLength: 48)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibility(name: name, label: Self.label(since: since, pickedUp: pickedUp, now: ctx.date, doing: doing),
                                                   note: note))
            .accessibilityIdentifier("working")
        }
        .transition(.opacity)
    }

    /// VoiceOver: who, the row, then the line under it. "Yui: Pondering · 12s. Usually 1 to 3 min."
    static func accessibility(name: String, label: String, note: String? = nil) -> String {
        "\(name): \(label)" + (note.map { ". " + $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) + "." } ?? "")
    }

    /// How far along the agent is: a thin bar in its accent, filled to the
    /// step. It slides to each new step; under Reduce Motion it just changes.
    private struct StepBar: View {
        let progress: Double
        let color: Color
        let track: Color
        let still: Bool
        var body: some View {
            Capsule()
                .fill(track.opacity(0.6))
                .frame(height: 3)
                .overlay(alignment: .leading) {
                    GeometryReader { g in
                        Capsule().fill(color)
                            .frame(width: max(3, g.size.width * min(1, max(0, progress))))
                    }
                }
                .frame(minWidth: 96)
                .animation(still ? nil : .snappy, value: progress)
                .accessibilityHidden(true)
        }
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

#if DEBUG
/// -yuiAutoScroll (YUI-101): moves the thread's own scroll view a frame at a time,
/// 3 s up at 1200 pt/s and 3 s back down, like a long drag. Timed as one scroll.
@MainActor
final class AutoScroll: NSObject {
    private static var running: AutoScroll?
    private let view: UIScrollView
    private var start: CFTimeInterval = 0
    private var link: CADisplayLink?

    private init(_ view: UIScrollView) { self.view = view }

    static func run() {
        let windows = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }
        guard let view = windows.flatMap(scrollViews).max(by: { $0.contentSize.height < $1.contentSize.height }) else { return }
        let a = AutoScroll(view)
        running = a
        Perf.shared.scrollMoving(true)
        let l = CADisplayLink(target: a, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        a.link = l
    }

    private static func scrollViews(in v: UIView) -> [UIScrollView] {
        var out = v.subviews.flatMap(scrollViews)
        if let s = v as? UIScrollView, s.contentSize.height > s.bounds.height * 2 { out.append(s) }
        return out
    }

    @objc private func tick(_ l: CADisplayLink) {
        if start == 0 { start = l.timestamp }
        let t = l.timestamp - start
        let dt = l.targetTimestamp - l.timestamp
        guard t < 6 else {
            l.invalidate()
            Perf.shared.scrollMoving(false)
            Self.running = nil
            return
        }
        let top = -view.adjustedContentInset.top
        let bottom = view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom
        let y = view.contentOffset.y + (t < 3 ? -1200 : 1200) * dt
        view.contentOffset.y = min(max(y, top), bottom)
    }
}
#endif

/// Where a drag has the drawer, points from its resting place (YUI-54). Its own
/// object so only `DrawerLayer` observes it: a drag frame redraws the drawer, not the chat.
@Observable @MainActor
final class DrawerMotion {
    var drag: CGFloat?
}

/// Over the chat, from the left, stopping short so the chat peeks out on the right.
/// A tap on that sliver or a drag back to the left closes it.
private struct DrawerLayer<Content: View>: View {
    let motion: DrawerMotion
    let open: Bool
    let shows: Bool
    /// The drawer's width.
    let width: CGFloat
    let reduceMotion: Bool
    let settle: (Bool) -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    /// How far out the drawer is, 0 closed to 1 open, following a drag when there is one.
    private var shown: CGFloat {
        guard let d = motion.drag else { return open ? 1 : 0 }
        return min(1, max(0, open ? 1 + d / width : d / width))
    }

    /// Drawn once, unseen, soon after the thread shows (YUI-106): the first open paid
    /// for building every drawer view type (about 60% of that tap); now it doesn't.
    @State private var warming = false
    @State private var warmed = false

    var body: some View {
        let p = shown
        if shows, !warmed, !(p > 0 || open) {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .task {
                    try? await Task.sleep(for: .seconds(2))
                    warming = true
                    try? await Task.sleep(for: .milliseconds(500))
                    warmed = true
                }
            if warming {
                content()
                    .frame(width: width)
                    .opacity(0.001)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .offset(x: -width * 2)
            }
        }
        if shows, p > 0 || open {
            GeometryReader { geo in
                let w = geo.size.width * Drawer.fraction
                ZStack(alignment: .leading) {
                    Color.black.opacity(0.32 * p)
                        .ignoresSafeArea()
                        .contentShape(.rect)
                        .onTapGesture { settle(false) }
                        .accessibilityLabel("Close the menu")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { settle(false) }
                    content()
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
                    motion.drag = min(0, x)
                } ended: { x, v in
                    settle(!(x < -w * Drawer.threshold || v < -Drawer.flick))
                })
            }
            .transition(.identity)
        }
    }
}


/// What the chats (YUI-169) need from the screen, apart from the body so the body type-checks:
/// a new chat starts at the newest message, the phone being on screen says what is being read,
/// and a chat Yui's server refused (the app is too old, or the list is full) gives the words back
/// to the composer and says why in plain words.
private struct ChatsHooks: ViewModifier {
    let store: ChatStore
    let composer: ComposerModel
    @Binding var window: Int
    @Binding var pinned: Bool
    @Binding var notice: String?
    let phase: ScenePhase
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let c = theme.swatch(scheme)
        content
            .onChange(of: store.chatID) {
                window = ChatView.windowStep
                if store.places[store.chatID ?? ""] == nil { pinned = true }
            }
            .onChange(of: phase, initial: true) { store.watching = phase == .active }
            .onChange(of: store.refusal?.note) {
                guard let r = store.refusal else { return }
                composer.draft = r.text
                store.clearRefusal()
                say(r.note)
            }
            .overlay(alignment: .top) {
                if let note = notice {
                    Label(note, systemImage: "info.circle")
                        .font(theme.font(theme.type.caption, .semibold))
                        .foregroundStyle(c.ink)
                        .padding(.horizontal, theme.spacing.l).padding(.vertical, theme.spacing.s)
                        .background(c.surface, in: Capsule())
                        .overlay(Capsule().stroke(c.outline, lineWidth: 1))
                        .padding(.top, 70)
                        .padding(.horizontal, theme.spacing.l)
                        .transition(.opacity)
                        .accessibilityIdentifier("chat-notice")
                }
            }
    }

    private func say(_ text: String) {
        withAnimation { notice = text }
        Task {
            try? await Task.sleep(for: .seconds(5))
            withAnimation { if notice == text { notice = nil } }
        }
    }
}
