import SwiftUI

/// Your agents, behind the nav's agents button. Agents are added by you, never
/// hardcoded: add one here (a pairing code for the host), from the host with
/// `hermes -p <profile> yui add`, or by asking an agent that holds an Agent
/// access token. Spec: yuigui/spec/AGENTS.md.
struct AgentsView: View {
    @Environment(AgentStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var adding = ProcessInfo.processInfo.arguments.contains("-yuiAddAgent")
    @State private var editing: YuiAgent?

    var body: some View {
        let c = theme.swatch(scheme)
        NavigationStack {
            Group {
                if store.loaded && store.agents.isEmpty {
                    EmptyAgents { adding = true }
                } else {
                    list(c)
                }
            }
            .background(c.background)
            .navigationTitle("Your agents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if store.agents.count > 1 {
                    ToolbarItem(placement: .cancellationAction) { EditButton().tint(c.inkSoft) }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.tint(c.accent) }
            }
        }
        .sheet(isPresented: $adding) {
            // Paired and "Say hi": straight to the new agent's thread.
            AddAgentSheet { id in
                store.selectedID = id
                adding = false
                dismiss()
            }
                .presentationDetents([.large])
                .presentationCornerRadius(theme.radius.card)
        }
        .sheet(item: $editing) { agent in
            EditAgentSheet(agent: agent)
                .presentationDetents([.medium, .large])
                .presentationCornerRadius(theme.radius.card)
        }
        // Live: agents added from a host or by another agent show up while the sheet is open.
        .task {
            while !Task.isCancelled {
                await store.refresh()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private func list(_ c: Swatch) -> some View {
        List {
            Section {
                ForEach(store.agents) { agent in
                    // Each row wears its agent's own look, whatever thread is open.
                    AgentRow(agent: agent, selected: agent.id == store.selected?.id) { editing = agent }
                        .environment(\.yuiTheme, agent.yuiTheme)
                        .contentShape(.rect)
                        .onTapGesture { store.selectedID = agent.id; dismiss() }
                        .swipeActions(edge: .trailing) {
                            Button("Edit", systemImage: "slider.horizontal.3") { editing = agent }.tint(c.inkSoft)
                        }
                }
                .onMove { store.move(from: $0, to: $1) }
            } header: {
                Text("Who do you want to talk to?")
                    .font(theme.font(theme.type.body, .semibold))
                    .foregroundStyle(c.inkSoft)
                    .textCase(nil)
            }
            Section {
                Button { adding = true } label: {
                    Label("Add agent", systemImage: "plus.circle.fill")
                        .font(theme.font(theme.type.body, .bold))
                        .foregroundStyle(c.accent)
                }
                .listRowBackground(c.surface)
            } footer: {
                if let error = store.error {
                    Text(error).font(theme.font(theme.type.caption)).foregroundStyle(.red)
                }
            }
        }
        .scrollContentBackground(.hidden)
    }
}

/// Avatar for any agent, always in that agent's own look (whatever thread is open):
/// Yui's mark, or an initial chip in the agent's accent.
struct AgentBadge: View {
    let agent: YuiAgent
    var size: Double

    var body: some View {
        Group {
            if agent.isYui {
                YuiAvatar(size: size)
            } else {
                AgentAvatar(name: agent.name, size: size)
            }
        }
        .environment(\.yuiTheme, agent.yuiTheme)
    }
}

private struct AgentRow: View {
    let agent: YuiAgent
    let selected: Bool
    let edit: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        HStack(spacing: theme.spacing.m) {
            AgentBadge(agent: agent, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: theme.spacing.s) {
                    Text(agent.name).font(theme.font(theme.type.body, theme.strong)).foregroundStyle(c.ink)
                    if agent.isDefault {
                        Text("Default")
                            .font(theme.font(11, .bold)).foregroundStyle(c.inkSoft)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(c.background, in: Capsule())
                    }
                    if agent.muted {
                        Image(systemName: "bell.slash.fill")
                            .font(theme.font(11, .bold)).foregroundStyle(c.inkSoft)
                            .accessibilityLabel("Notifications off")
                    }
                }
                StatusLine(agent: agent)
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(theme.font(theme.type.title, .bold))
                    .foregroundStyle(c.accent)
                    .accessibilityLabel("Talking to \(agent.name)")
            }
            Button("Edit \(agent.name)", systemImage: "ellipsis.circle", action: edit)
                .labelStyle(.iconOnly)
                .font(theme.font(theme.type.title))
                .foregroundStyle(c.inkSoft)
                .buttonStyle(.borderless)
        }
        .padding(.vertical, theme.spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .listRowBackground(
            HStack(spacing: 0) {
                Rectangle().fill(c.accent).frame(width: 5)
                c.background
            }
        )
    }
}

/// Online dot + words: "Online", "Offline, seen 5 min ago", "Waiting to connect".
struct StatusLine: View {
    let agent: YuiAgent
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        HStack(spacing: 6) {
            Circle().fill(dot(c)).frame(width: 8, height: 8)
            Text(text).font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
        }
    }

    private func dot(_ c: Swatch) -> Color {
        switch agent.status {
        case .connected: .green
        case .offline: c.inkSoft.opacity(0.5)
        case .pending: c.butter
        }
    }

    private var text: String {
        switch agent.status {
        case .connected: return "Online"
        case .pending: return "Waiting to connect"
        case .offline:
            guard let seen = agent.lastSeenAt else { return "Offline" }
            return "Offline, seen \(seen.formatted(.relative(presentation: .named)))"
        }
    }
}

private struct EmptyAgents: View {
    let add: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        VStack(spacing: theme.spacing.l) {
            Spacer(minLength: 0)
            Image(systemName: "sparkles")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(c.accent)
            Text("Add your first agent")
                .font(theme.font(theme.type.display, theme.strong)).foregroundStyle(c.ink)
            Text("Yui shows the answers of an agent you run on your own computer, like a Hermes profile. Connecting one takes about five minutes.")
                .font(theme.font(theme.type.body)).foregroundStyle(c.inkSoft)
                .multilineTextAlignment(.center)
            PillButton(title: "Add agent", systemImage: "plus", action: add)
            GuideLink()
            Spacer(minLength: 0)
        }
        .padding(theme.spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The coral full-width action button used across the agent sheets.
struct PillButton: View {
    let title: String
    var systemImage: String?
    var working = false
    let action: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        Button(action: action) {
            Group {
                if working {
                    ProgressView().tint(c.onAccent)
                } else if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            .font(theme.font(theme.type.body, .bold)).foregroundStyle(c.onAccent)
            .frame(maxWidth: .infinity).padding(.vertical, theme.spacing.m)
            .background(c.accent, in: .rect(cornerRadius: theme.radius.pill))
        }
        .buttonStyle(BounceButtonStyle())
        .disabled(working)
    }
}

/// The looks a person can pick for an agent: its own (seeded from its name) first,
/// then every named set. Each chip is drawn in the look it stands for.
struct LookPickerRow: View {
    let name: String
    var isYui = false
    @Binding var look: String?
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: theme.spacing.m) {
                chip(nil, label: "Own")
                ForEach(AgentLook.sets.map(\.name), id: \.self) { chip($0, label: $0.capitalized) }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
    }

    private func chip(_ preset: String?, label: String) -> some View {
        let c = theme.swatch(scheme)
        let s = AgentLook.theme(AgentLook(preset: preset), name: name.isEmpty ? "agent" : name, isYui: isYui).swatch(scheme)
        let on = look == preset
        return Button { withAnimation(theme.spring) { look = preset } } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle().fill(s.background)
                    Circle().fill(s.accent).padding(10)
                }
                .frame(width: 44, height: 44)
                .overlay(Circle().stroke(on ? c.ink : c.outline, lineWidth: on ? 3 : 1))
                Text(label).font(theme.font(11, .bold)).foregroundStyle(on ? c.ink : c.inkSoft)
            }
        }
        .buttonStyle(BounceButtonStyle())
        .accessibilityLabel("\(label) look")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Add agent: name it, pick a look, get a code, run three commands on the host.
/// Opens from the agents list, and straight from the chat on a new account.
struct AddAgentSheet: View {
    /// Paired, and the person tapped "Say hi": the new agent's id.
    var done: (String) -> Void = { _ in }
    @Environment(AgentStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var name = ProcessInfo.processInfo.arguments.contains("-yuiAddAgent") ? "Nova" : ""
    @State private var look: String?
    @State private var pending: (agent: YuiAgent, code: PairingCode)?
    @State private var working = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        let c = theme.swatch(scheme)
        NavigationStack {
            ScrollView {
                if let pending {
                    PairingStep(agentID: pending.agent.id, code: pending.code, newCode: {
                        self.pending = (pending.agent, try await store.newCode(for: pending.agent))
                    }, sayHi: { done(pending.agent.id) })
                } else {
                    nameStep(c)
                }
            }
            .background(c.background)
            .navigationTitle("Add agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(pending == nil ? "Cancel" : "Done") { dismiss() }.tint(c.accent)
                }
            }
        }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-yuiAddAgentCode") { await create() }
            #endif
        }
    }

    private func nameStep(_ c: Swatch) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.l) {
            HStack {
                Spacer()
                AgentAvatar(name: name.isEmpty ? "?" : name, size: 72)
                    .environment(\.yuiTheme, AgentLook.theme(AgentLook(preset: look), name: name.isEmpty ? "agent" : name))
                Spacer()
            }
            Text("What should we call them?")
                .font(theme.font(theme.type.title, .bold)).foregroundStyle(c.ink)
            TextField("Name, like Nova", text: $name)
                .font(theme.font(theme.type.body, .semibold))
                .focused($focused)
                .submitLabel(.next)
                .onSubmit { Task { await create() } }
                .padding(theme.spacing.m)
                .background(c.surface, in: .rect(cornerRadius: theme.radius.bubble))
                .overlay(RoundedRectangle(cornerRadius: theme.radius.bubble).stroke(c.outline, lineWidth: 1.5))
            Text("Look").font(theme.font(theme.type.caption, .bold)).foregroundStyle(c.inkSoft)
            LookPickerRow(name: name, look: $look)
            if let error {
                Text(error).font(theme.font(theme.type.caption, .semibold)).foregroundStyle(.red)
            }
            PillButton(title: "Get a pairing code", working: working) { Task { await create() } }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            Text("Next you'll get a code and three short commands to run on the computer your agent lives on.")
                .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
        }
        .padding(theme.spacing.xl)
    }

    private func create() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !working else { return }
        working = true
        defer { working = false }
        do {
            let (agent, code) = try await store.add(name: trimmed, color: "mint")
            if look != nil { await store.setLook(agent, preset: look) }
            withAnimation(theme.spring) { pending = (agent, code) }
        } catch {
            self.error = "Couldn't make a code just now. Check your connection and tap again."
        }
    }
}

