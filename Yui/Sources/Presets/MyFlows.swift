import SwiftUI
import YuiLines

// My flows (YUI-238, spec yuigui/spec/FLOWS.md sections 8 and 9, mock /playground?demo=myflows):
// every saved flow in one list. The starters come with every Yui and stay; a variant is listed
// under the flow it starts from, with its own variants under it. Tap a row to run it on the stage;
// swipe it, or hold it, to Remove. A variant goes alone; one with variants of its own takes them along.

/// One row of the list.
struct FlowRow: Identifiable, Equatable {
    var name: String
    var title: String
    /// Steps in the flow's chart (0 when its base is gone and it cannot run).
    var steps: Int
    /// A starter ships in the app and cannot be removed.
    var starter: Bool
    /// How far under a starter: 0 for a starter, 1 for its variant, 2 for a variant of that.
    var depth: Int
    /// The title of the flow a variant starts from.
    var from: String?
    /// How many variants this row would take with it when removed.
    var variants: Int
    var id: String { name }
}

@MainActor
enum MyFlows {
    /// The list, top to bottom: each starter, its variants under it, then any variant whose base is gone.
    static func rows(in d: UserDefaults = .standard) -> [FlowRow] {
        var variants: [(name: String, title: String, base: String)] = StarterFlows.variants
            .filter { !SavedFlows.removed(in: d).contains($0.name) }
            .map { ($0.name, SavedFlows.title(ofName: $0.name), $0.base) }
        for k in SavedFlows.kept(in: d) where !variants.contains(where: { YuiLines.flowKey($0.name) == YuiLines.flowKey(k.name) }) {
            variants.append((k.name, k.title, k.base))
        }
        func under(_ parent: String) -> [(name: String, title: String, base: String)] {
            variants.filter { YuiLines.flowKey($0.base) == YuiLines.flowKey(parent) }
        }
        func count(_ name: String, seen: Set<String>) -> Int {
            under(name).filter { !seen.contains($0.name) }.reduce(0) { $0 + 1 + count($1.name, seen: seen.union([$1.name])) }
        }
        var out: [FlowRow] = []
        var placed: Set<String> = []
        func place(_ name: String, title: String, starter: Bool, depth: Int, from: String?) {
            guard !placed.contains(name), depth <= SavedFlows.maxDepth else { return }
            placed.insert(name)
            let steps = SavedFlows.resolve(name, in: d)?.graph.nodes.filter { $0.preset != nil }.count ?? 0
            out.append(FlowRow(name: name, title: title, steps: steps, starter: starter, depth: depth, from: from,
                               variants: count(name, seen: [name])))
            for v in under(name) { place(v.name, title: v.title, starter: false, depth: depth + 1, from: title) }
        }
        for f in StarterFlows.all { place(f.name, title: f.title, starter: true, depth: 0, from: nil) }
        // A variant whose base is gone cannot run; it is still listed so it can be removed.
        for v in variants where !placed.contains(v.name) {
            place(v.name, title: v.title, starter: false, depth: 1, from: SavedFlows.title(ofName: v.base))
        }
        return out
    }

    /// The names a Remove of `name` takes: itself and every variant under it. Empty for a starter.
    static func removal(of name: String, in d: UserDefaults = .standard) -> [String] {
        let all = rows(in: d)
        guard let i = all.firstIndex(where: { $0.name == name }), !all[i].starter else { return [] }
        var names = [name]
        var j = i + 1
        while j < all.count, all[j].depth > all[i].depth { names.append(all[j].name); j += 1 }
        return names
    }

    /// Removes it and the variants under it. Returns the names that went.
    @discardableResult
    static func remove(_ name: String, in d: UserDefaults = .standard) -> [String] {
        let names = removal(of: name, in: d)
        for n in names { SavedFlows.forget(n, in: d) }
        return names
    }
}

struct MyFlowsView: View {
    /// Runs a flow on the stage: the sheet and the drawer shut first.
    let run: (FlowRow) -> Void
    let dismiss: () -> Void
    @State private var rows: [FlowRow] = { SavedFlows.resetForTests(); return MyFlows.rows() }()
    @State private var removing: FlowRow?
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        VStack(spacing: 0) {
            HStack {
                Text("My flows").font(theme.font(theme.type.title, .heavy)).foregroundStyle(c.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done", action: dismiss)
                    .font(theme.font(theme.type.body, .heavy)).foregroundStyle(c.accent)
                    .accessibilityIdentifier("my-flows-done")
            }
            .padding(.horizontal, theme.spacing.l).padding(.top, theme.spacing.l).padding(.bottom, theme.spacing.s)
            List {
                Section {
                    ForEach(rows) { r in
                        row(r, c)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if !r.starter {
                                    Button("Remove", role: .destructive) { removing = r }
                                        .accessibilityIdentifier("my-flows-remove-\(r.name)")
                                }
                            }
                    }
                } footer: {
                    Text("Starters come with every Yui and stay as they are. Ask your agent to make a variant, and it lands under the flow it came from.")
                        .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                        .padding(.top, theme.spacing.s)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("my-flows-list")
        }
        .background(c.background.ignoresSafeArea())
        .alert(removing.map(title) ?? "", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
               presenting: removing) { r in
            Button("Remove", role: .destructive) {
                MyFlows.remove(r.name)
                withAnimation { rows = MyFlows.rows() }
            }
            .accessibilityIdentifier("my-flows-remove-confirm")
            Button("Keep it", role: .cancel) {}
        } message: { r in
            Text(r.variants > 0
                 ? "Its \(r.variants == 1 ? "variant goes" : "\(r.variants) variants go") with it. A run already started keeps going."
                 : "Your agent can send it again any time.")
        }
    }

    private func title(_ r: FlowRow) -> String { "Remove \u{201C}\(r.title)\u{201D}?" }

    private func row(_ r: FlowRow, _ c: Swatch) -> some View {
        Button { run(r) } label: {
            HStack(spacing: theme.spacing.m) {
                if r.depth > 0 {
                    Image(systemName: "arrow.turn.down.right").font(theme.font(13, .bold)).foregroundStyle(c.inkSoft)
                        .padding(.leading, CGFloat(r.depth - 1) * 14)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.title).font(theme.font(theme.type.body, .bold)).foregroundStyle(c.ink).lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(sub(r)).font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "play.fill").font(theme.font(13, .bold)).foregroundStyle(c.onAccent)
                    .frame(width: 32, height: 32).background(c.accent, in: Circle())
            }
            .padding(.horizontal, theme.spacing.m).padding(.vertical, theme.spacing.s + 2)
            .background(c.surface, in: .rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(c.outline, lineWidth: 1))
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(BounceButtonStyle())
        .disabled(r.steps == 0)
        .contextMenu {
            Button("Run", systemImage: "play.fill") { run(r) }
            if !r.starter { Button("Remove", systemImage: "trash", role: .destructive) { removing = r } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("my-flows-row-\(r.name)")
    }

    private func sub(_ r: FlowRow) -> String {
        let n = r.steps == 0 ? "Its base flow is gone" : "\(r.steps) steps"
        if let from = r.from { return "\(n) · from \(from)" }
        return "\(n) · Starter"
    }
}
