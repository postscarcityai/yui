import SwiftUI
import YuiLines

// Flows on the phone (YUI-115, spec yuigui/spec/FLOWS.md sections 4 to 6): a flow an agent
// sends runs here, one step at a time, branches and all. The path, the progress and the
// event come from YuiLines (flowPath, flowNext, flowEvent); this file is the screen and what
// the phone keeps so a run survives a killed app and never sends twice.

/// What the phone keeps for one flow on one message: every answer given (off-path answers
/// too, FLOWS.md section 4), the step on screen (a step id or `review`), `sent` once the event
/// is out, and the graph a saved flow ran (a copy, not a live link).
struct FlowRun: Codable, Equatable {
    /// The value of each step's own event, by step id: what its preset hands over (`choice`, `picked`...).
    var events: [String: [String: YLValue]] = [:]
    var step: String?
    var sent = false
    /// An edit opened from the review: Next goes back to it once the path is whole again.
    var fromReview = false
    var graph: YLValue?

    /// Keyed by the message and the flow's id. Under `yui.runner.` so a UI test's runner reset clears it too.
    static func key(_ scope: String, _ id: String) -> String { "yui.runner.flow.\(scope).\(id)" }

    @MainActor static func load(_ scope: String, _ id: String, in d: UserDefaults = .standard) -> FlowRun? {
        RunnerProgress.resetIfAsked()
        return d.data(forKey: key(scope, id)).flatMap { try? JSONDecoder().decode(FlowRun.self, from: $0) }
    }

    func save(_ scope: String, _ id: String, in d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key(scope, id)) }
    }

    static func clear(_ scope: String, _ id: String, in d: UserDefaults = .standard) { d.removeObject(forKey: key(scope, id)) }

    /// A skipped question answers with null: on the path, never sent.
    static let skipped: [String: YLValue] = ["skipped": .bool(true)]

    /// The answer each step's event stands for.
    var answers: [String: YLValue] {
        events.compactMapValues { e in
            if e["skipped"] == .bool(true) { return YLValue.null }
            for k in ["answer", "choice", "picked", "value", "form", "transcript", "photo"] { if let v = e[k] { return v } }
            return nil
        }
    }
}

/// The steps of a flow's graph, as components the presets can draw.
private extension YLFlowNode {
    func component(_ c: YLComponent, index: Int) -> YLComponent {
        YLComponent(serial: c.serial &* 1000 &+ index, ylID: id, preset: preset ?? "page", screen: c.screen, props: props, line: "")
    }
}

struct FlowPreset: View {
    let c: YLComponent
    @State private var run = FlowRun()
    @State private var loaded = false
    /// Steps holding Next: a form with a required field still empty.
    @State private var missing: Set<String> = []
    @Environment(\.ylScope) private var scope
    @Environment(\.ylEmit) private var emit
    @Environment(\.ylAnswers) private var sentAnswers
    @Environment(\.ylOnStage) private var onStage
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    // MARK: what runs

    private enum Shown { case waiting, unknown, flow(ResolvedFlow) }

    /// The flow this component is: its own chart (inline), its base with changes (a variant),
    /// or a saved flow by name. A run that already started keeps the copy it began with.
    private var shown: Shown {
        let title = c.string("title") ?? ""
        if let name = c.string("as") {
            // A variant's changes land with its `end`.
            guard c.props["source"] != nil else { return .waiting }
            let v = SavedFlows.variant(base: title, changes: c.props["changes"]?.array ?? [], as: name)
            return v.map { .flow($0) } ?? .unknown
        }
        if c.props["nodes"] != nil {
            return .flow(ResolvedFlow(name: title, title: title, submit: nil, graph: YLFlowGraph(props: c.props)))
        }
        // An inline flow with its chart still streaming in has a source only once it ends.
        if c.props["source"] != nil { return .flow(ResolvedFlow(name: title, title: title, submit: nil, graph: YLFlowGraph())) }
        let saved = SavedFlows.resolve(title)
        if let g = run.graph?.object {
            return .flow(ResolvedFlow(name: title, title: saved?.title ?? title, submit: saved?.submit, graph: YLFlowGraph(props: g)))
        }
        return saved.map { .flow($0) } ?? .unknown
    }

