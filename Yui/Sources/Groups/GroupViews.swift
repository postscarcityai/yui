import SwiftUI

// Group threads in the app (YUI-94). Spec: yuigui/spec/GROUPS.md.
// The agent list holds the groups (stacked faces) and the New group button; the sheet
// below picks two or more agents, a name and the lead.

/// Faces overlapping in a row, the lead first with a small crown.
struct GroupFaces: View {
    let agents: [YuiAgent]
    var lead: String?
    var size: Double = 30
    var limit = 4

    var body: some View {
        HStack(spacing: -size * 0.32) {
            ForEach(Array(agents.prefix(limit).enumerated()), id: \.element.id) { i, a in
                AgentBadge(agent: a, size: size)
                    .overlay(alignment: .topTrailing) {
                        if a.id == lead && agents.count > 1 { Crown(size: size) }
                    }
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2).padding(-1))
                    .zIndex(Double(limit - i))
            }
            if agents.count > limit {
                Text("+\(agents.count - limit)")
                    .font(.system(size: size * 0.36, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(.quaternary, in: Circle())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(agents.map(\.name).joined(separator: ", "))
    }
}

/// The lead's little crown.
struct Crown: View {
    let size: Double
    var body: some View {
        Image(systemName: "crown.fill")
            .font(.system(size: max(8, size * 0.3)))
            .foregroundStyle(.yellow)
            .shadow(color: .black.opacity(0.35), radius: 1)
            .offset(x: size * 0.12, y: -size * 0.14)
            .accessibilityHidden(true)
    }
}

/// A group in the agent list: faces, its name, who is in it.
struct GroupRow: View {
    let group: GroupInfo
    let agents: [YuiAgent]
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        let faces = group.ordered(agents) { $0.id }
        HStack(spacing: theme.spacing.m) {
            GroupFaces(agents: faces, lead: group.lead, size: 32).frame(minWidth: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title).font(theme.font(theme.type.body, theme.strong)).foregroundStyle(c.ink)
                Text(faces.map(\.name).joined(separator: ", "))
                    .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(c.inkSoft)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("group-row")
    }
}

/// New group: pick two or more agents, a name, the lead.
struct NewGroupSheet: View {
    @Environment(AgentStore.self) private var agents
    @Environment(GroupStore.self) private var groups
    @Environment(\.dismiss) private var dismiss
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    /// Called with the new group's id once it is made.
    var made: (String) -> Void = { _ in }
    @State private var picked: [String] = []
    @State private var title = ""
    @State private var lead: String?
    @State private var working = false
    @State private var refusal: GroupError?
    @State private var failure: String?

    private var members: [YuiAgent] { picked.compactMap { id in agents.agents.first { $0.id == id } } }
    private var suggested: String { GroupStore.suggestedTitle(members.map(\.name)) }
    private var name: String { GroupStore.validTitle(title) ?? GroupStore.validTitle(suggested) ?? "" }
    private var ready: Bool { picked.count >= 2 && !name.isEmpty }

    var body: some View {
        let c = theme.swatch(scheme)
        NavigationStack {
            List {
                Section {
                    ForEach(agents.agents) { a in pickRow(a, c) }
                } header: { header("Who is in it? Pick two or more.", c) }
                Section {
                    TextField(suggested.isEmpty ? "Name the group" : suggested, text: $title)
                        .accessibilityIdentifier("group-name")
                        .submitLabel(.done)
                } header: { header("Name", c) }
                if picked.count >= 2 {
                    Section {
                        ForEach(members) { a in leadRow(a, c) }
                    } header: { header("The lead answers anything you don't @.", c) }
                }
                Section {
                    if refusal == .updateNeeded { UpdateChip().frame(maxWidth: .infinity) }
                    if let words = failure ?? refusal?.spoken {
                        Text(words).font(theme.font(theme.type.caption)).foregroundStyle(.red)
                            .accessibilityIdentifier("group-error")
                    }
                    PillButton(title: "Start group", working: working) { Task { await create() } }
                        .disabled(!ready || working).opacity(ready ? 1 : 0.4)
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                        .accessibilityIdentifier("group-create")
                }
            }
            .scrollContentBackground(.hidden)
            .background(c.background)
            .navigationTitle("New group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.tint(c.inkSoft) } }
        }
    }

    private func header(_ text: String, _ c: Swatch) -> some View {
        Text(text).font(theme.font(theme.type.body, .semibold)).foregroundStyle(c.inkSoft).textCase(nil)
    }

    private func pickRow(_ a: YuiAgent, _ c: Swatch) -> some View {
        let on = picked.contains(a.id)
        return Button { toggle(a) } label: {
            HStack(spacing: theme.spacing.m) {
                AgentBadge(agent: a, size: 36)
                Text(a.name).font(theme.font(theme.type.body, theme.strong)).foregroundStyle(c.ink)
                Spacer()
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(on ? c.accent : c.inkSoft)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("group-pick-\(a.handle)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func leadRow(_ a: YuiAgent, _ c: Swatch) -> some View {
        Button { lead = a.id } label: {
            HStack(spacing: theme.spacing.m) {
                AgentBadge(agent: a, size: 30)
                Text(a.name).font(theme.font(theme.type.body)).foregroundStyle(c.ink)
                Spacer()
                if (lead ?? picked.first) == a.id { Crown(size: 20).offset(x: 0, y: 0) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("group-lead-\(a.handle)")
        .accessibilityAddTraits((lead ?? picked.first) == a.id ? .isSelected : [])
    }

    private func toggle(_ a: YuiAgent) {
        if let i = picked.firstIndex(of: a.id) {
            picked.remove(at: i)
            if lead == a.id { lead = nil }
        } else if picked.count < 12 {
            picked.append(a.id)
        }
        refusal = nil; failure = nil
    }

    private func create() async {
        guard ready, let leadID = lead.flatMap({ picked.contains($0) ? $0 : nil }) ?? picked.first else { return }
        working = true; refusal = nil; failure = nil
        defer { working = false }
        do {
            let id = try await groups.create(title: name, lead: leadID, members: picked)
            dismiss()
            made(id)
        } catch let e as GroupError {
            refusal = e
        } catch {
            failure = GroupStore.words(error)
        }
    }
}

/// Groups for the app (YUI-94): the store in the environment, read once signed in, dropped on sign out.
/// The demo account has no server, so no groups.
struct GroupsHooks: ViewModifier {
    let groups: GroupStore
    @Environment(Account.self) private var account

    func body(content: Content) -> some View {
        content
            .environment(groups)
            .task(id: account.session?.userID ?? "") {
                groups.reset()
                guard account.isSignedIn, account.session?.userID != "demo" else { return }
                groups.attach(account)
                await groups.refresh()
            }
    }
}
