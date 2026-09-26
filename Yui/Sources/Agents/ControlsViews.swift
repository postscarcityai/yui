import SwiftUI
import YuiLines

// The drawer's Controls screens (YUI-70, spec yuigui spec/CONTROLS.md section 1).
// One screen per area. Text shows rendered with an Edit toggle; every delete asks
// first; a save the host refuses as changed shows both versions to pick from.

/// One area, opened from the drawer: its own navigation, so an item can push.
struct ControlsSheet: View {
    let model: ControlsModel
    let section: ControlSection
    let agentID: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            Group {
                switch section {
                case .soul: SoulScreen(model: model, agentID: agentID)
                case .memory: MemoryScreen(model: model, agentID: agentID)
                case .skills: SkillsScreen(model: model, agentID: agentID)
                case .schedules: SchedulesScreen(model: model, agentID: agentID)
                case .model: ModelScreen(model: model)
                case .channels: ChannelsScreen(model: model)
                }
            }
            .navigationTitle(section.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("controls-close")
                }
            }
            .background(theme.swatch(scheme).background)
        }
        .tint(theme.swatch(scheme).accent)
        .overlay(alignment: .topLeading) {
            // For UI tests: the sheet is up, whichever screen is pushed.
            Text(" ").font(.system(size: 1)).opacity(0.01).accessibilityIdentifier("controls-sheet").allowsHitTesting(false)
        }
    }
}

// MARK: Loading, errors, shared pieces

/// Loads with the host, shows the error in words with Try again.
private struct Loader<Value, Content: View>: View {
    let load: () async throws -> Value
    @ViewBuilder let content: (Value, _ reload: @escaping () -> Void) -> Content
    @State private var value: Value?
    @State private var error: ControlsError?
    @State private var tick = 0
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if let value {
                content(value) { tick += 1 }
            } else if let error {
                ControlsProblem(error: error) { self.error = nil; tick += 1 }
            } else {
                VStack(spacing: theme.spacing.m) {
                    ProgressView()
                    Text("Asking your Mac").font(theme.font(theme.type.caption)).foregroundStyle(theme.swatch(scheme).inkSoft)
                }
                .frame(maxWidth: .infinity, minHeight: 240)
            }
        }
        .task(id: tick) {
            do {
                value = try await load()
                error = nil
            } catch let e as ControlsError {
                error = e
            } catch {
                self.error = .noAnswer
            }
        }
    }
}

/// "Your Mac didn't answer", "Update the Yui plugin", or the host's own words, with Try again.
struct ControlsProblem: View {
    let error: ControlsError
    let retry: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        VStack(spacing: theme.spacing.m) {
            Image(systemName: error == .version ? "arrow.down.app" : "desktopcomputer.trianglebadge.exclamationmark")
                .font(.system(size: 40, weight: .semibold)).foregroundStyle(c.accent)
            Text(error.message).font(theme.font(theme.type.title, theme.strong)).foregroundStyle(c.ink)
                .multilineTextAlignment(.center)
            if error == .noAnswer {
                Text("It may be asleep or its gateway may be off. Your change was not made.")
                    .font(theme.font(15)).foregroundStyle(c.inkSoft).multilineTextAlignment(.center)
            }
            if error != .version {
                Button("Try again", action: retry)
                    .buttonStyle(ControlsPill(filled: true))
                    .accessibilityIdentifier("controls-retry")
            }
        }
        .padding(theme.spacing.xl)
        .frame(maxWidth: .infinity, minHeight: 320)
        .accessibilityIdentifier("controls-problem")
    }
}

struct ControlsPill: ButtonStyle {
    var filled = false
    var danger = false
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let c = theme.swatch(scheme)
        let tint = danger ? Color.red : c.accent
        configuration.label
            .font(theme.font(15, .bold))
            .padding(.horizontal, theme.spacing.l).padding(.vertical, 11)
            .frame(minHeight: 44)
            .foregroundStyle(filled ? c.onAccent : tint)
            .background(filled ? AnyShapeStyle(tint) : AnyShapeStyle(c.surface), in: Capsule())
            .overlay(Capsule().stroke(filled ? .clear : tint.opacity(0.5), lineWidth: 1.5))
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? theme.motion.bounceScale : 1)
            .animation(theme.spring, value: configuration.isPressed)
    }
}