    private var submitLabel: String {
        if let s = c.string("submit") { return s }
        if case .flow(let r) = shown, let s = r.submit { return s }
        return "Send"
    }
    private var reviewOn: Bool { c.props["review"]?.bool != false }

    var body: some View {
        let s = theme.swatch(scheme)
        PresetCard(flat: onStage) {
            switch shown {
            case .waiting:
                wait(s)
            case .unknown:
                let name = c.string("as") ?? c.string("title") ?? "that"
                wayOn("No saved flow called \u{201C}\(name)\u{201D}.", "I only have the ones built in. Tell the agent and it can send the flow itself.", s)
            case .flow(let r):
                let title = c.string("as").map { SavedFlows.title(ofName: $0) } ?? r.title
                if !title.isEmpty { PresetTitle(text: title) }
                if r.graph.nodes.contains(where: { $0.preset != nil }) {
                    running(r.graph, s)
                } else {
                    wayOn("This flow has no steps.", "Nothing to ask here. Tell the agent and it can send another.", s)
                }
            }
        }
        .onAppear { load() }
        .onChange(of: run) { _, r in
            guard loaded else { return }
            r.save(scope, c.ylID)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let r = FlowRun.load(scope, c.ylID) { run = r }
        // A variant is kept under its name the first time it shows (FLOWS.md section 9).
        if let name = c.string("as"), c.props["source"] != nil, let base = c.string("title") {
            SavedFlows.keep(KeptVariant(name: YuiLines.flowName(name), title: SavedFlows.title(ofName: name), base: base,
                                        changes: c.props["changes"]?.array ?? []))
        }
        // Sent before the kill: the event rows say so even when the run store is gone.
        if !run.sent, sentAnswers(scope, c.ylID)?["flow"] != nil { run.sent = true }
    }

    // MARK: no flow, or nothing in it

    private func wait(_ s: Swatch) -> some View {
        Text("The steps are on their way.").font(theme.font(theme.type.body, .medium)).foregroundStyle(s.inkSoft)
    }

    /// A full screen always has somewhere to go (Chris, 2026-09-27): a note and a Send.
    private func wayOn(_ headline: String, _ note: String, _ s: Swatch) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.m) {
            Text(headline).font(theme.font(theme.type.body, .heavy)).foregroundStyle(s.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(note).font(theme.font(theme.type.body, .medium)).foregroundStyle(s.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            OptionPill(text: "Tell the agent", fill: s.accent, ink: s.onAccent, grow: true, icon: "paperplane.fill") {
                emit(c.event(["missing": .bool(true), "name": .string(c.string("title") ?? "")], echo: headline))
            }
            .accessibilityIdentifier("flow-tell")
        }
    }

    // MARK: the run

    private func running(_ g: YLFlowGraph, _ s: Swatch) -> some View {
        let answers = run.answers
        let route = YuiLines.flowPath(g, answers)
        let cur = current(g, route)
        return VStack(alignment: .leading, spacing: theme.spacing.m) {
            if run.sent {
                summary(g, s)
            } else if cur == "review" {
                reviewList(g, s)
            } else if let node = g.node(cur) {
                progress(g, route, node, s)
                stepView(g, node)
                controls(g, route, node, s)
            }
        }
    }

    /// Where the person is: the stored step while it is on the path (or is the open question),
    /// else the first question with no answer, else the review (FLOWS.md section 5, Resume).
    private func current(_ g: YLFlowGraph, _ route: YLFlowRoute) -> String {
        if run.step == "review", reviewOn, route.open == nil { return "review" }
        if let s = run.step, route.path.contains(s) || s == route.open { return s }
        if let open = route.open { return open }
        if reviewOn { return "review" }
        return route.path.last ?? YuiLines.flowFirst(g) ?? ""
    }

    private func progress(_ g: YLFlowGraph, _ route: YLFlowRoute, _ node: YLFlowNode, _ s: Swatch) -> some View {
        let answers = run.answers
        let before = route.path.firstIndex(of: node.id) ?? route.path.count
        let ahead = YuiLines.flowAhead(g, answers, from: node.id).count
        let total = before + 1 + ahead
        return VStack(alignment: .leading, spacing: theme.spacing.xs) {
            HStack {
                Text("Step \(before + 1) of \(total)").font(theme.font(theme.type.caption, .heavy)).foregroundStyle(s.inkSoft)
                    .accessibilityIdentifier("flow-progress")
                Spacer()
            }
            ProgressView(value: Double(before + 1), total: Double(total)).tint(s.accent)
        }
    }

    private func stepView(_ g: YLFlowGraph, _ node: YLFlowNode) -> some View {
        let index = g.nodes.firstIndex { $0.id == node.id } ?? 0
        let comp = node.component(c, index: index)
        let events = run.events
        return Group {
            if node.preset == "page", onStage { StoryPage(c: comp, active: true) }
            else if node.preset == "page" { PagePreset(c: comp).padding(.vertical, theme.spacing.s) }
            else if onStage { StageCenter { PresetView(component: comp) } }
            else { PresetView(component: comp) }
        }
        .id("\(c.serial)-\(node.id)")
        .environment(\.ylBare, true)
        .environment(\.ylHostedSubmit, true)
        .environment(\.ylAnswers, YLAnswers { _, id in events[id] })
        .environment(\.ylEmit, YLEmit { e in record(e, node: node, g: g) })
        .frame(maxHeight: onStage ? .infinity : nil, alignment: .top)
        .accessibilityIdentifier("flow-step-\(node.id)")
    }

    private func controls(_ g: YLFlowGraph, _ route: YLFlowRoute, _ node: YLFlowNode, _ s: Swatch) -> some View {
        let answers = run.answers
        let at = route.path.firstIndex(of: node.id)
        // Back walks the path taken, not the source order.
        let back: String? = at.map { $0 > 0 ? route.path[$0 - 1] : nil } ?? route.path.last
        let last = YuiLines.flowNext(g, answers, from: node.id, guess: true) == nil && !run.fromReview
        let held = missing.contains(node.id)
        let word = last ? (reviewOn ? "Review" : submitLabel) : "Next"
        return HStack(spacing: theme.spacing.s) {
            OptionPill(text: "Back", fill: s.lavender, on: back != nil, grow: true) {
                if let back { withAnimation(theme.spring) { run.step = back } }
            }
            .disabled(back == nil)
            .accessibilityIdentifier("flow-back")
            OptionPill(text: word, fill: s.accent, ink: s.onAccent, on: !held, grow: true) { next(g, node) }
                .disabled(held)
                .accessibilityIdentifier(last ? (reviewOn ? "flow-review" : "flow-submit") : "flow-next")
        }
    }

    // MARK: moving

    /// What a step's own event says. A form, a pick and a mic hand over every edit, and all
    /// fields cleared or every pick off takes the answer back (as in a plan).
    private func record(_ e: YLEvent, node: YLFlowNode, g: YLFlowGraph) {
        if node.preset == "form" || node.preset == "pick" || node.preset == "mic" {
            if e.value["missing"] != nil { missing.insert(node.id) } else { missing.remove(node.id) }
            if YLComponent.answerValue(e) == nil { run.events[node.id] = nil }
        }
        guard YLComponent.answerValue(e) != nil else { return }
        run.events[node.id] = e.value
        // The step on screen is the one being answered: a first step typed into must not let the
        // next open question take its place.
        if run.step == nil { run.step = node.id }
        run.sent = false
        if run.graph == nil, c.props["nodes"] == nil { run.graph = g.value }
        // ask and choose move on by themselves after a tap.
        guard node.preset == "ask" || node.preset == "choose" else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            // Only if the person did not move on already.
            guard run.step == node.id || run.step == nil else { return }
            withAnimation(theme.spring) { advance(g, from: node.id) }
        }
    }

