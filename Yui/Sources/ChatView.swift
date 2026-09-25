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
    /// The first-run button opens Add agent straight from the chat.
    @State private var addFirst = false
    /// The message open in Select text.
    @State private var selecting: ChatMessage?
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
                        // Screens are for reading: the composer stays with the chat.
                        if onChat {
                            inputBar(c)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(theme.spring, value: onChat)
                }
            }
            // Held agent bubble: the tapback bar over a dimmed thread (YUI-49).
            .overlayPreferenceValue(ReactionAnchor.self) { anchor in
                GeometryReader { geo in
                    if let anchor, let m = store.reactingMessage {
                        ReactionOverlay(message: m, rect: geo[anchor], size: geo.size, current: store.reaction(for: m)) { pick in
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
                        }
                        .id(m.id)
                        .transition(.opacity)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Your agents", systemImage: "person.2.fill") { showAgents = true }
                        .tint(c.inkSoft)
                }
                ToolbarItem(placement: .principal) {
                    if let agent = store.agent {
                        Button { showAgents = true } label: {
                            HStack(spacing: theme.spacing.s) {
                                AgentBadge(agent: agent, size: 26)
                                Text(agent.name)
                                    .font(theme.font(theme.type.body, theme.strong))
                                    .foregroundStyle(c.ink)
                                Circle().fill(agent.liveness == .online ? c.mint : agent.liveness == .asleep ? c.lavender : c.outline)
                                    .frame(width: 8, height: 8)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Talking to \(agent.name), \(agent.liveness == .pending ? "offline" : agent.liveness.rawValue)")
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
                    .presentationCornerRadius(theme.radius.card)
            }
            .sheet(isPresented: $addFirst) {
                // Paired and "Say hi": the new agent's thread is the chat.
                AddAgentSheet { id in
                    agents.selectedID = id
                    addFirst = false
                }
                .presentationDetents([.large])
                .presentationCornerRadius(theme.radius.card)
            }
            // Select text: the held message's words, read-only, to copy any part.
            .sheet(item: $selecting) { m in
                SelectTextSheet(text: m.text)
                    .presentationDetents([.medium, .large])
                    .presentationCornerRadius(theme.radius.card)
            }
            .sheet(isPresented: $showAgents) {
                AgentsView()
                    .presentationDetents([.medium, .large])
                    .presentationCornerRadius(theme.radius.card)
            }
        }
        // The chat steps back a little while the stage is up (YUI-13).
        .mask { RoundedRectangle(cornerRadius: store.stageOpen ? 38 : 0).ignoresSafeArea() }
        .scaleEffect(store.stageOpen ? 0.92 : 1)
        .background(Color.black.ignoresSafeArea())
        if let m = store.stageMessage, let yl = m.yl, !yl.staged(agentStyle).isEmpty {
            StageView(components: yl.staged(agentStyle), scope: m.id, agent: store.agent, open: store.stageOpen,
                      close: store.closeStage)
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
        .onChange(of: agentStyle, initial: true) { store.style = agentStyle }
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
            if !onChat { focused = false }
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
            while !Task.isCancelled {
                await agents.refresh()
                try? await Task.sleep(for: .seconds(30))
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
            agents.selectedID = id
            if !agents.agents.contains(where: { $0.id == id }) { Task { await agents.refresh() } }
        }
        .tint(c.accent)
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
                    ForEach(store.messages) { m in
                        if let yl = m.yl {
                            YLReply(screen: yl, scope: m.id, agent: store.agent, style: agentStyle) { store.openStage(m.id) }
                        } else {
                            Bubble(message: m, agent: store.agent, pending: outbox.isPending(m.id),
                                   reaction: store.wearsReaction(m) ? store.reaction(for: m) : nil,
                                   lifted: store.reacting == m.id,
                                   open: { openReactions(m.id) },
                                   react: { store.react(m.id, with: $0) },
                                   select: { selecting = m })
                        }
                    }
                    if let agent = store.agent, outbox.offline, !outbox.pending(agentID: agent.id).isEmpty {
                        // On the phone, not on Yui yet: it sends itself when the connection is back.
                        QuietNote(text: "Not sent yet. It goes the moment you're back online.", icon: "clock")
                    } else if store.waiting, let agent = store.agent, agent.liveness != .online {
                        // Delivered, but the agent's computer is away: say so instead of fake dots.
                        QuietNote(text: agent.liveness == .asleep
                                  ? "\(agent.name) is asleep. It gets this when its computer wakes."
                                  : "\(agent.name) is offline. It gets this when its gateway starts again.",
                                  icon: agent.liveness == .asleep ? "moon.zzz" : "powersleep")
                    } else if store.waiting {
                        TypingDots(agent: store.agent).id("typing")
                        WorkingNote(agent: store.agent, since: store.waitingSince, pickedUp: store.pickedUpAt)
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
            .scrollDismissesKeyboard(.interactively)
            // How far above the newest message the view sits, in screens.
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                // containerSize is inside the insets (nav bar above, composer below).
                let below = geo.contentSize.height - geo.contentInsets.top - geo.contentOffset.y - geo.containerSize.height
                return below / max(geo.containerSize.height, 1)
            } action: { _, screens in
                followScroll(screens: screens)
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

    private func inputBar(_ c: Swatch) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.s) {
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
        TextField(photos.isEmpty ? "Say something nice" : "Add a caption", text: $draft, axis: .vertical)
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
            if photos.isEmpty {
                // Not sent (no agent, no session): the words stay in the field.
                guard store.send(text) else { return }
                clearComposer()
                return
            }
            let outgoing = photos
            sending = true
            Task {
                defer { sending = false }
                do {
                    try await store.send(text, photos: outgoing)
                    photos = []
                    clearComposer()
                } catch {
                    flash("Couldn't send the photo. Try again.")
                }
            }
            return
        }
        let body = Attachments.body(text: text, photos: photos.count)
        withAnimation(ChatStore.sendSpring) {
            store.messages.append(ChatMessage(text: Attachments.caption(body: body, photos: photos.count), fromUser: true,
                                              photos: photos.map { .local($0.preview) }))
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

    private func jumpToBottom() {
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
        if let name = UserDefaults.standard.string(forKey: "yuiYL"), let text = YLSamples.text(name) {
            return [ChatMessage(text: "Show me the \(name) one", fromUser: true),
                    ChatMessage(text: "", fromUser: false, yl: YLScreen(text))]
        }
        return ProcessInfo.processInfo.arguments.contains("-yuiDemo") ? demo : []
    }
}

/// An agent reply in Yui Lines: the presets in line order, errors underneath.
/// Components that open on the stage show here as one pill that reopens it.
private struct YLReply: View {
    let screen: YLScreen
    let scope: String
    var agent: YuiAgent?
    var style: [String: String] = [:]
    let openStage: () -> Void
    @Environment(\.yuiTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: theme.spacing.s) {
            AgentFace(agent: agent)
            VStack(alignment: .leading, spacing: theme.spacing.m) {
                YLItemsView(items: YLItem.layout(screen.top, pills: style), openStage: openStage)
                ForEach(Array(screen.errors.enumerated()), id: \.offset) { YLErrorRow(node: $1) }
                ForEach(Array(screen.looks.enumerated()), id: \.offset) { _ in LookNote(agent: agent) }
            }
            .environment(\.ylScope, scope)
            .environment(\.ylComponents, screen.components)
        }
        .transition(.opacity)
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
    var open: () -> Void = {}
    var react: (Reaction?) -> Void = { _ in }
    var select: () -> Void = {}
    @Environment(\.yuiTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .bottom, spacing: theme.spacing.s) {
            if message.fromUser { Spacer(minLength: 48) } else { AgentFace(agent: agent) }
            VStack(alignment: .trailing, spacing: theme.spacing.xs) {
                ForEach(Array(message.photos.enumerated()), id: \.offset) { BubblePhoto(photo: $1) }
                if !message.text.isEmpty {
                    let words = BubbleText(text: message.text, fromUser: message.fromUser)
                        .accessibilityLabel(pending ? "\(message.text), not sent yet" : message.text)
                    if message.fromUser {
                        words
                    } else {
                        words.modifier(Reactable(text: message.text, reaction: reaction, lifted: lifted, open: open, react: react, select: select))
                    }
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

/// The agent is thinking.
private struct TypingDots: View {
    var agent: YuiAgent?
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        HStack(alignment: .bottom, spacing: theme.spacing.s) {
            AgentFace(agent: agent)
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(c.inkSoft).frame(width: 7, height: 7)
                        .phaseAnimator([0.3, 1.0]) { dot, o in dot.opacity(o) } animation: { _ in
                            .easeInOut(duration: 0.5).delay(Double(i) * 0.15)
                        }
                }
            }
            .padding(.horizontal, theme.spacing.l)
            .padding(.vertical, theme.spacing.m + 4)
            .background(c.agentBubble, in: Capsule())
            .overlay(Capsule().stroke(c.outline, lineWidth: 1.5))
            Spacer(minLength: 48)
        }
        .accessibilityLabel("\(agent?.name ?? "Yui") is typing")
        .transition(.opacity)
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
                Text(agent.liveness == .asleep ?
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

/// The agent owes a reply: say it is on it and for how long, the way Telegram
/// does. Long turns are normal (TestFlight: "assume it's always going to take
/// a little while"), so there is no time limit and no fix-it advice here; an
/// agent whose computer is away gets its own asleep/offline note instead.
struct WorkingNote: View {
    var agent: YuiAgent?
    var since: Date?
    var pickedUp: Date?
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    /// "Yui is working · 1m 24s". Before the host picks it up, it is still on its way.
    static func label(name: String, since: Date?, pickedUp: Date?, now: Date) -> String {
        guard let start = pickedUp ?? since else { return "\(name) is working" }
        let took = elapsed(now.timeIntervalSince(start))
        return pickedUp == nil ? "Sent to \(name) · \(took)" : "\(name) is working · \(took)"
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
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: theme.spacing.s) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(c.accent)
                        .symbolEffect(.variableColor.iterative.reversing, options: .repeat(.continuous))
                    Text(Self.label(name: name, since: since, pickedUp: pickedUp, now: ctx.date))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                if let start = pickedUp ?? since, ctx.date.timeIntervalSince(start) > Self.longTurn {
                    Text("Long jobs are fine. Leave any time, the answer lands here.")
                        .transition(.opacity)
                }
            }
            .font(theme.font(theme.type.caption, .semibold))
            .foregroundStyle(c.inkSoft)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("working")
        }
        .transition(.opacity)
    }
}