/// A card with a rounded outline, the drawer's look.
private struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        VStack(alignment: .leading, spacing: theme.spacing.s) { content }
            .padding(theme.spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(c.surface, in: .rect(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(c.outline, lineWidth: 1))
    }
}

/// Markdown as the chat draws it, never raw marks.
private struct Rendered: View {
    let text: String
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(BubbleMarkdown.attributed(Self.withoutFrontmatter(text)))
            .font(theme.font(16))
            .foregroundStyle(theme.swatch(scheme).ink)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A SKILL.md's frontmatter is shown as the card above it, not as dashes.
    static func withoutFrontmatter(_ s: String) -> String {
        guard s.hasPrefix("---"), let end = s.range(of: "\n---", range: s.index(s.startIndex, offsetBy: 3)..<s.endIndex) else { return s }
        return String(s[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A line that says part of the item is hidden on the Mac, so it's read only here.
private struct HiddenNote: View {
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        Label("A line with a key in it is hidden on your Mac, so this can only be changed there.", systemImage: "lock.fill")
            .font(theme.font(theme.type.caption, .semibold))
            .foregroundStyle(c.inkSoft)
            .padding(theme.spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(c.butter.opacity(0.35), in: .rect(cornerRadius: 14))
            .accessibilityIdentifier("controls-hidden-note")
    }
}

private struct Chip: View {
    let text: String
    var tint: Color? = nil
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        Text(text)
            .font(theme.font(12, .heavy))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background((tint ?? c.lavender).opacity(0.55), in: Capsule())
            .foregroundStyle(c.ink)
    }
}

private struct Fact: View {
    let label: String
    let value: String
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(theme.font(15)).foregroundStyle(c.inkSoft)
            Spacer(minLength: theme.spacing.m)
            Text(value).font(theme.font(15, .bold)).foregroundStyle(c.ink).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct Toast: ViewModifier {
    @Binding var text: String?
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let text {
                Text(text)
                    .font(theme.font(15, .bold))
                    .foregroundStyle(theme.swatch(scheme).onAccent)
                    .padding(.horizontal, theme.spacing.l).padding(.vertical, 12)
                    .background(theme.swatch(scheme).ink.opacity(0.9), in: Capsule())
                    .padding(.bottom, theme.spacing.xl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityIdentifier("controls-toast")
                    .task(id: text) {
                        try? await Task.sleep(for: .seconds(2.5))
                        withAnimation { self.text = nil }
                    }
            }
        }
        .animation(theme.spring, value: text)
    }
}

extension View {
    fileprivate func toast(_ text: Binding<String?>) -> some View { modifier(Toast(text: text)) }
}

/// "in 3 h", "in 12 min", "tomorrow 8:00" from the host's ISO time.
enum ControlsTime {
    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s) ?? YuiTime.date(s)
    }
    static func next(_ s: String?, now: Date = .now) -> String? {
        guard let d = parse(s) else { return nil }
        let mins = Int(d.timeIntervalSince(now) / 60)
        if mins < 1 { return "in a moment" }
        if mins < 60 { return "in \(mins) min" }
        if mins < 24 * 60 { return "in \(mins / 60) h" }
        return d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
    static func ago(_ s: String?, now: Date = .now) -> String? {
        guard let d = parse(s) else { return nil }
        return d.formatted(.relative(presentation: .named))
    }
}

// MARK: Editor + conflict

/// Full-screen markdown editor. Keeps a draft on the phone while it's open.
private struct Editor: View {
    let title: String
    let draftKey: String
    let original: String
    let save: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var text = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        let c = theme.swatch(scheme)
        NavigationStack {
            VStack(spacing: 0) {
                if let error {
                    Text(error).font(theme.font(theme.type.caption, .semibold)).foregroundStyle(.red)
                        .padding(theme.spacing.m).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("controls-editor-error")
                }
                TextEditor(text: $text)
                    .font(.system(size: 15, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, theme.spacing.m)
                    .focused($focused)
                    .accessibilityIdentifier("controls-editor")
                    .onChange(of: text) { _, t in ControlsModel.saveDraft(t == original ? nil : t, key: draftKey) }
            }
            .background(c.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        ControlsModel.saveDraft(nil, key: draftKey)
                        dismiss()
                    }
                    .accessibilityIdentifier("controls-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving" : "Save") {
                        Task {
                            saving = true
                            defer { saving = false }
                            do {
                                try await save(text)
                                ControlsModel.saveDraft(nil, key: draftKey)
                                dismiss()
                            } catch let e as ControlsError {
                                if case .conflict = e { dismiss() } else { error = e.message }
                            } catch {
                                self.error = ControlsError.noAnswer.message
                            }
                        }
                    }
                    .bold()
                    .disabled(saving || text == original)
                    .accessibilityIdentifier("controls-save")
                }
            }
        }
        .onAppear {
            text = ControlsModel.draft(draftKey) ?? original
            focused = true
        }
    }
}

