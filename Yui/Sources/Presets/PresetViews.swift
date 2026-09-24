import SwiftUI
import YuiLines

extension EnvironmentValues {
    @Entry var ylEmit = YLEmit()
    /// Every component in the reply: group heads find their members here, and
    /// `chart data=id` its table.
    @Entry var ylComponents: [YLComponent] = []
    /// Puts a saved screen back (`project open=name`).
    @Entry var ylShow = YLShow()
    /// The thread's answers, for presets that reopen answered.
    @Entry var ylAnswers = YLAnswers()
    /// Goes to one of the agent's pages (2 or 3) from the chat's page pills.
    @Entry var ylPage = YLPage()
}

/// Moves the thread to page `n` (spec section 5, Pages).
struct YLPage: Sendable {
    var run: @MainActor @Sendable (Int) -> Void = { _ in }
    @MainActor func callAsFunction(_ n: Int) { run(n) }
    init(_ run: @escaping @MainActor @Sendable (Int) -> Void = { _ in }) { self.run = run }
}

/// `(reply scope, screen, saved name)`: the host applies `show name` to that reply.
struct YLShow: Sendable {
    var run: @MainActor @Sendable (String, String, String) -> Void = { _, _, _ in }
    @MainActor func callAsFunction(scope: String, screen: String, name: String) { run(scope, screen, name) }
    init(_ run: @escaping @MainActor @Sendable (String, String, String) -> Void = { _, _, _ in }) { self.run = run }
}

/// A reply's components laid out: one view each, steps as one stepper, staged runs as pills.
struct YLItemsView: View {
    let items: [YLItem]
    var openStage: () -> Void = {}
    @Environment(\.ylScope) private var scope
    @Environment(\.ylAnswers) private var answers

    var body: some View {
        ForEach(items) { item in
            switch item {
            case .one(let c): PresetView(component: c)
            case .steps(let cs): StepperPreset(steps: cs)
            case .pill(let cs):
                // A sent plan leaves a record instead of a pill (YUI-51).
                if let plan = cs.first(where: { $0.preset == "plan" }), answers(scope, plan.ylID)?["plan"] != nil {
                    PlanRecord(plan: plan, open: openStage)
                    let rest = cs.filter { $0.serial != plan.serial }
                    if !rest.isEmpty { StagePill(components: rest, scope: scope, open: openStage) }
                } else {
                    StagePill(components: cs, scope: scope, open: openStage)
                }
            case .page(let n, let cs): PagePill(page: n, components: cs)
            }
        }
    }
}

/// Renders one YL component. Every look comes from `YuiTheme` tokens.
struct PresetView: View {
    let component: YLComponent

    var body: some View {
        switch component.preset {
        case "ask": AskPreset(c: component)
        case "choose": ChoosePreset(c: component, multi: false)
        case "pick": ChoosePreset(c: component, multi: true)
        case "slide": SlidePreset(c: component)
        case "form": FormPreset(c: component)
        case "list": ListPreset(c: component)
        case "timer": TimerPreset(c: component)
        case "say": SayPreset(text: component.string("text") ?? "")
        case "image": ImagePreset(c: component)
        case "video": VideoPreset(c: component)
        case "camera": CameraPreset(c: component)
        case "card": CardPreset(c: component)
        case "table": TablePreset(c: component)
        case "gallery": GalleryPreset(c: component)
        case "compare": ComparePreset(c: component)
        case "storyboard": StoryboardPreset(c: component)
        case "chart": ChartPreset(c: component)
        case "stat": StatPreset(c: component)
        case "math": MathPreset(c: component)
        case "step": StepperPreset(steps: [component])
        case "calc": CalcPreset(c: component)
        case "deck": DeckPreset(c: component)
        case "page": PagePreset(c: component, standalone: true)
        case "plan": PlanPreset(c: component)
        case "project": ProjectPreset(c: component)
        case "narrate": NarratePreset(c: component)
        default: LaterPreset(c: component)
        }
    }
}

/// The rounded paper card every preset sits on.
struct PresetCard<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        VStack(alignment: .leading, spacing: theme.spacing.m) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(theme.spacing.l)
            .background(c.surface, in: .rect(cornerRadius: theme.radius.card))
            .overlay(RoundedRectangle(cornerRadius: theme.radius.card).stroke(c.outline, lineWidth: 1.5))
            .transition(.scale(scale: 0.9, anchor: .topLeading).combined(with: .opacity))
    }
}

