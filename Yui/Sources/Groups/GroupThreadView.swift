import SwiftUI
import YuiLines

/// One group, full screen (YUI-94): the lead first in the header with a crown, bubbles in each
/// sender's look on the person's background, one working row per agent with Stop, handoff and
/// guard rows, and a composer where @ suggests the members. Spec: yuigui/spec/GROUPS.md.
struct GroupThreadView: View {
    let groupID: String
    @Environment(Account.self) private var account
    @Environment(AgentStore.self) private var agents
    @Environment(GroupStore.self) private var groups
    @Environment(\.appTheme) private var appTheme
    @Environment(\.colorScheme) private var scheme
    @State private var thread: GroupThread?
    @State private var draft = ""
    @State private var settings = false
    @State private var jump: String?
    @FocusState private var focused: Bool

    private var info: GroupInfo? { groups.groups.first { $0.id == groupID } }

    var body: some View {
        let c = appTheme.swatch(scheme)
        VStack(spacing: 0) {
            if let info, let thread {
                Header(info: info, members: members(info), thread: thread,
                       close: { groups.openID = nil }, settings: { settings = true },
                       makeLead: { id in Task { await makeLead(id) } })
                transcript(info, thread, c)
                composer(info, thread, c)
            } else {
                Spacer(); ProgressView(); Spacer()
            }
        }
        .background(c.background.ignoresSafeArea())
        .environment(\.yuiTheme, appTheme)
        .task(id: info?.id) {
            guard let info, thread == nil else { return }
            let t = GroupThread(info: info, client: groups.client(account))
            thread = t
            t.start()
        }
        .onChange(of: info) { _, fresh in if let fresh { thread?.update(fresh) } }
        .onDisappear { thread?.stopPolling() }
        .sheet(isPresented: $settings) {
            if let info { GroupSettings(info: info) { settings = false } }
        }
        .overlay { Color.clear.allowsHitTesting(false).accessibilityIdentifier("group-thread") }
    }

    private func members(_ info: GroupInfo) -> [YuiAgent] { info.ordered(agents.agents) { $0.id } }

    private func agent(_ id: String) -> YuiAgent? { agents.agents.first { $0.id == id } }

    private func makeLead(_ id: String) async {
        do { try await groups.client(account).makeLead(id, thread: groupID); await groups.refresh() }
        catch { thread?.notice = GroupStore.words(error) }
    }

    // MARK: Transcript

    private func transcript(_ info: GroupInfo, _ thread: GroupThread, _ c: Swatch) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: appTheme.spacing.m) {
                    if thread.loaded && thread.shown.isEmpty {
                        Text("Say something. Start with @ to ask one of them, or just talk and \(agent(info.lead)?.name ?? "the lead") answers.")
                            .font(appTheme.font(appTheme.type.caption)).foregroundStyle(c.inkSoft)
                            .padding(.top, appTheme.spacing.l)
                    }
                    ForEach(thread.shown) { item in
                        row(item, info, thread).id(item.id)
                    }
                    ForEach(thread.working, id: \.agent) { w in working(w, thread) }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, appTheme.spacing.l).padding(.vertical, appTheme.spacing.m)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: thread.shown.count) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: thread.working.count) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: jump) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
                jump = nil
            }
        }
    }

    @ViewBuilder
    private func row(_ item: GroupItem, _ info: GroupInfo, _ thread: GroupThread) -> some View {
        switch item {
        case .you(_, let text, let to, _):
            YouBubble(text: text, to: to.compactMap { agent($0)?.name })
        case .agent(let id, let who, let text, _):
            AgentBubbles(id: id, agent: agent(who), text: text,
                         reply: { thread.replyTarget = who },
                         emit: { thread.emit($0, from: who) },
                         open: { agents.selectedID = who; groups.openID = nil })
        case .handoff(_, let from, let to, let ask, let msg, let cancelled):
            HandoffRow(from: agent(from), to: agent(to), ask: ask, cancelled: cancelled) {
                if let msg { jump = msg }
            }
        case .guardAsk(let id, let asker, _, let toName, let text, let state):
            GuardRow(asker: agent(asker), toName: toName, text: text, state: state,
                     letIt: { thread.letIt(id) }, stop: { thread.stop() })
        case .status(_, let about, let text):
            GroupStatusLine(agent: agent(about), text: text)
        }
    }

    private func working(_ w: GroupWorking, _ thread: GroupThread) -> some View {
        HStack(alignment: .top, spacing: appTheme.spacing.s) {
            WorkingNote(agent: agent(w.agent), since: w.since, pickedUp: w.pickedUp, doing: w.doing)
                .environment(\.yuiTheme, agent(w.agent)?.yuiTheme ?? appTheme)
            Button("Stop") { thread.stop() }
                .font(appTheme.font(appTheme.type.caption, .bold))
                .buttonStyle(.bordered).tint(appTheme.swatch(scheme).inkSoft)
                .accessibilityIdentifier("group-stop-\(agent(w.agent)?.handle ?? w.agent)")
        }
    }

    // MARK: Composer

    private func composer(_ info: GroupInfo, _ thread: GroupThread, _ c: Swatch) -> some View {
        let all = members(info)
        let partial = GroupRows.partialMention(draft)
        let suggestions = partial.map { p in
            all.filter { p.isEmpty || $0.handle.lowercased().hasPrefix(p.lowercased()) || $0.name.lowercased().hasPrefix(p.lowercased()) }
        } ?? []
        return VStack(spacing: appTheme.spacing.xs) {
            if let note = thread.notice {
                Text(note).font(appTheme.font(appTheme.type.caption)).foregroundStyle(.red).accessibilityIdentifier("group-notice")
            }
            if let who = thread.replyTarget.flatMap(agent) {
                HStack {
                    Label("Replying to \(who.name)", systemImage: "arrowshape.turn.up.left")
                        .font(appTheme.font(appTheme.type.caption, .semibold)).foregroundStyle(c.inkSoft)
                    Spacer()
                    Button { thread.replyTarget = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .tint(c.inkSoft).accessibilityLabel("Cancel reply")
                }
                .padding(.horizontal, appTheme.spacing.l)
            }
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: appTheme.spacing.s) {
                        ForEach(suggestions) { a in
                            Button { draft = GroupRows.completing(draft, with: a.handle) } label: {
                                HStack(spacing: 6) {
                                    AgentBadge(agent: a, size: 22)
                                    Text("@\(a.handle)").font(appTheme.font(appTheme.type.caption, .semibold)).foregroundStyle(c.ink)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(c.surface, in: Capsule())
                            }
                            .accessibilityIdentifier("group-at-\(a.handle)")
                        }
                    }
                    .padding(.horizontal, appTheme.spacing.l)
                }
            }
            GroupBar(draft: $draft, focused: $focused, thread: thread, members: all, account: account)
        }
        .padding(.vertical, appTheme.spacing.s)
        .background(c.background)
    }
}