/// The host changed it since it was opened: both versions, pick one.
private struct ConflictScreen: View {
    let mine: String
    let theirs: String
    let keepMine: () -> Void
    let useTheirs: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        ScrollView {
            VStack(alignment: .leading, spacing: theme.spacing.m) {
                Text("Changed on your Mac").font(theme.font(theme.type.display, theme.strong)).foregroundStyle(c.ink)
                Text("Someone saved a different version on your Mac after you opened this. Pick the one to keep.")
                    .font(theme.font(15)).foregroundStyle(c.inkSoft)
                Text("YOUR VERSION").font(theme.font(theme.type.caption, .heavy)).kerning(0.8).foregroundStyle(c.inkSoft)
                Card { Rendered(text: mine) }
                Text("ON YOUR MAC").font(theme.font(theme.type.caption, .heavy)).kerning(0.8).foregroundStyle(c.inkSoft)
                Card { Rendered(text: theirs) }
                HStack {
                    Button("Use the Mac's", action: useTheirs).buttonStyle(ControlsPill())
                        .accessibilityIdentifier("controls-use-theirs")
                    Spacer()
                    Button("Keep mine", action: keepMine).buttonStyle(ControlsPill(filled: true))
                        .accessibilityIdentifier("controls-keep-mine")
                }
            }
            .padding(theme.spacing.l)
        }
        .background(c.background)
        .accessibilityIdentifier("controls-conflict")
    }
}

/// A text item (SOUL.md, a memory, a SKILL.md, a schedule's prompt): rendered, Edit,
/// and the conflict screen when a save lands on a newer version.
private struct TextItem<Extra: View>: View {
    let model: ControlsModel
    let section: ControlSection
    let agentID: String
    let id: String
    var editTitle: String
    var editable = true
    @Binding var toast: String?
    var saved: (ControlItem) -> Void = { _ in }
    @ViewBuilder let extra: (ControlItem, _ rev: String, _ reload: @escaping () -> Void) -> Extra
    @State private var editing = false
    @State private var conflict: (mine: String, rev: String, theirs: String)?
    @State private var tick = 0
    @State private var current: (rev: String, item: ControlItem)?
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Loader(load: { try await model.get(section, current?.item.id ?? id) }) { got, reload in
            let (rev, item) = got
            ScrollView {
                VStack(alignment: .leading, spacing: theme.spacing.m) {
                    if item.locked { HiddenNote() }
                    extra(item, rev, reload)
                    Card { Rendered(text: item.text ?? "") }
                        .accessibilityIdentifier("controls-rendered")
                    TalkAboutButton(item: TalkItem(section: section, itemID: item.id, rev: rev,
                                                   title: TalkItem.title(section, item), text: item.text))
                }
                .padding(theme.spacing.l)
            }
            .toolbar {
                if editable {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Edit") { editing = true }
                            .bold()
                            .disabled(item.locked)
                            .accessibilityIdentifier("controls-edit")
                    }
                }
            }
            .onAppear { current = got }
            .fullScreenCover(isPresented: $editing) {
                Editor(title: editTitle, draftKey: ControlsModel.draftKey(agentID, section, id), original: item.text ?? "") { text in
                    do {
                        let r = try await model.put(section, item.id, rev: rev, value: ["text": .string(text)])
                        current = r
                        saved(r.item)
                        toast = "Saved on your Mac"
                        reload()
                    } catch ControlsError.conflict(let newRev, let theirs) {
                        conflict = (text, newRev, theirs?.text ?? "")
                        throw ControlsError.conflict(newRev, theirs)
                    }
                }
                .environment(\.yuiTheme, theme)
            }
            .sheet(isPresented: Binding(get: { conflict != nil }, set: { if !$0 { conflict = nil } })) {
                if let cf = conflict {
                    ConflictScreen(mine: cf.mine, theirs: cf.theirs, keepMine: {
                        Task {
                            do {
                                let r = try await model.put(section, item.id, rev: cf.rev, value: ["text": .string(cf.mine)])
                                current = r
                                saved(r.item)
                                ControlsModel.saveDraft(nil, key: ControlsModel.draftKey(agentID, section, id))
                                toast = "Saved on your Mac"
                            } catch let e as ControlsError {
                                toast = e.message
                            }
                            conflict = nil
                            reload()
                        }
                    }, useTheirs: {
                        ControlsModel.saveDraft(nil, key: ControlsModel.draftKey(agentID, section, id))
                        conflict = nil
                        reload()
                    })
                    .environment(\.yuiTheme, theme)
                    .presentationDetents([.large])
                }
            }
        }
    }
}