/// The code, the three commands from yuigui.com/start, and a live "connected"
/// once the host claims it. Stuck or expired: says how to fix it.
private struct PairingStep: View {
    let agentID: String
    let code: PairingCode
    let newCode: () async throws -> Void
    /// Paired: "Say hi" opens the thread. Nil (a re-pair from settings) shows no button.
    var sayHi: (() -> Void)? = nil
    @Environment(AgentStore.self) private var store
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var since = Date.now

    private var agent: YuiAgent? { store.agents.first { $0.id == agentID } }
    private var connected: Bool { agent.map { $0.status != .pending } ?? false }
    /// Waiting this long means a step was missed: show the fix.
    static let stuckAfter: TimeInterval = ProcessInfo.processInfo.arguments.contains("-yuiPairStuck") ? 0 : 150

    static let install = "hermes plugins install postscarcityai/yui/hermes-plugin/yui --enable"
    static let restart = "hermes gateway restart"

    var body: some View {
        let c = theme.swatch(scheme)
        VStack(alignment: .leading, spacing: theme.spacing.l) {
            HStack(spacing: theme.spacing.m) {
                if let agent { AgentBadge(agent: agent, size: 52) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent?.name ?? "").font(theme.font(theme.type.title, .bold)).foregroundStyle(c.ink)
                    if let agent { StatusLine(agent: agent) }
                }
            }
            if connected, let agent {
                VStack(spacing: theme.spacing.m) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56, weight: .bold)).foregroundStyle(.green)
                    Text("\(agent.name) is connected!")
                        .font(theme.font(theme.type.display, theme.strong)).foregroundStyle(c.ink)
                        .multilineTextAlignment(.center)
                    Text(agent.connectorName.map { "Running on \($0). Say hi and it answers here." }
                         ?? "Say hi and it answers here.")
                        .font(theme.font(theme.type.body)).foregroundStyle(c.inkSoft)
                        .multilineTextAlignment(.center)
                    if let sayHi {
                        PillButton(title: "Say hi to \(agent.name)", systemImage: "hand.wave.fill", action: sayHi)
                            .padding(.top, theme.spacing.s)
                    }
                }
                .frame(maxWidth: .infinity)
                .transition(.scale.combined(with: .opacity))
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = max(0, Int(code.expiresAt.timeIntervalSince(ctx.date)))
                    VStack(alignment: .leading, spacing: theme.spacing.l) {
                        Text("On the computer \(agent?.name ?? "your agent") runs on, open a terminal and run these three commands.")
                            .font(theme.font(theme.type.body, .semibold)).foregroundStyle(c.ink)
                        step(1, "Install the Yui plugin", Self.install, note: "Already installed? Skip to step 2.", c)
                        step(2, "Pair with this code", "hermes yui pair \(code.code)", note: nil, c)
                        codeCard(left, c)
                        step(3, "Restart the gateway", Self.restart,
                             note: "No gateway service yet? Run hermes gateway install first.", c)
                        Text("Using a named profile? Put -p <profile> right after hermes in each command.")
                            .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                        if left == 0 {
                            fix("That code ran out.", "Tap Get a new code above, then run step 2 again with the new code.", c)
                        } else if ctx.date.timeIntervalSince(since) >= Self.stuckAfter {
                            fix("Still waiting?",
                                "Run hermes yui status on that computer. Not paired: run step 2 again. Paired: run step 3, the gateway only connects after a restart.", c)
                        }
                        HStack(spacing: theme.spacing.s) {
                            ProgressView()
                            Text("Waiting for your computer…").font(theme.font(theme.type.caption, .semibold)).foregroundStyle(c.inkSoft)
                        }
                        .accessibilityElement(children: .combine)
                        GuideLink()
                    }
                }
            }
        }
        .padding(theme.spacing.xl)
        .animation(theme.spring, value: connected)
        .onChange(of: code) { since = .now }
        .task {
            while !Task.isCancelled && !connected {
                try? await Task.sleep(for: .seconds(2))
                await store.refresh()
            }
        }
    }

    private func codeCard(_ left: Int, _ c: Swatch) -> some View {
        VStack(spacing: theme.spacing.s) {
            Text(spaced(code.code))
                .font(.system(size: 44, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(left > 0 ? c.ink : c.inkSoft.opacity(0.5))
                .strikethrough(left == 0)
                .accessibilityLabel("Pairing code \(code.code.map(String.init).joined(separator: " "))")
            if left > 0 {
                Text("Works once. Expires in \(left / 60):\(String(format: "%02d", left % 60))")
                    .font(theme.font(theme.type.caption, .semibold)).foregroundStyle(c.inkSoft)
            } else {
                Button("Get a new code") { Task { try? await newCode() } }
                    .font(theme.font(theme.type.body, .bold)).tint(c.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(theme.spacing.l)
        .background(c.surface, in: .rect(cornerRadius: theme.radius.card))
        .overlay(RoundedRectangle(cornerRadius: theme.radius.card).stroke(c.outline, lineWidth: 1.5))
    }

    /// One numbered step: what it does, the exact command with a copy button.
    private func step(_ n: Int, _ title: String, _ command: String, note: String?, _ c: Swatch) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.s) {
            HStack(spacing: theme.spacing.s) {
                Text("\(n)")
                    .font(theme.font(theme.type.caption, .black)).foregroundStyle(c.onAccent)
                    .frame(width: 22, height: 22)
                    .background(c.accent, in: Circle())
                Text(title).font(theme.font(theme.type.body, .bold)).foregroundStyle(c.ink)
            }
            HStack(alignment: .top) {
                Text(command)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(c.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Copy step \(n)", systemImage: "doc.on.doc") { UIPasteboard.general.string = command }
                    .labelStyle(.iconOnly).tint(c.inkSoft)
            }
            .padding(theme.spacing.m)
            .background(c.surface, in: .rect(cornerRadius: theme.radius.bubble))
            .overlay(RoundedRectangle(cornerRadius: theme.radius.bubble).stroke(c.outline, lineWidth: 1))
            if let note {
                Text(note).font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
            }
        }
    }

    private func fix(_ title: String, _ body: String, _ c: Swatch) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "wrench.and.screwdriver.fill")
                .font(theme.font(theme.type.body, .bold)).foregroundStyle(c.ink)
            Text(body).font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(theme.spacing.m)
        .background(c.butter.opacity(0.35), in: .rect(cornerRadius: theme.radius.bubble))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pair-fix")
    }

    private func spaced(_ s: String) -> String {
        s.count == 6 ? "\(s.prefix(3)) \(s.suffix(3))" : s
    }
}

/// "Step-by-step guide": yuigui.com/start, same steps with more help.
struct GuideLink: View {
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Link(destination: YuiBackend.startGuide) {
            Label("Step-by-step guide at yuigui.com/start", systemImage: "book.fill")
        }
        .font(theme.font(theme.type.caption, .bold))
        .tint(theme.swatch(scheme).inkSoft)
    }
}

