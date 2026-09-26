import SwiftUI
import YuiLines

/// `timeline [title] mark= fold= [+reorder] [board=]`, then `done` / `now` / `next` rows (YUI-65).
/// A vertical track: done rows oldest first, the now marker, the running rows
/// lit up on it, then the queue in order. Older done rows fold behind an
/// "N earlier" button. A lone row (no timeline above it) is a one-row track.
/// `+reorder` (YUI-66): Edit order gives each queued row a drag handle; Save
/// sends `{order: [key...], board}` once. Done and running rows never move.
struct TimelinePreset: View {
    let c: YLComponent
    @State private var unfolded = false
    @State private var draft: [Int]?       // the queue's serials while editing
    @State private var savedOrder: [Int]?  // the queue as last saved
    @State private var dragging: Int?
    @State private var dragY: CGFloat = 0
    @State private var anchor: CGFloat = 0
    @State private var heights: [Int: CGFloat] = [:]
    @Environment(\.ylComponents) private var all
    @Environment(\.ylEmit) private var emit
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private var lone: Bool { c.preset != "timeline" }
    private var rows: [YLComponent] { lone ? [c] : all.members(of: c) }
    private var reorder: Bool { !lone && c.flag("reorder") && !c.locked }

    var body: some View {
        let s = theme.swatch(scheme)
        let rows = rows
        // The now marker: moves when a patch re-kinds a row (YUI-111).
        let split = markAt(rows.map(\.preset))
        let fold = lone ? 0 : Int(c.number("fold") ?? 5)
        let hidden = !unfolded && fold > 0 && split > fold ? split - fold : 0
        let tail = Array(rows[split...])
        // With +reorder the queue is drawn in its own order under the running rows.
        let queue = reorder ? tail.filter { $0.preset == "next" } : []
        let fixed = reorder ? tail.filter { $0.preset != "next" } : tail
        let order = ordered(queue)
        let byID = Dictionary(uniqueKeysWithValues: queue.map { ($0.serial, $0) })
        let editing = draft != nil
        PresetCard {
            let title = lone ? nil : c.string("title").flatMap { $0.isEmpty ? nil : $0 }
            if title != nil || (queue.count > 1 && !editing) {
                HStack(alignment: .firstTextBaseline, spacing: theme.spacing.s) {
                    if let title { PresetTitle(text: title) }
                    Spacer(minLength: 0)
                    if queue.count > 1, !editing {
                        Button {
                            withAnimation(.snappy) { draft = order }
                        } label: {
                            Label("Edit order", systemImage: "arrow.up.arrow.down")
                                .font(theme.font(theme.type.caption, .bold)).foregroundStyle(s.ink)
                                .padding(.horizontal, theme.spacing.m).frame(minHeight: 36)
                                .overlay(Capsule().stroke(s.outline, lineWidth: 1.5))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("timeline-edit-order")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                if hidden > 0 {
                    Button { withAnimation(.snappy) { unfolded = true } } label: {
                        Text("\(hidden) earlier")
                            .font(theme.font(theme.type.caption, .bold)).foregroundStyle(s.inkSoft)
                            .padding(.horizontal, theme.spacing.m).frame(minHeight: 36)
                            .overlay(Capsule().stroke(s.outline, lineWidth: 1.5))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("timeline-earlier")
                    .padding(.vertical, 4)
                    .padding(.leading, TimelineRow.gutter + TimelineRow.railWidth)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The rail as a background, like a row's, so it never stretches the stack.
                    .background(alignment: .leading) {
                        TimelineRail(color: s.outline).offset(x: TimelineRow.gutter + TimelineRow.railWidth / 2 - 1)
                    }
                }
                ForEach(rows[hidden..<split]) { TimelineRow(r: $0) }
                if !lone { NowMarker(label: c.string("mark") ?? "Now", last: split == rows.count) }
                ForEach(fixed) { TimelineRow(r: $0) }
                ForEach(Array(order.enumerated()), id: \.element) { i, serial in
                    if let r = byID[serial] { queued(r, at: i, of: order, editing: editing, s) }
                }
            }
            .sensoryFeedback(.selection, trigger: draft)
            if editing {
                HStack(spacing: theme.spacing.s) {
                    OptionPill(text: "Cancel", fill: s.background, on: false, grow: true) {
                        withAnimation(.snappy) { draft = nil; dragging = nil; dragY = 0 }
                    }
                    .accessibilityIdentifier("timeline-cancel-order")
                    let moved = order != (savedOrder.map { ordered(queue, $0) } ?? queue.map(\.serial))
                    OptionPill(text: "Save order", fill: s.accent, ink: s.onAccent, dim: !moved, grow: true) {
                        save(order, byID)
                    }
                    .disabled(!moved)
                    .accessibilityIdentifier("timeline-save-order")
                }
                .padding(.top, theme.spacing.s)
                .transition(.opacity)
            }
        }
    }

    /// The queue's serials: the draft while editing, else the last save, else line order.
    /// Rows a later patch added go at the end; rows that left drop out.
    private func ordered(_ queue: [YLComponent], _ from: [Int]? = nil) -> [Int] {
        let ids = queue.map(\.serial)
        let base = (from ?? draft ?? savedOrder ?? ids).filter(ids.contains)
        return base + ids.filter { !base.contains($0) }
    }

    @ViewBuilder
    private func queued(_ r: YLComponent, at i: Int, of order: [Int], editing: Bool, _ s: Swatch) -> some View {
        let lifted = dragging == r.serial
        HStack(spacing: 0) {
            TimelineRow(r: r, editing: editing)
            if editing {
                Image(systemName: "line.3.horizontal")
                    .font(.body.weight(.bold)).foregroundStyle(lifted ? s.accent : s.inkSoft)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .highPriorityGesture(drag(r.serial))
                    .accessibilityElement()
                    .accessibilityLabel("Reorder \(r.string("tag") ?? r.string("text") ?? "")")
                    .accessibilityHint("Drag up or down, or use Move up and Move down")
                    .accessibilityIdentifier("timeline-grip")
                    .accessibilityActions {
                        if i > 0 { Button("Move up") { move(r.serial, by: -1) } }
                        if i < order.count - 1 { Button("Move down") { move(r.serial, by: 1) } }
                    }
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[r.serial] = $0 }
        .background {
            if lifted {
                RoundedRectangle(cornerRadius: theme.radius.bubble / 1.5).fill(s.surface)
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            }
        }
        .scaleEffect(lifted ? 1.02 : 1)
        .offset(y: lifted ? dragY : 0)
        .zIndex(lifted ? 1 : 0)
    }

    /// Drag the handle: the row follows the finger; past half a neighbour's height they swap.
    private func drag(_ serial: Int) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { v in
                guard var o = draft, let i = o.firstIndex(of: serial) else { return }
                if dragging != serial { dragging = serial; anchor = v.startLocation.y }
                let dy = v.location.y - anchor
                let h = { (id: Int) in heights[id] ?? 44 }
                if dy > 0, i < o.count - 1, dy > h(o[i + 1]) / 2 {
                    anchor += h(o[i + 1]); o.swapAt(i, i + 1)
                } else if dy < 0, i > 0, -dy > h(o[i - 1]) / 2 {
                    anchor -= h(o[i - 1]); o.swapAt(i, i - 1)
                }
                if o != draft { withAnimation(.snappy(duration: 0.2)) { draft = o } }
                dragY = v.location.y - anchor
            }
            .onEnded { _ in withAnimation(.snappy) { dragging = nil; dragY = 0 } }
    }

    private func move(_ serial: Int, by step: Int) {
        guard var o = draft, let i = o.firstIndex(of: serial), o.indices.contains(i + step) else { return }
        o.swapAt(i, i + step)
        withAnimation(.snappy) { draft = o }
    }

    private func save(_ order: [Int], _ byID: [Int: YLComponent]) {
        let rows = order.compactMap { byID[$0] }
        let keys = rows.map { $0.string("key") ?? $0.string("tag") ?? $0.string("text") ?? "" }
        var value: [String: YLValue] = ["order": .array(keys.map { .string($0) })]
        if let board = c.string("board"), !board.isEmpty { value["board"] = .string(board) }
        let names = rows.map { $0.string("tag") ?? $0.string("text") ?? "" }
        emit(c.event(value, echo: "New order: " + names.joined(separator: ", ")))
        withAnimation(.snappy) { savedOrder = order; draft = nil }
    }
}

/// The track's line, drawn behind each row's dot so rows join up.
private struct TimelineRail: View {
    let color: Color
    var body: some View {
        Rectangle().fill(color).frame(width: 2).frame(maxHeight: .infinity)
    }
}

/// The line across the track between what happened and what is running or queued.
private struct NowMarker: View {
    let label: String
    let last: Bool
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        HStack(spacing: theme.spacing.s) {
            Text(label.uppercased())
                .font(theme.font(theme.type.caption, .heavy)).tracking(0.6)
                .foregroundStyle(s.accent)
                .frame(width: TimelineRow.gutter + TimelineRow.railWidth / 2, alignment: .trailing)
            Capsule().fill(s.accent).frame(height: 2)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("timeline-now")
    }
}

/// One row: when in the gutter, a dot on the rail, the tag, text and sub.
/// A row with an https `url` opens it in Safari and sends nothing to the chat.
struct TimelineRow: View {
    let r: YLComponent
    /// Edit order mode: a link row stops opening Safari so a drag never leaves the app.
    var editing = false
    static let gutter: CGFloat = 58
    static let railWidth: CGFloat = 26
    @State private var pulse = false
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private var link: URL? {
        guard let raw = r.string("url"), let u = URL(string: raw), u.scheme?.lowercased() == "https" else { return nil }
        return u
    }

    var body: some View {
        if let link, !editing {
            Button { openURL(link) } label: { row.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityHint("Opens in Safari")
        } else {
            row
        }
    }

    private var row: some View {
        let s = theme.swatch(scheme)
        let state = r.preset
        return HStack(alignment: .top, spacing: 0) {
            Text(r.string("at") ?? "")
                .font(theme.font(theme.type.caption, .bold).monospacedDigit())
                .foregroundStyle(s.inkSoft)
                .lineLimit(1).minimumScaleFactor(0.7)
                .multilineTextAlignment(.trailing)
                .frame(width: Self.gutter - 8, alignment: .trailing)
                .padding(.trailing, 8).padding(.top, 2)
            // No maxHeight here: a flexible dot let rows soak up a tall stage (YUI-112).
            dot(s, state)
                .frame(width: Self.railWidth)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let tag = r.string("tag") {
                        Text(tag)
                            .font(theme.font(theme.type.caption - 1, .heavy))
                            .foregroundStyle(state == "now" ? s.onAccent : s.inkSoft)
                            .padding(.horizontal, 7).padding(.vertical, 1)
                            .background(state == "now" ? s.accent : s.outline.opacity(0.6), in: Capsule())
                    }
                    Text(r.string("text") ?? "")
                        .font(theme.font(theme.type.body, state == "now" ? .heavy : state == "done" ? .regular : .semibold))
                        .foregroundStyle(state == "done" ? s.inkSoft : s.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if link != nil {
                        Image(systemName: "arrow.up.right").font(.caption.weight(.heavy)).foregroundStyle(s.accent)
                    }
                }
                if let sub = r.string("sub") {
                    Text(sub).font(theme.font(theme.type.caption)).foregroundStyle(s.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7)
        .padding(.trailing, 6)
        // The rail runs the full row height, padding included, so rows join up.
        .background(alignment: .leading) {
            TimelineRail(color: s.outline).offset(x: Self.gutter + Self.railWidth / 2 - 1)
        }
        .background {
            if state == "now" {
                RoundedRectangle(cornerRadius: theme.radius.bubble / 1.5).fill(s.accent.opacity(0.14))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibility)
        .accessibilityIdentifier("timeline-\(state)")
    }

    private var accessibility: String {
        let what = ["done": "Done", "now": "Running now", "next": "Queued"][r.preset] ?? ""
        return [what, r.string("at"), r.string("tag"), r.string("text"), r.string("sub")]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    @ViewBuilder private func dot(_ s: Swatch, _ state: String) -> some View {
        switch state {
        case "done":
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .black)).foregroundStyle(s.userInk)
                .frame(width: 18, height: 18).background(s.mint, in: Circle())
                .padding(.top, 1)
        case "now":
            ZStack {
                Circle().stroke(s.accent.opacity(0.4), lineWidth: 3)
                    .frame(width: 18, height: 18)
                    .scaleEffect(pulse ? 1.7 : 1).opacity(pulse ? 0 : 1)
                Circle().fill(s.accent).frame(width: 16, height: 16)
            }
            .padding(.top, 2)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
            }
        default:
            Circle().fill(s.surface).overlay(Circle().stroke(s.inkSoft.opacity(0.6), lineWidth: 2))
                .frame(width: 14, height: 14)
                .padding(.top, 4)
        }
    }
}