struct PresetTitle: View {
    let text: String
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(text)
            .font(theme.font(theme.type.title, theme.strong))
            .foregroundStyle(theme.swatch(scheme).ink)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension Swatch {
    /// Pastel fills options cycle through, so a row of buttons reads as candy, not a form.
    var candy: [Color] { [accent, mint, lavender, butter] }
    /// The ink that reads on `candy[i]`: the accent carries its own.
    func candyInk(_ i: Int) -> Color { i % 4 == 0 ? onAccent : userInk }
}

/// A tappable pastel pill. `on` fills it, `dim` fades it once a choice is locked.
struct OptionPill: View {
    let text: String
    var fill: Color
    var ink: Color? = nil
    var on = true
    var dim = false
    var check = false
    var grow = false
    let action: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        Button(action: action) {
            HStack(spacing: theme.spacing.xs) {
                if check { Image(systemName: on ? "checkmark.circle.fill" : "circle") }
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
            .font(theme.font(theme.type.body, .bold))
            .foregroundStyle(on ? ink ?? c.userInk : c.ink)
            .padding(.horizontal, theme.spacing.l)
            .padding(.vertical, theme.spacing.m)
            .frame(maxWidth: grow ? .infinity : nil)
            .background(on ? fill : c.background, in: Capsule())
            .overlay(Capsule().stroke(on ? .clear : c.outline, lineWidth: 1.5))
            .opacity(dim ? 0.4 : 1)
        }
        .buttonStyle(BounceButtonStyle())
    }
}

// MARK: - ask

struct AskPreset: View {
    let c: YLComponent
    @State private var answer: String?
    @Environment(\.ylScope) private var scope
    @Environment(\.ylAnswers) private var answers
    @Environment(\.agentStyle) private var style
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.ylEmit) private var emit

    var body: some View {
        let s = theme.swatch(scheme)
        let options = Array((c.strings("options") ?? ["Yes", "No"]).prefix(4))
        PresetCard {
            PresetTitle(text: c.string("q") ?? "Continue?")
            let buttons = ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                OptionPill(text: o, fill: s.candy[i % 4], ink: s.candyInk(i), on: answer == nil || answer == o,
                           dim: answer != nil && answer != o, grow: true) {
                    guard answer != o else { return }
                    let changed = answer != nil
                    withAnimation(theme.spring) { answer = o }
                    var v: [String: YLValue] = ["answer": .string(o)]
                    if let right = c.quizAnswer { v["correct"] = .bool(right.contains(o)) }
                    emit(c.answer(v, echo: o, changed: changed))
                }
            }
            // Two options sit side by side unless the agent prefers stacked buttons
            // (or a row of up to three).
            let row = switch style["buttons"] {
            case "stack": false
            case "row": options.count <= 3
            default: options.count <= 2
            }
            if row {
                HStack(spacing: theme.spacing.s) { buttons }
            } else {
                VStack(spacing: theme.spacing.s) { buttons }
            }
            if let answer, let right = c.quizAnswer {
                QuizMark(right: right.contains(answer), answer: right, why: c.string("why"))
            }
        }
        .disabled(c.locked)
        // Reopened thread: show the answer the thread already holds.
        .onChange(of: answers(scope, c.ylID), initial: true) { _, v in
            if answer == nil, let a = v?["answer"]?.string { answer = a }
        }
    }
}

// MARK: - choose / pick