// MARK: - Header

private struct Header: View {
    let info: GroupInfo
    let members: [YuiAgent]
    let thread: GroupThread
    let close: () -> Void
    let settings: () -> Void
    let makeLead: (String) -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        HStack(spacing: theme.spacing.m) {
            Button(action: close) { Image(systemName: "chevron.down").font(.body.weight(.semibold)) }
                .tint(c.ink).accessibilityLabel("Close group").accessibilityIdentifier("group-close")
            // The lead first, with a crown. Hold a face for Make lead.
            HStack(spacing: -10) {
                ForEach(Array(members.prefix(5).enumerated()), id: \.element.id) { i, a in
                    AgentBadge(agent: a, size: 34)
                        .overlay(alignment: .topTrailing) { if a.id == info.lead { Crown(size: 34) } }
                        .overlay(Circle().stroke(c.background, lineWidth: 2).padding(-1))
                        .zIndex(Double(10 - i))
                        .contextMenu {
                            if a.id != info.lead { Button("Make lead", systemImage: "crown") { makeLead(a.id) } }
                        }
                        .accessibilityLabel(a.id == info.lead ? "\(a.name), lead" : a.name)
                        .accessibilityIdentifier("group-face-\(a.handle)")
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(info.title).font(theme.font(theme.type.body, .bold)).foregroundStyle(c.ink).lineLimit(1)
                Text(members.map(\.name).joined(separator: ", "))
                    .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: settings) { Image(systemName: "slider.horizontal.3") }
                .tint(c.ink).accessibilityLabel("Group settings").accessibilityIdentifier("group-settings")
        }
        .padding(.horizontal, theme.spacing.l).padding(.vertical, theme.spacing.m)
        .background(c.surface.ignoresSafeArea(edges: .top))
    }
}

// MARK: - Rows

private struct YouBubble: View {
    let text: String
    let to: [String]
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .trailing, spacing: theme.spacing.xs) {
            if !to.isEmpty {
                Text("To \(to.joined(separator: ", "))")
                    .font(theme.font(theme.type.caption, .semibold)).foregroundStyle(theme.swatch(scheme).inkSoft)
            }
            BubbleText(text: text, fromUser: true)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
    }
}