// MARK: Personality

private struct SoulScreen: View {
    let model: ControlsModel
    let agentID: String
    @State private var toast: String?
    @Environment(\.yuiTheme) private var theme

    var body: some View {
        TextItem(model: model, section: .soul, agentID: agentID, id: "SOUL.md", editTitle: "SOUL.md",
                 editable: model.report.can(.soul, "w"), toast: $toast) { item, _, _ in
            if let outline = item.outline, !outline.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) { ForEach(Array(outline.enumerated()), id: \.offset) { Chip(text: $0.element) } }
                }
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("controls-outline")
            }
        }
        .toast($toast)
    }
}

// MARK: Memory

private struct MemoryScreen: View {
    let model: ControlsModel
    let agentID: String
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        Loader(load: { try await model.list(.memory) }) { items, reload in
            List {
                ForEach([("remembers", "What it remembers"), ("you", "About you")], id: \.0) { group, heading in
                    let rows = items.filter { $0.group == group }
                    Section {
                        if rows.isEmpty {
                            Text(group == "you" ? "Nothing about you yet." : "Nothing yet.")
                                .font(theme.font(15)).foregroundStyle(c.inkSoft)
                        }
                        ForEach(rows) { m in
                            NavigationLink {
                                MemoryItem(model: model, agentID: agentID, id: m.id, done: reload)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: theme.spacing.s) {
                                    Text(m.title ?? "").font(theme.font(16)).foregroundStyle(c.ink).lineLimit(2)
                                    if m.locked {
                                        Spacer(minLength: 0)
                                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(c.inkSoft)
                                            .accessibilityLabel("Hidden on your Mac")
                                    }
                                }
                            }
                            .accessibilityIdentifier("memory-row")
                        }
                    } header: {
                        Text(heading).font(theme.font(theme.type.caption, .heavy))
                    }
                }
                Section {
                    Text("To add a memory, ask \(model.agentName) to remember it.")
                        .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                }
            }
            .scrollContentBackground(.hidden)
            .refreshable { reload() }
        }
    }
}

private struct MemoryItem: View {
    let model: ControlsModel
    let agentID: String
    let id: String
    let done: () -> Void
    @State private var asking = false
    @State private var toast: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TextItem(model: model, section: .memory, agentID: agentID, id: id, editTitle: "Memory",
                 editable: model.report.can(.memory, "w"), toast: $toast, saved: { _ in done() }) { item, rev, _ in
            if model.report.can(.memory, "d") {
                Button("Forget", systemImage: "trash", role: .destructive) { asking = true }
                    .buttonStyle(ControlsPill(danger: true))
                    .accessibilityIdentifier("controls-forget")
                    .alert("Forget this? \(model.agentName) will not remember it next time.", isPresented: $asking) {
                        Button("Forget", role: .destructive) {
                            Task {
                                do {
                                    try await model.delete(.memory, item.id, rev: rev)
                                    done()
                                    dismiss()
                                } catch let e as ControlsError { toast = e.message }
                            }
                        }
                        Button("Keep it", role: .cancel) {}
                    }
            }
        }
        .navigationTitle("Memory")
        .toast($toast)
    }
}

// MARK: Skills

private struct SkillsScreen: View {
    let model: ControlsModel
    let agentID: String
    @State private var toast: String?
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        Loader(load: { try await model.list(.skills) }) { items, reload in
            List {
                Section {
                    ForEach(items) { s in
                        SkillRow(model: model, skill: s, toast: $toast) {
                            SkillItem(model: model, agentID: agentID, id: s.id, done: reload)
                        }
                    }
                } footer: {
                    Text("Off keeps the skill on your Mac but \(model.agentName) won't use it.")
                        .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                }
            }
            .scrollContentBackground(.hidden)
            .refreshable { reload() }
        }
        .toast($toast)
    }
}