/// `choose` (one answer, sent on tap) and `pick` (many, sent with the submit button).
/// Answers stay open: a new tap (or a new submit) sends the new answer with
/// `changed: true`, until the agent locks the component with `+lock`.
struct ChoosePreset: View {
    let c: YLComponent
    let multi: Bool
    @State private var picked: [String] = []
    @State private var typing = false
    @State private var other = ""
    /// What went back to the agent last, or nil before the first answer.
    @State private var sent: [String]?
    @FocusState private var otherFocused: Bool
    @Environment(\.ylScope) private var scope
    @Environment(\.ylAnswers) private var answers
    @Environment(\.agentStyle) private var style
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.ylEmit) private var emit

    var body: some View {
        let s = theme.swatch(scheme)
        let options = c.strings("options") ?? []
        let cap = c.number("max").map { Int($0) }
        PresetCard {
            if let q = c.string("q") { PresetTitle(text: q) }
            if multi, let cap {
                Text("Pick up to \(cap)").font(theme.font(theme.type.caption, .semibold)).foregroundStyle(s.inkSoft)
            }
            let stack = style["buttons"] == "stack"
            let layout = stack ? AnyLayout(VStackLayout(alignment: .leading, spacing: theme.spacing.s))
                               : AnyLayout(FlowLayout(spacing: theme.spacing.s))
            layout {
                ForEach(Array((options + picked.filter { !options.contains($0) }).enumerated()), id: \.offset) { i, o in
                    let on = picked.contains(o)
                    OptionPill(text: o, fill: s.candy[i % 4], ink: s.candyInk(i), on: on, dim: sent != nil && !on, check: multi,
                               grow: stack) {
                        tap(o, cap: cap)
                    }
                }
                if c.flag("other"), !c.locked {
                    OptionPill(text: "Type your own", fill: s.lavender, on: typing) {
                        withAnimation(theme.spring) { typing.toggle() }
                        otherFocused = typing
                    }
                }
            }
            if typing, !c.locked { otherField(s) }
            if let sent, let right = c.quizAnswer {
                QuizMark(right: multi ? Set(right) == Set(sent) : right == sent, answer: right, why: c.string("why"))
            }
            if multi, !c.locked {
                // Done always answers, none included. After a send it reads "Sent"
                // until the picks change again.
                let fresh = sent == nil || picked != sent
                OptionPill(text: sent != nil && !fresh ? "Sent" : c.string("submit") ?? "Done", fill: s.accent, ink: s.onAccent,
                           on: fresh, grow: true) {
                    let changed = sent != nil
                    sent = picked
                    var v: [String: YLValue] = ["picked": .array(picked.map(YLValue.string))]
                    if let right = c.quizAnswer { v["correct"] = .bool(Set(right) == Set(picked)) }
                    emit(c.answer(v, echo: picked.isEmpty ? "None of these" : picked.joined(separator: ", "), changed: changed))
                }
                .disabled(!fresh)
            }
        }
        .disabled(c.locked)
        // Reopened thread: the last answer sent comes back picked, and a new tap is a change.
        .onChange(of: answers(scope, c.ylID), initial: true) { _, v in
            guard sent == nil, let v else { return }
            let back = multi ? v["picked"]?.array?.compactMap(\.string) : v["choice"]?.string.map { [$0] }
            if let back { picked = back; sent = back }
        }
    }

    private func otherField(_ s: Swatch) -> some View {
        HStack(spacing: theme.spacing.s) {
            TextField("Your answer", text: $other)
                .font(theme.font(theme.type.body))
                .foregroundStyle(s.ink)
                .focused($otherFocused)
                .submitLabel(.done)
                .onSubmit(addOther)
                .padding(.horizontal, theme.spacing.l)
                .padding(.vertical, theme.spacing.m)
                .background(s.background, in: Capsule())
                .overlay(Capsule().stroke(s.outline, lineWidth: 1.5))
            Button("Add", systemImage: "arrow.up", action: addOther)
                .labelStyle(.iconOnly)
                .font(theme.font(theme.type.body, .black))
                .foregroundStyle(s.userInk)
                .frame(width: 40, height: 40)
                .background(s.accent, in: Circle())
                .buttonStyle(BounceButtonStyle())
        }
        .transition(.opacity)
    }

    private func tap(_ o: String, cap: Int?) {
        withAnimation(theme.spring) {
            if !multi {
                guard sent != [o] else { return }
                let changed = sent != nil
                picked = [o]
                sent = [o]
                var v: [String: YLValue] = ["choice": .string(o)]
                if let right = c.quizAnswer { v["correct"] = .bool(right.contains(o)) }
                emit(c.answer(v, echo: o, changed: changed))
            } else if let i = picked.firstIndex(of: o) {
                picked.remove(at: i)
            } else if cap.map({ picked.count < $0 }) ?? true {
                picked.append(o)
            }
        }
    }

    private func addOther() {
        let t = other.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        withAnimation(theme.spring) {
            typing = false
            other = ""
            if multi {
                if !picked.contains(t) { picked.append(t) }
            } else {
                let changed = sent != nil
                picked = [t]
                sent = [t]
                emit(c.answer(["choice": .string(t), "other": .bool(true)], echo: t, changed: changed))
            }
        }
    }
}

// MARK: - slide

/// A slider that sends `{value}` on release. It stays movable: every later
/// release with a new value sends again with `changed: true`.
struct SlidePreset: View {
    let c: YLComponent
    @State private var value: Double?
    @State private var sent: Double?
    @Environment(\.ylScope) private var scope
    @Environment(\.ylAnswers) private var answers
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.ylEmit) private var emit

    var body: some View {
        let s = theme.swatch(scheme)
        let lo = c.number("min") ?? 1
        let hi = max(c.number("max") ?? 5, lo + 1)
        let step = max(c.number("step") ?? 1, 0.0001)
        let v = value ?? c.number("value") ?? (lo + ((hi - lo) / 2 / step).rounded() * step)
        PresetCard {
            if let label = c.string("label") { PresetTitle(text: label) }
            Text(YLComponent.format(v) + (c.string("unit").map { " \($0)" } ?? ""))
                .font(theme.font(theme.type.title, .black))
                .foregroundStyle(s.ink)
                .contentTransition(.numericText())
            Slider(value: Binding(get: { v }, set: { value = $0 }), in: lo...hi, step: step) { editing in
                guard !editing, v != sent else { return }
                let changed = sent != nil
                sent = v
                let text = YLComponent.format(v) + (c.string("unit").map { " \($0)" } ?? "")
                emit(c.answer(["value": .number(v)], echo: text, changed: changed))
            }
            .tint(s.accent)
            HStack {
                Text(c.string("lo") ?? YLComponent.format(lo))
                Spacer()
                Text(c.string("hi") ?? YLComponent.format(hi))
            }
            .font(theme.font(theme.type.caption, .semibold))
            .foregroundStyle(s.inkSoft)
        }
        .disabled(c.locked)
        // Reopened thread: the slider sits where it was released.
        .onChange(of: answers(scope, c.ylID), initial: true) { _, v in
            if sent == nil, let n = v?["value"]?.number { value = n; sent = n }
        }
    }
}