    /// Next: an unanswered question is skipped (a slider answers where it sits).
    private func next(_ g: YLFlowGraph, _ node: YLFlowNode) {
        if node.isQuestion, run.events[node.id] == nil {
            if node.preset == "slide" {
                let lo = node.props["min"]?.number ?? 1, hi = max(node.props["max"]?.number ?? 5, lo + 1)
                let step = max(node.props["step"]?.number ?? 1, 0.0001)
                let v = node.props["value"]?.number ?? (lo + ((hi - lo) / 2 / step).rounded() * step)
                run.events[node.id] = ["value": .number(v)]
            } else {
                run.events[node.id] = FlowRun.skipped
            }
            if run.graph == nil, c.props["nodes"] == nil { run.graph = g.value }
        }
        withAnimation(theme.spring) { advance(g, from: node.id) }
    }

    /// Follows the edge the answers pick. With nothing left, the review comes next (or the send).
    private func advance(_ g: YLFlowGraph, from id: String) {
        let answers = run.answers
        let route = YuiLines.flowPath(g, answers)
        run.sent = false
        if run.fromReview {
            // An edit from the review: back to it once the path is whole, else through what is new first.
            if let open = route.open { run.step = open; return }
            run.fromReview = false
            run.step = "review"
            return
        }
        if let n = YuiLines.flowNext(g, answers, from: id) { run.step = n; return }
        if reviewOn { run.step = "review" } else { submit(g) }
    }