/// An agent's answer in its own look: its face, its name over the bubble, text as bubbles,
/// screens inline. Hold a bubble for Reply: the reply goes to this agent.
private struct AgentBubbles: View {
    let id: String
    let agent: YuiAgent?
    let text: String
    let reply: () -> Void
    let emit: (YLEvent) -> Void
    let open: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = agent?.yuiTheme ?? YuiTheme.yui
        let c = theme.swatch(scheme)
        HStack(alignment: .top, spacing: theme.spacing.s) {
            if let agent { AgentBadge(agent: agent, size: 34) } else { YuiAvatar(size: 34) }
            VStack(alignment: .leading, spacing: theme.spacing.xs) {
                Text(agent?.name ?? "Yui").font(theme.font(theme.type.caption, .bold)).foregroundStyle(c.inkSoft)
                ForEach(Array(YuiFence.split(text).enumerated()), id: \.offset) { _, seg in
                    switch seg {
                    case .text(let t):
                        BubbleText(text: t, fromUser: false, markdown: true)
                            .contextMenu { Button("Reply", systemImage: "arrowshape.turn.up.left", action: reply) }
                            .accessibilityIdentifier("group-bubble")
                    case .yl(let lines):
                        Screen(lines: lines, scope: id, agent: agent, emit: emit, open: open)
                    }
                }
            }
            Spacer(minLength: 48)
        }
        .environment(\.yuiTheme, theme)
    }

    /// Screen 1 draws here; a `>2` and up belongs to the agent's own thread, so the group says so with Open.
    private struct Screen: View {
        let lines: String
        let scope: String
        let agent: YuiAgent?
        let emit: (YLEvent) -> Void
        let open: () -> Void
        @Environment(\.yuiTheme) private var theme
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            let screen = YLScreen(lines)
            let inline = YLItem.layout(screen.top, pills: [:])
            if screen.top.isEmpty {
                EmptyView()
            } else if lines.range(of: #"(^|\n)\s*>[2-9]|(^|\n)\s*>1[0-2]"#, options: .regularExpression) != nil {
                Button(action: open) {
                    Label("\(agent?.name ?? "Yui") put a screen on its page", systemImage: "rectangle.portrait.on.rectangle.portrait")
                        .font(theme.font(theme.type.caption, .semibold))
                        .padding(.horizontal, theme.spacing.m).padding(.vertical, theme.spacing.s)
                        .background(theme.swatch(scheme).surface, in: Capsule())
                }
                .accessibilityIdentifier("group-open-screen")
            } else {
                YLItemsView(items: inline, openStage: open)
                    .environment(\.ylScope, scope)
                    .environment(\.ylComponents, screen.components)
                    .environment(\.ylEmit, YLEmit { e in emit(e) })
            }
        }
    }
}