private struct SkillRow<Detail: View>: View {
    let model: ControlsModel
    let skill: ControlItem
    @Binding var toast: String?
    @ViewBuilder let detail: () -> Detail
    @State private var on: Bool
    @State private var busy = false
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    init(model: ControlsModel, skill: ControlItem, toast: Binding<String?>, @ViewBuilder detail: @escaping () -> Detail) {
        self.model = model
        self.skill = skill
        _toast = toast
        self.detail = detail
        _on = State(initialValue: skill.enabled ?? true)
    }

    var body: some View {
        let c = theme.swatch(scheme)
        HStack(spacing: theme.spacing.m) {
            NavigationLink(destination: detail) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(skill.title ?? skill.id).font(theme.font(16, .bold)).foregroundStyle(c.ink)
                        if skill.bundled == true { Chip(text: "Hermes", tint: c.mint) }
                    }
                    if let d = skill.description, !d.isEmpty {
                        Text(d).font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft).lineLimit(2)
                    }
                }
            }
            Toggle(skill.title ?? skill.id, isOn: Binding(get: { on }, set: { flip($0) }))
                .labelsHidden()
                .disabled(busy || !model.report.can(.skills, "w"))
                .accessibilityIdentifier("skill-switch-\(skill.id)")
        }
    }

    private func flip(_ value: Bool) {
        on = value
        busy = true
        Task {
            defer { busy = false }
            do {
                let item = try await model.act(.skills, skill.id, value ? "enable" : "disable")
                on = item?.enabled ?? value
                toast = "\(skill.title ?? skill.id) is \(on ? "on" : "off")"
            } catch let e as ControlsError {
                on = !value
                toast = e.message
            }
        }
    }
}

private struct SkillItem: View {
    let model: ControlsModel
    let agentID: String
    let id: String
    let done: () -> Void
    @State private var asking = false
    @State private var toast: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        TextItem(model: model, section: .skills, agentID: agentID, id: id, editTitle: "SKILL.md",
                 editable: model.report.can(.skills, "w"), toast: $toast) { item, rev, _ in
            HStack(spacing: 6) {
                Chip(text: item.enabled == false ? "Off" : "On", tint: item.enabled == false ? c.outline : c.mint)
                if item.bundled == true { Chip(text: "Ships with Hermes", tint: c.lavender) }
            }
            if item.bundled == true {
                Text("Skills that ship with Hermes can be switched off, not deleted. The next update would bring them back.")
                    .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
            } else if model.report.can(.skills, "d") {
                Button("Delete", systemImage: "trash", role: .destructive) { asking = true }
                    .buttonStyle(ControlsPill(danger: true))
                    .accessibilityIdentifier("controls-delete")
                    .alert("Delete the skill \(id)? Its folder goes to the trash for 30 days.", isPresented: $asking) {
                        Button("Delete", role: .destructive) {
                            Task {
                                do {
                                    try await model.delete(.skills, id, rev: rev)
                                    done()
                                    dismiss()
                                } catch let e as ControlsError { toast = e.message }
                            }
                        }
                        Button("Keep it", role: .cancel) {}
                    }
            }
        }
        .navigationTitle(id)
        .toast($toast)
    }
}

// MARK: Schedules

private struct SchedulesScreen: View {
    let model: ControlsModel
    let agentID: String
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        Loader(load: { try await model.list(.schedules) }) { items, reload in
            List {
                if items.isEmpty {
                    Text("Nothing runs on a schedule yet. Ask \(model.agentName) to set one up.")
                        .font(theme.font(15)).foregroundStyle(c.inkSoft)
                }
                ForEach(items) { j in
                    NavigationLink {
                        ScheduleItem(model: model, agentID: agentID, id: j.id, done: reload)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(j.title ?? j.id).font(theme.font(16, .bold)).foregroundStyle(c.ink)
                                if j.paused == true { Chip(text: "Paused", tint: c.butter) }
                            }
                            Text([j.when, j.paused == true ? nil : ControlsTime.next(j.nextRun).map { "next \($0)" }]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                        }
                    }
                    .accessibilityIdentifier("schedule-row-\(j.id)")
                }
            }
            .scrollContentBackground(.hidden)
            .refreshable { reload() }
        }
    }
}