    // MARK: review, send, sent

    private func questions(_ g: YLFlowGraph) -> [YLFlowNode] {
        let route = YuiLines.flowPath(g, run.answers)
        return route.path.compactMap { g.node($0) }.filter(\.isQuestion)
    }

    private func prompt(_ g: YLFlowGraph, _ n: YLFlowNode) -> String {
        n.component(c, index: g.nodes.firstIndex { $0.id == n.id } ?? 0).prompt
    }

    private func reviewList(_ g: YLFlowGraph, _ s: Swatch) -> some View {
        let answers = run.answers
        return VStack(alignment: .leading, spacing: theme.spacing.m) {
            Text("Your answers").font(theme.font(theme.type.caption, .heavy)).foregroundStyle(s.inkSoft)
            ForEach(questions(g), id: \.id) { n in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(prompt(g, n)).font(theme.font(theme.type.caption, .heavy)).foregroundStyle(s.inkSoft)
                        Text(YLComponent.answerText(answers[n.id]))
                            .font(theme.font(theme.type.body, .bold))
                            .foregroundStyle(answers[n.id] == .null ? s.inkSoft : s.ink)
                    }
                    Spacer()
                    Button("Edit") {
                        withAnimation(theme.spring) { run.fromReview = true; run.step = n.id }
                    }
                    .font(theme.font(theme.type.caption, .heavy))
                    .foregroundStyle(s.ink)
                    .accessibilityLabel("Edit \(prompt(g, n))")
                    .accessibilityIdentifier("flow-edit-\(n.id)")
                }
            }
            OptionPill(text: submitLabel, fill: s.accent, ink: s.onAccent, grow: true) { submit(g) }
                .accessibilityIdentifier("flow-submit")
        }
    }

    private func submit(_ g: YLFlowGraph) {
        let e = YuiLines.flowEvent(g, run.answers)
        // A skipped question is on the path and sends nothing.
        let flow = e.flow.filter { $0.value != .null }
        // The echo is the fold-back: the chat shows it as the person's own message, a line per answer on the path.
        let lines = questions(g).compactMap { n -> String? in
            guard let v = flow[n.id] else { return nil }
            let q = prompt(g, n)
            let sep = q.hasSuffix("?") || q.hasSuffix(":") ? " " : ": "
            return q + sep + (n.preset == "camera" ? "Photo" : YLComponent.answerText(v))
        }
        emit(c.event(["flow": .object(flow), "path": .array(e.path.map(YLValue.string))],
                     echo: lines.isEmpty ? "Sent" : lines.joined(separator: "\n")))
        withAnimation(theme.spring) { run.sent = true; run.fromReview = false; run.step = "review" }
    }

    private func summary(_ g: YLFlowGraph, _ s: Swatch) -> some View {
        let answers = run.answers
        return VStack(alignment: .leading, spacing: theme.spacing.s) {
            Label("Sent", systemImage: "checkmark.circle.fill").font(theme.font(theme.type.body, .heavy))
                .foregroundStyle(ChartPalette.good(scheme))
                .accessibilityIdentifier("flow-sent")
            ForEach(questions(g).filter { answers[$0.id] != .null }, id: \.id) { n in
                Text("\(prompt(g, n)): \(YLComponent.answerText(answers[n.id]))")
                    .font(theme.font(theme.type.caption, .semibold)).foregroundStyle(s.ink)
            }
            OptionPill(text: "Edit answers", fill: s.lavender, grow: true) {
                // Edit and submit again sends a new event (FLOWS.md section 4).
                withAnimation(theme.spring) { run.sent = false; run.step = "review" }
            }
        }
    }
}

