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
            AddAgentSheet()
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
            Text("Connect an agent that runs on your computer, like a Hermes profile. It takes a minute.")
                .font(theme.font(theme.type.body)).foregroundStyle(c.inkSoft)
                .multilineTextAlignment(.center)
            PillButton(title: "Add agent", systemImage: "plus", action: add)
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

/// Add agent: name it, pick a look, get a code, run one command on the host.
private struct AddAgentSheet: View {
    @Environment(AgentStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var name = ProcessInfo.processInfo.arguments.contains("-yuiAddAgent") ? "Monk" : ""
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
                    PairingStep(agentID: pending.agent.id, code: pending.code) {
                        self.pending = (pending.agent, try await store.newCode(for: pending.agent))
                    }
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
            TextField("Name, like Monk", text: $name)
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
            Text("You'll get a code to type on the computer your agent runs on.")
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
            self.error = error.localizedDescription
        }
    }
}

/// The code, the one command, and a live "connected" once the host claims it.
private struct PairingStep: View {
    let agentID: String
    let code: PairingCode
    let newCode: () async throws -> Void
    @Environment(AgentStore.self) private var store
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private var agent: YuiAgent? { store.agents.first { $0.id == agentID } }
    private var connected: Bool { agent.map { $0.status != .pending } ?? false }
    private var command: String { "hermes -p <profile> yui pair \(code.code)" }

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
                    if let host = agent.connectorName {
                        Text("Running on \(host).").font(theme.font(theme.type.body)).foregroundStyle(c.inkSoft)
                    }
                }
                .frame(maxWidth: .infinity)
                .transition(.scale.combined(with: .opacity))
            } else {
                Text("On the computer your agent runs on, type this:")
                    .font(theme.font(theme.type.body, .semibold)).foregroundStyle(c.ink)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = max(0, Int(code.expiresAt.timeIntervalSince(ctx.date)))
                    VStack(spacing: theme.spacing.s) {
                        Text(spaced(code.code))
                            .font(.system(size: 48, weight: .heavy, design: .rounded).monospacedDigit())
                            .foregroundStyle(left > 0 ? c.ink : c.inkSoft.opacity(0.5))
                            .strikethrough(left == 0)
                            .accessibilityLabel("Pairing code \(code.code.map(String.init).joined(separator: " "))")
                        if left > 0 {
                            Text("Expires in \(left / 60):\(String(format: "%02d", left % 60))")
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
                HStack {
                    Text(command)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(c.ink)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = command }
                        .labelStyle(.iconOnly).tint(c.inkSoft)
                }
                .padding(theme.spacing.m)
                .background(c.surface, in: .rect(cornerRadius: theme.radius.bubble))
                Text("Replace <profile> with the agent's Hermes profile name. Already connected this computer before? Skip the code and run `hermes -p <profile> yui add` there instead.")
                    .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                HStack(spacing: theme.spacing.s) {
                    ProgressView()
                    Text("Waiting for your computer…").font(theme.font(theme.type.caption, .semibold)).foregroundStyle(c.inkSoft)
                }
            }
        }
        .padding(theme.spacing.xl)
        .animation(theme.spring, value: connected)
        .task {
            while !Task.isCancelled && !connected {
                try? await Task.sleep(for: .seconds(2))
                await store.refresh()
            }
        }
    }

    private func spaced(_ s: String) -> String {
        s.count == 6 ? "\(s.prefix(3)) \(s.suffix(3))" : s
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