private struct ScheduleItem: View {
    let model: ControlsModel
    let agentID: String
    let id: String
    let done: () -> Void
    @State private var asking = false
    @State private var retiming: (rev: String, item: ControlItem)?
    @State private var busy = false
    @State private var toast: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        TextItem(model: model, section: .schedules, agentID: agentID, id: id, editTitle: "Prompt",
                 editable: model.report.can(.schedules, "w"), toast: $toast, saved: { _ in done() }) { item, rev, reload in
            Card {
                HStack(spacing: 6) {
                    Text(item.title ?? id).font(theme.font(theme.type.title, theme.strong)).foregroundStyle(c.ink)
                    if item.paused == true { Chip(text: "Paused", tint: c.butter) }
                    if item.runningSoon == true { Chip(text: "Running soon", tint: c.mint) }
                }
                Fact(label: "When", value: item.when ?? item.schedule ?? "?")
                if item.paused != true, let n = ControlsTime.next(item.nextRun) { Fact(label: "Next run", value: n) }
                if let d = item.deliver { Fact(label: "Delivers to", value: d == "origin" ? "where it was set up" : d.capitalized) }
                if let l = ControlsTime.ago(item.lastRun) {
                    Fact(label: "Last run", value: l + (item.lastOk == false ? ", failed" : item.lastOk == true ? ", worked" : ""))
                }
            }
            .accessibilityIdentifier("schedule-card")
            if model.report.can(.schedules, "w") {
                HStack(spacing: theme.spacing.s) {
                    Button(item.paused == true ? "Resume" : "Pause", systemImage: item.paused == true ? "play.fill" : "pause.fill") {
                        act(item.paused == true ? "resume" : "pause", reload)
                    }
                    .buttonStyle(ControlsPill(filled: true))
                    .accessibilityIdentifier(item.paused == true ? "controls-resume" : "controls-pause")
                    Button("Run now", systemImage: "bolt.fill") { act("run", reload) }
                        .buttonStyle(ControlsPill())
                        .accessibilityIdentifier("controls-run")
                    Button("Time", systemImage: "clock") { retiming = (rev, item) }
                        .buttonStyle(ControlsPill())
                        .accessibilityIdentifier("controls-time")
                }
                .disabled(busy)
            }
            if model.report.can(.schedules, "d") {
                Button("Delete", systemImage: "trash", role: .destructive) { asking = true }
                    .buttonStyle(ControlsPill(danger: true))
                    .accessibilityIdentifier("controls-delete")
                    .alert("Delete the schedule \(item.title ?? id)? It will stop running.", isPresented: $asking) {
                        Button("Delete", role: .destructive) {
                            Task {
                                do {
                                    try await model.delete(.schedules, id, rev: rev)
                                    done()
                                    dismiss()
                                } catch let e as ControlsError { toast = e.message }
                            }
                        }
                        Button("Keep it", role: .cancel) {}
                    }
            }
            Text("PROMPT").font(theme.font(theme.type.caption, .heavy)).kerning(0.8).foregroundStyle(c.inkSoft)
        }
        .navigationTitle("Schedule")
        .toast($toast)
        .sheet(isPresented: Binding(get: { retiming != nil }, set: { if !$0 { retiming = nil } })) {
            if let r = retiming {
                TimePicker(current: r.item.schedule ?? "") { line in
                    let got = try await model.put(.schedules, id, rev: r.rev, value: ["schedule": .string(line)])
                    toast = "Now \(got.item.when ?? line)"
                    done()
                }
                .environment(\.yuiTheme, theme)
                .presentationDetents([.medium])
            }
        }
    }

    private func act(_ verb: String, _ reload: @escaping () -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await model.act(.schedules, id, verb)
                toast = ["pause": "Paused", "resume": "Resumed", "run": "Runs within a minute"][verb]
                done()
                reload()
            } catch let e as ControlsError {
                toast = e.message
            }
        }
    }
}