// MARK: - record

/// A sent flow in the chat: its title and what it held, folded. Tap to see the answers; Open brings it back.
struct FlowRecord: View {
    let flow: YLComponent
    let open: () -> Void
    @State private var expanded = false
    @Environment(\.ylScope) private var scope
    @Environment(\.ylAnswers) private var sent
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        let event = sent(scope, flow.ylID)
        let answers = event?["flow"]?.object ?? [:]
        let title = flow.string("as").map { SavedFlows.title(ofName: $0) } ?? SavedFlows.resolve(flow.string("title") ?? "")?.title
            ?? flow.string("title") ?? "Flow"
        let held = "\(answers.count) answer\(answers.count == 1 ? "" : "s")"
        VStack(alignment: .leading, spacing: theme.spacing.s) {
            Button { withAnimation(theme.spring) { expanded.toggle() } } label: {
                HStack(spacing: theme.spacing.s) {
                    Image(systemName: "checkmark")
                        .font(theme.font(theme.type.caption, .black))
                        .foregroundStyle(s.onAccent)
                        .frame(width: 26, height: 26)
                        .background(s.accent, in: Circle())
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).font(theme.font(theme.type.body, .bold)).foregroundStyle(s.ink).lineLimit(1)
                        Text(held).font(theme.font(theme.type.caption, .semibold)).foregroundStyle(s.inkSoft)
                    }
                    Spacer(minLength: theme.spacing.s)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(theme.font(theme.type.caption, .heavy)).foregroundStyle(s.inkSoft)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), sent, \(held)")
            .accessibilityHint(expanded ? "Hides the answers" : "Shows the answers")
            .accessibilityIdentifier("flow-record")
            if expanded {
                ForEach(answers.keys.sorted(), id: \.self) { k in
                    Text("\(k): \(YLComponent.answerText(answers[k]))")
                        .font(theme.font(theme.type.caption, .semibold)).foregroundStyle(s.ink)
                }
            }
            OptionPill(text: "Open", fill: s.lavender, grow: true, action: open)
        }
        .padding(theme.spacing.m)
        .background(s.surface, in: .rect(cornerRadius: theme.radius.card))
        .overlay(RoundedRectangle(cornerRadius: theme.radius.card).stroke(s.outline, lineWidth: 1.5))
    }
}