/// Rename, pick a look (the sheet previews it live), notifications, make default, new pairing code, remove.
private struct EditAgentSheet: View {
    let agent: YuiAgent
    @Environment(AgentStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var name = ""
    @State private var look: String?
    @State private var notify = true
    @State private var confirmRemove = false
    @State private var code: PairingCode?

    /// The agent as it will look once saved.
    private var preview: YuiAgent {
        var a = agent
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { a.name = name }
        if look != agent.theme?.preset { a.theme = AgentLook(preset: look, style: agent.theme?.style) }
        return a
    }

    /// The sheet wears the look being picked, so the choice previews itself.
    private var theme: YuiTheme { preview.yuiTheme }

    var body: some View {
        let c = theme.swatch(scheme)
        NavigationStack {
            ScrollView {
                if let code {
                    PairingStep(agentID: agent.id, code: code) { self.code = try await store.newCode(for: agent) }
                } else {
                    form(c)
                }
            }
            .background(c.background)
            .navigationTitle(agent.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.tint(c.inkSoft) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task {
                            if n != agent.name, !n.isEmpty { await store.update(agent, name: n) }
                            if look != agent.theme?.preset { await store.setLook(agent, preset: look) }
                            if notify == agent.muted { await store.update(agent, pushMuted: !notify) }
                            dismiss()
                        }
                    }
                    .tint(c.accent)
                }
            }
            .confirmationDialog("Remove \(agent.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove \(agent.name)", role: .destructive) {
                    Task { await store.remove(agent); dismiss() }
                }
            } message: {
                Text("This deletes your whole conversation with \(agent.name). The agent itself keeps running on your computer.")
            }
        }
        .environment(\.yuiTheme, theme)
        .animation(theme.spring, value: theme)
        .onAppear { name = agent.name; look = agent.theme?.preset; notify = !agent.muted }
    }

    /// "full screen, stacked buttons": the agent's style profile in words.
    static func prefs(_ style: [String: String]?) -> String? {
        guard let style, !style.isEmpty else { return nil }
        let words: [String] = ["screen", "buttons", "gallery", "chart"].compactMap { k in
            guard let v = style[k] else { return nil }
            return switch k {
            case "screen": v == "full" ? "full screen" : "chat screens"
            case "buttons": v == "stack" ? "stacked buttons" : "buttons in a row"
            case "gallery": "\(v) galleries"
            default: "\(v) charts"
            }
        }
        return words.isEmpty ? nil : words.joined(separator: ", ")
    }

    private func form(_ c: Swatch) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.l) {
            HStack {
                Spacer()
                VStack(spacing: theme.spacing.s) {
                    AgentBadge(agent: preview, size: 72)
                    StatusLine(agent: agent)
                }
                Spacer()
            }
            Text("Name").font(theme.font(theme.type.caption, .bold)).foregroundStyle(c.inkSoft)
            TextField("Name", text: $name)
                .font(theme.font(theme.type.body, .semibold))
                .padding(theme.spacing.m)
                .background(c.surface, in: .rect(cornerRadius: theme.radius.bubble))
                .overlay(RoundedRectangle(cornerRadius: theme.radius.bubble).stroke(c.outline, lineWidth: 1.5))
            Text("Look").font(theme.font(theme.type.caption, .bold)).foregroundStyle(c.inkSoft)
            LookPickerRow(name: agent.handle, isYui: agent.isYui, look: $look)
            if let prefs = Self.prefs(agent.theme?.style) {
                Text("Prefers \(prefs). \(agent.name) can change its look itself: ask it.")
                    .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
            } else {
                Text("\(agent.name) can change its look itself: ask it.")
                    .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
            }
            if let host = agent.connectorName, let ref = agent.remoteRef {
                Text("Runs on \(host) as the \(ref) profile.")
                    .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
            }
            Toggle(isOn: $notify) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notifications").font(theme.font(theme.type.body, .bold)).foregroundStyle(c.ink)
                    Text(notify ? "Your phone buzzes when \(agent.name) answers and Yui is closed."
                                : "\(agent.name) stays quiet. Its answers wait in the thread.")
                        .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                }
            }
            .tint(c.accent)
            .padding(theme.spacing.l)
            .background(c.surface, in: .rect(cornerRadius: theme.radius.card))
            .overlay(RoundedRectangle(cornerRadius: theme.radius.card).stroke(c.outline, lineWidth: 1.5))
            .accessibilityIdentifier("agent-notifications")
            VStack(spacing: 0) {
                if !agent.isDefault {
                    row("Make default", "star.fill", c.ink) {
                        Task { await store.update(agent, makeDefault: true); dismiss() }
                    }
                    Divider()
                }
                if agent.status == .pending {
                    row("Get a pairing code", "number", c.ink) {
                        Task { code = try? await store.newCode(for: agent) }
                    }
                    Divider()
                }
                row("Remove \(agent.name)", "trash.fill", .red) { confirmRemove = true }
            }
            .background(c.surface, in: .rect(cornerRadius: theme.radius.card))
            .overlay(RoundedRectangle(cornerRadius: theme.radius.card).stroke(c.outline, lineWidth: 1.5))
        }
        .padding(theme.spacing.xl)
    }

    private func row(_ title: String, _ icon: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(theme.font(theme.type.body, .bold)).foregroundStyle(tint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(theme.spacing.l)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