/// When a schedule runs: every N minutes, daily at, weekdays at, or a cron line.
private struct TimePicker: View {
    let current: String
    let save: (String) async throws -> Void
    enum Kind: String, CaseIterable { case every = "Every", daily = "Daily", weekdays = "Weekdays", cron = "Cron" }
    @State private var kind = Kind.daily
    @State private var minutes = 30
    @State private var at = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: .now) ?? .now
    @State private var cron = ""
    @State private var error: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var line: String {
        let h = Calendar.current.component(.hour, from: at), m = Calendar.current.component(.minute, from: at)
        switch kind {
        case .every: return "every \(minutes)m"
        case .daily: return "\(m) \(h) * * *"
        case .weekdays: return "\(m) \(h) * * 1-5"
        case .cron: return cron.trimmingCharacters(in: .whitespaces)
        }
    }

    var body: some View {
        let c = theme.swatch(scheme)
        NavigationStack {
            Form {
                Picker("Runs", selection: $kind) { ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("controls-time-kind")
                switch kind {
                case .every:
                    Stepper("Every \(minutes) minutes", value: $minutes, in: 5...720, step: 5)
                case .daily, .weekdays:
                    DatePicker("At", selection: $at, displayedComponents: .hourAndMinute)
                case .cron:
                    TextField("m h dom mon dow", text: $cron).font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if let error { Text(error).foregroundStyle(.red).font(theme.font(theme.type.caption, .semibold)) }
            }
            .scrollContentBackground(.hidden)
            .background(c.background)
            .navigationTitle("When it runs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving" : "Save") {
                        Task {
                            saving = true
                            defer { saving = false }
                            do { try await save(line); dismiss() }
                            catch let e as ControlsError { error = e.message }
                            catch { self.error = ControlsError.noAnswer.message }
                        }
                    }
                    .bold()
                    .disabled(saving || line.isEmpty)
                    .accessibilityIdentifier("controls-time-save")
                }
            }
        }
        .onAppear { load(current) }
    }

    private func load(_ s: String) {
        let p = s.split(separator: " ").map(String.init)
        if s.hasPrefix("every "), let n = Int(s.dropFirst(6).filter(\.isNumber)) { kind = .every; minutes = n; return }
        if p.count == 5, let m = Int(p[0]), let h = Int(p[1]), p[2] == "*", p[3] == "*", p[4] == "*" || p[4] == "1-5" {
            kind = p[4] == "*" ? .daily : .weekdays
            at = Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: .now) ?? at
            return
        }
        if !s.isEmpty { kind = .cron; cron = s }
    }
}

// MARK: Model and tools (read only)

private struct ModelScreen: View {
    let model: ControlsModel
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        Loader(load: { try await model.get(.model, "model") }) { got, _ in
            let (rev, m) = got
            ScrollView {
                VStack(alignment: .leading, spacing: theme.spacing.m) {
                    Card {
                        Fact(label: "Model", value: m.model ?? "?")
                        Fact(label: "Runs on", value: m.provider ?? "?")
                    }
                    Text("TOOLS").font(theme.font(theme.type.caption, .heavy)).kerning(0.8).foregroundStyle(c.inkSoft)
                    Card {
                        ForEach(m.toolsets ?? []) { t in
                            HStack {
                                Circle().fill(t.on ? c.mint : c.outline).frame(width: 10, height: 10)
                                Text(t.name).font(theme.font(15)).foregroundStyle(c.ink)
                                Spacer()
                                Text(t.on ? "On" : "Off").font(theme.font(theme.type.caption, .bold)).foregroundStyle(c.inkSoft)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    Text("Switching the model comes later, once your Mac can test one first. Keys never show here.")
                        .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                    TalkAboutButton(item: TalkItem(section: .model, itemID: "model", rev: rev,
                                                   title: TalkItem.title(.model, m),
                                                   text: "**Model:** \(m.model ?? "?")\n\n**Runs on:** \(m.provider ?? "?")\n\n"
                                                       + "**Tools:** " + (m.toolsets ?? []).map(\.name).joined(separator: ", ")))
                }
                .padding(theme.spacing.l)
            }
        }
    }
}

// MARK: Channels (read only)

private struct ChannelsScreen: View {
    let model: ControlsModel
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        Loader(load: { try await model.list(.channels) }) { items, _ in
            ScrollView {
                VStack(alignment: .leading, spacing: theme.spacing.m) {
                    Card {
                        ForEach(items) { ch in
                            HStack {
                                Circle().fill(ch.live == true ? c.mint : c.outline).frame(width: 10, height: 10)
                                Text(ch.title ?? ch.id).font(theme.font(16, .bold)).foregroundStyle(c.ink)
                                Spacer()
                                Text(ch.live == true ? "Connected" : "Off").font(theme.font(theme.type.caption, .bold))
                                    .foregroundStyle(c.inkSoft)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    Text("Where else \(model.agentName) answers. Set these up on your Mac.")
                        .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                }
                .padding(theme.spacing.l)
            }
        }
    }
}