// MARK: - list

struct ListPreset: View {
    let c: YLComponent
    @State private var checked: Set<Int> = []
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.ylEmit) private var emit

    var body: some View {
        let s = theme.swatch(scheme)
        let items = c.strings("items") ?? []
        let check = c.flag("check")
        PresetCard {
            if let t = c.string("title") { PresetTitle(text: t) }
            VStack(alignment: .leading, spacing: theme.spacing.s) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    let done = checked.contains(i)
                    let row = HStack(alignment: .firstTextBaseline, spacing: theme.spacing.m) {
                        marker(i, done: done, check: check, s)
                        Text(item)
                            .font(theme.font(theme.type.body, .medium))
                            .foregroundStyle(done ? s.inkSoft : s.ink)
                            .strikethrough(done, color: s.inkSoft)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    if check {
                        Button {
                            withAnimation(theme.spring) {
                                if done { checked.remove(i) } else { checked.insert(i) }
                            }
                            emit(c.event(["item": .string(item), "checked": .bool(!done)]))
                        } label: { row.contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(done ? .isSelected : [])
                    } else {
                        row
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func marker(_ i: Int, done: Bool, check: Bool, _ s: Swatch) -> some View {
        if check {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(theme.font(theme.type.title, .bold))
                .foregroundStyle(done ? s.mint : s.inkSoft)
                .symbolEffect(.bounce, value: done)
        } else if c.flag("num") {
            Text("\(i + 1)")
                .font(theme.font(theme.type.caption, .heavy))
                .foregroundStyle(s.candyInk(i))
                .frame(width: 24, height: 24)
                .background(s.candy[i % 4], in: Circle())
        } else {
            Circle().fill(s.candy[i % 4]).frame(width: 10, height: 10)
        }
    }
}

// MARK: - say, and presets that ship later

struct SayPreset: View {
    let text: String
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        Text(text)
            .font(theme.font(theme.type.body, .medium))
            .foregroundStyle(s.agentInk)
            .padding(.horizontal, theme.spacing.l)
            .padding(.vertical, theme.spacing.m)
            .background(s.agentBubble, in: .rect(cornerRadius: theme.radius.bubble))
            .overlay(RoundedRectangle(cornerRadius: theme.radius.bubble).stroke(s.outline, lineWidth: 1.5))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A preset this build does not draw yet: say so, show the line.
struct LaterPreset: View {
    let c: YLComponent
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        PresetCard {
            Label("\(c.preset) arrives in a later build", systemImage: "sparkles")
                .font(theme.font(theme.type.caption, .bold))
                .foregroundStyle(s.inkSoft)
            Text(c.line)
                .font(.system(size: theme.type.caption, design: .monospaced))
                .foregroundStyle(s.ink)
        }
    }
}

struct YLErrorRow: View {
    let node: YLNode
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        VStack(alignment: .leading, spacing: theme.spacing.xs) {
            Label(node.message ?? "error", systemImage: "exclamationmark.bubble")
                .font(theme.font(theme.type.caption, .bold))
                .foregroundStyle(s.accent)
            Text(node.line)
                .font(.system(size: theme.type.caption, design: .monospaced))
                .foregroundStyle(s.inkSoft)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Layout

/// Wraps children onto new rows like words in a sentence.
struct FlowLayout: Layout {
    var spacing: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * Double(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width = 0.0; var height = 0.0 }

    private func arrange(_ maxWidth: Double, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            let needed = rows[rows.count - 1].items.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > maxWidth, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            var r = rows[rows.count - 1]
            r.width = r.items.isEmpty ? size.width : r.width + spacing + size.width
            r.height = max(r.height, size.height)
            r.items.append(i)
            rows[rows.count - 1] = r
        }
        return rows.filter { !$0.items.isEmpty }
    }
}
