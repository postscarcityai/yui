import SwiftUI
import YuiLines

/// `timeline [title] mark= fold=`, then `done` / `now` / `next` rows (YUI-65).
/// A vertical track: done rows oldest first, the now marker, the running rows
/// lit up on it, then the queue in order. Older done rows fold behind an
/// "N earlier" button. A lone row (no timeline above it) is a one-row track.
struct TimelinePreset: View {
    let c: YLComponent
    @State private var unfolded = false
    @Environment(\.ylComponents) private var all
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private var lone: Bool { c.preset != "timeline" }
    private var rows: [YLComponent] { lone ? [c] : all.members(of: c) }

    var body: some View {
        let s = theme.swatch(scheme)
        let rows = rows
        let split = rows.firstIndex { $0.preset != "done" } ?? rows.count
        let fold = lone ? 0 : Int(c.number("fold") ?? 5)
        let hidden = !unfolded && fold > 0 && split > fold ? split - fold : 0
        PresetCard {
            if !lone, let t = c.string("title"), !t.isEmpty { PresetTitle(text: t) }
            VStack(alignment: .leading, spacing: 0) {
                if hidden > 0 {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: TimelineRow.gutter)
                        TimelineRail(color: s.outline).frame(width: TimelineRow.railWidth)
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
                    }
                }
                ForEach(rows[hidden..<split]) { TimelineRow(r: $0) }
                if !lone { NowMarker(label: c.string("mark") ?? "Now", last: split == rows.count) }
                ForEach(rows[split...]) { TimelineRow(r: $0) }
            }
        }
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
        if let link {
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
            dot(s, state)
                .frame(width: Self.railWidth)
                .frame(maxHeight: .infinity, alignment: .top)
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
