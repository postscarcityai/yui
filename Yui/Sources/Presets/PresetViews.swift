import SwiftUI
import YuiLines

extension EnvironmentValues {
    @Entry var ylEmit = YLEmit()
}

/// Renders one YL component. Every look comes from `YuiTheme` tokens.
struct PresetView: View {
    let component: YLComponent

    var body: some View {
        switch component.preset {
        case "ask": AskPreset(c: component)
        case "choose": ChoosePreset(c: component, multi: false)
        case "pick": ChoosePreset(c: component, multi: true)
        case "form": FormPreset(c: component)
        case "list": ListPreset(c: component)
        case "timer": TimerPreset(c: component)
        case "say": SayPreset(text: component.string("text") ?? "")
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
                    guard answer == nil else { return }
                    withAnimation(theme.spring) { answer = o }
                    emit(c.event(["answer": .string(o)], echo: o))
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
        }
        .disabled(answer != nil)
    }
}

// MARK: - choose / pick

/// `choose` (one answer, sent on tap) and `pick` (many, sent with the submit button).
struct ChoosePreset: View {
    let c: YLComponent
    let multi: Bool
    @State private var picked: [String] = []
    @State private var typing = false
    @State private var other = ""
    @State private var sent = false
    @FocusState private var otherFocused: Bool
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
                    OptionPill(text: o, fill: s.candy[i % 4], ink: s.candyInk(i), on: on, dim: sent && !on, check: multi,
                               grow: stack) {
                        tap(o, cap: cap)
                    }
                }
                if c.flag("other"), !sent {
                    OptionPill(text: "Type your own", fill: s.lavender, on: typing) {
                        withAnimation(theme.spring) { typing.toggle() }
                        otherFocused = typing
                    }
                }
            }
            if typing, !sent { otherField(s) }
            if multi, !sent {
                OptionPill(text: c.string("submit") ?? "Done", fill: s.accent, ink: s.onAccent, on: !picked.isEmpty, grow: true) {
                    sent = true
                    emit(c.event(["picked": .array(picked.map(YLValue.string))], echo: picked.joined(separator: ", ")))
                }
                .disabled(picked.isEmpty)
            }
        }
        .disabled(sent)
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
                picked = [o]
                sent = true
                emit(c.event(["choice": .string(o)], echo: o))
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
                picked = [t]
                sent = true
                emit(c.event(["choice": .string(t), "other": .bool(true)], echo: t))
            }
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