/// "Coach asked Sage", with both faces, and the ask in one line.
private struct HandoffRow: View {
    let from: YuiAgent?
    let to: YuiAgent?
    let ask: String
    let cancelled: Bool
    let tap: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        Button(action: tap) {
            HStack(spacing: theme.spacing.s) {
                if let from { AgentBadge(agent: from, size: 22) }
                Image(systemName: "arrow.right").font(.caption.weight(.bold)).foregroundStyle(c.inkSoft)
                if let to { AgentBadge(agent: to, size: 22) }
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(from?.name ?? "An agent") asked \(to?.name ?? "another")" + (cancelled ? ", stopped" : ""))
                        .font(theme.font(theme.type.caption, .bold)).foregroundStyle(c.ink)
                    if !ask.isEmpty {
                        Text(ask).font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, theme.spacing.m).padding(.vertical, theme.spacing.s)
            .background(c.surface.opacity(cancelled ? 0.5 : 1), in: RoundedRectangle(cornerRadius: theme.radius.bubble))
            .overlay(RoundedRectangle(cornerRadius: theme.radius.bubble).stroke(c.outline, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("group-handoff")
    }
}

/// A held ask, in the asking agent's look: Let it / Stop here.
private struct GuardRow: View {
    let asker: YuiAgent?
    let toName: String
    let text: String
    let state: GroupItem.GuardState
    let letIt: () -> Void
    let stop: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = asker?.yuiTheme ?? YuiTheme.yui
        let c = theme.swatch(scheme)
        HStack(alignment: .top, spacing: theme.spacing.s) {
            if let asker { AgentBadge(agent: asker, size: 34) }
            VStack(alignment: .leading, spacing: theme.spacing.s) {
                Text(text).font(theme.font(theme.type.body, .medium)).foregroundStyle(c.agentInk)
                switch state {
                case .held:
                    HStack(spacing: theme.spacing.s) {
                        Button("Let it", action: letIt)
                            .buttonStyle(.borderedProminent).tint(c.accent).accessibilityIdentifier("group-letit")
                        Button("Stop here", action: stop)
                            .buttonStyle(.bordered).tint(c.inkSoft).accessibilityIdentifier("group-stophere")
                    }
                    .font(theme.font(theme.type.caption, .bold))
                case .continued: Text("Let through.").font(theme.font(theme.type.caption, .semibold)).foregroundStyle(c.inkSoft)
                case .stopped: Text("Stopped here.").font(theme.font(theme.type.caption, .semibold)).foregroundStyle(c.inkSoft)
                case .gone: Text("\(toName) isn't in the group anymore.").font(theme.font(theme.type.caption, .semibold)).foregroundStyle(c.inkSoft)
                }
            }
            .padding(theme.spacing.m)
            .background(c.agentBubble, in: RoundedRectangle(cornerRadius: theme.radius.bubble))
            .overlay(RoundedRectangle(cornerRadius: theme.radius.bubble).stroke(c.accent.opacity(0.6), lineWidth: 1.5))
            Spacer(minLength: 24)
        }
        .background { Color.clear.allowsHitTesting(false).accessibilityIdentifier("group-guard") }
    }
}

/// A quiet line about one agent: asleep, offline, stopped. In its look.
private struct GroupStatusLine: View {
    let agent: YuiAgent?
    let text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = agent?.yuiTheme ?? YuiTheme.yui
        HStack(spacing: theme.spacing.s) {
            if let agent { AgentBadge(agent: agent, size: 18) }
            Text(text).font(theme.font(theme.type.caption, .semibold)).foregroundStyle(theme.swatch(scheme).inkSoft)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("group-status")
    }
}

// MARK: - Settings

/// Max hops, members (add, leave), lead, archive.
struct GroupSettings: View {
    let info: GroupInfo
    let done: () -> Void
    @Environment(Account.self) private var account
    @Environment(AgentStore.self) private var agents
    @Environment(GroupStore.self) private var groups
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var title = ""
    @State private var error: String?
    @State private var confirmArchive = false

    private var current: GroupInfo { groups.groups.first { $0.id == info.id } ?? info }
    private var inGroup: [YuiAgent] { current.ordered(agents.agents) { $0.id } }
    private var outside: [YuiAgent] { agents.agents.filter { !current.members.contains($0.id) } }

    var body: some View {
        let c = theme.swatch(scheme)
        NavigationStack {
            List {
                Section("Name") {
                    HStack {
                        TextField("Group name", text: $title).onSubmit { Task { await rename() } }
                            .accessibilityIdentifier("group-settings-name")
                        NameMic(text: $title, id: "group-settings-name-mic") { Task { await rename() } }
                    }
                }
                Section {
                    Stepper(value: Binding(get: { current.maxHops }, set: { n in Task { await hops(n) } }), in: 1...5) {
                        Text("Max hops: \(current.maxHops)")
                    }
                    .accessibilityIdentifier("group-hops")
                } footer: {
                    Text("How many times agents may hand work to each other before they ask you.")
                }
                Section("In the group") {
                    ForEach(inGroup) { a in
                        HStack {
                            AgentBadge(agent: a, size: 30)
                            Text(a.name)
                            if a.id == current.lead { Crown(size: 18) }
                            Spacer()
                            if a.id != current.lead {
                                Menu {
                                    Button("Make lead", systemImage: "crown") { Task { await call { try await $0.makeLead(a.id, thread: info.id) } } }
                                    Button("Leave group", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                                        Task { await call { try await $0.leave(a.id, thread: info.id) } }
                                    }
                                } label: { Image(systemName: "ellipsis.circle") }
                                .accessibilityIdentifier("group-member-\(a.handle)")
                            }
                        }
                    }
                }
                if !outside.isEmpty {
                    Section("Add") {
                        ForEach(outside) { a in
                            Button { Task { await call { try await $0.add([a.id], to: info.id) } } } label: {
                                Label { Text(a.name) } icon: { AgentBadge(agent: a, size: 26) }
                            }
                            .accessibilityIdentifier("group-add-\(a.handle)")
                        }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("group-settings-error") } }
                Section {
                    Button("Archive group", role: .destructive) { confirmArchive = true }
                        .accessibilityIdentifier("group-archive")
                } footer: { Text("Nothing more goes in an archived group. Its words stay.") }
            }
            .scrollContentBackground(.hidden).background(c.background)
            .navigationTitle(current.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { Task { await rename(); done() } }.tint(c.accent) } }
            .confirmationDialog("Archive \(current.title)?", isPresented: $confirmArchive, titleVisibility: .visible) {
                Button("Archive", role: .destructive) { Task { await groups.archive(info.id); done() } }
            }
        }
        .onAppear { title = info.title }
        .presentationDetents([.medium, .large])
    }

    private func rename() async {
        guard let t = GroupStore.validTitle(title), t != current.title else { return }
        await call { try await $0.rename(info.id, to: t) }
    }

    private func hops(_ n: Int) async { await call { try await $0.setMaxHops(n, thread: info.id) } }

    private func call(_ work: (GroupClient) async throws -> Void) async {
        do { try await work(groups.client(account)); error = nil } catch { self.error = GroupStore.words(error) }
        await groups.refresh()
    }
}
