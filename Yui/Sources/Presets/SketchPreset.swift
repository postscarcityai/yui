import SwiftUI
import YuiLines

// Agents draw (YUI-84, the native side of YUI-83; TestFlight feedback on build 96:
// "draw a little window that has certain things crossed out and other things
// highlighted"). `sketch [title] frame=window|phone|bubble before=`, then `row`
// lines: +x struck out, +hi a highlighter swipe, +dim greyed, +button a button,
// no text a filler bar, note= a callout with an arrow to its row. One `after`
// line splits it into a before and after of the same frame. Sends nothing.
// In the chat it sits on a card; on a story page it is the page's picture and
// its rows come on one after another with the page.

/// `sketch` in the chat, and a lone `row` as a one-row sketch. A lone `after` draws nothing.
struct SketchPreset: View {
    let c: YLComponent
    @Environment(\.ylComponents) private var all

    var body: some View {
        if c.preset != "after" {
            PresetCard { SketchDrawing(sketch: c, parts: c.preset == "row" ? [c] : all.members(of: c)) }
        }
    }
}

/// The picture itself: one frame, or a before and after pair stacked (a phone is narrow).
/// With a `phase` (a story page) each part springs on on its own beat.
struct SketchDrawing: View {
    let sketch: YLComponent
    /// The sketch's `row` and `after` members, in line order.
    let parts: [YLComponent]
    var phase: StoryPage.Phase? = nil
    /// The page's beat the drawing starts on.
    var firstBeat = 0
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let s = theme.swatch(scheme)
        let frame = Self.frames.contains(sketch.string("frame") ?? "") ? sketch.string("frame")! : "window"
        let title = sketch.string("title").flatMap { $0.isEmpty ? nil : $0 }
        let cut = parts.firstIndex { $0.preset == "after" }
        let rows = { (list: ArraySlice<YLComponent>) in list.filter { $0.preset == "row" } }
        VStack(alignment: .leading, spacing: theme.spacing.m) {
            // A bubble's title sits above it, once over both sides.
            if frame == "bubble", let title {
                Text(title).font(theme.font(theme.type.caption, .heavy)).foregroundStyle(s.inkSoft)
                    .accessibilityAddTraits(.isHeader)
                    .onBeat(phase, firstBeat, reduceMotion, theme.spring)
            }
            if let cut {
                let before = rows(parts[..<cut]), after = rows(parts[(cut + 1)...])
                side(frame, title, label: sketch.string("before") ?? "Before", good: false, rows: before, beat: firstBeat)
                side(frame, title, label: parts[cut].string("label") ?? "After", good: true, rows: after,
                     beat: firstBeat + before.count + 1)
            } else {
                side(frame, title, label: nil, good: false, rows: rows(parts[...]), beat: firstBeat)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title ?? "Sketch")
    }

    static let frames: Set<String> = ["window", "phone", "bubble"]

    private func side(_ frame: String, _ title: String?, label: String?, good: Bool, rows: [YLComponent], beat: Int) -> some View {
        let s = theme.swatch(scheme)
        let notes = rows.contains { $0.string("note") != nil }
        return VStack(alignment: .leading, spacing: theme.spacing.xs) {
            if let label {
                Text(label.uppercased())
                    .font(theme.font(theme.type.caption - 1, .black))
                    .tracking(0.8)
                    .foregroundStyle(good ? ChartPalette.good(scheme) : s.inkSoft)
                    .accessibilityIdentifier("sketch-label")
                    .onBeat(phase, beat, reduceMotion, theme.spring)
            }
            Grid(alignment: .leading, horizontalSpacing: theme.spacing.s, verticalSpacing: 0) {
                if frame != "bubble" {
                    GridRow {
                        head(frame, title).anchorPreference(key: SketchBox.self, value: .bounds) { [$0] }
                        if notes { Color.clear.frame(width: 0, height: 0) }
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.element.serial) { i, r in
                    GridRow {
                        SketchRow(r: r, i: i, frame: frame)
                            .padding(.horizontal, theme.spacing.m)
                            .padding(.top, i == 0 ? (frame == "bubble" ? theme.spacing.m : theme.spacing.s) : theme.spacing.xs)
                            .padding(.bottom, i == rows.count - 1 ? theme.spacing.m : theme.spacing.xs)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .anchorPreference(key: SketchBox.self, value: .bounds) { [$0] }
                        if notes { note(r) }
                    }
                    .onBeat(phase, beat + 1 + i, reduceMotion, theme.spring)
                }
                if rows.isEmpty {
                    GridRow {
                        Color.clear.frame(height: 28).anchorPreference(key: SketchBox.self, value: .bounds) { [$0] }
                    }
                }
            }
            .backgroundPreferenceValue(SketchBox.self) { anchors in
                GeometryReader { g in
                    let r = anchors.map { g[$0] }.reduce(CGRect.null) { $0.union($1) }
                    if !r.isNull { box(frame).frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY) }
                }
            }
            .onBeat(phase, beat, reduceMotion, theme.spring, whole: true)
        }
        .accessibilityElement(children: .contain)
    }

    /// The frame's top: a window's three dots and title, a phone's notch and title.
    private func head(_ frame: String, _ title: String?) -> some View {
        let s = theme.swatch(scheme)
        return VStack(spacing: theme.spacing.xs) {
            if frame == "phone" {
                Capsule().fill(s.outline).frame(width: 46, height: 6).padding(.top, theme.spacing.s)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 5) {
                if frame == "window" {
                    ForEach([s.accent, s.butter, s.mint].indices, id: \.self) { k in
                        Circle().fill([s.accent, s.butter, s.mint][k]).frame(width: 8, height: 8)
                    }
                    .accessibilityHidden(true)
                }
                if let title {
                    Text(title).font(theme.font(theme.type.caption, .heavy)).foregroundStyle(s.inkSoft)
                        .lineLimit(2)
                        .padding(.leading, frame == "window" ? 4 : 0)
                        .frame(maxWidth: .infinity, alignment: frame == "phone" ? .center : .leading)
                        .accessibilityAddTraits(.isHeader)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, theme.spacing.m)
            .padding(.vertical, frame == "window" ? theme.spacing.s : 0)
            .overlay(alignment: .bottom) {
                if frame == "window" { Rectangle().fill(s.outline).frame(height: 1.5) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func box(_ frame: String) -> some View {
        let s = theme.swatch(scheme)
        switch frame {
        case "bubble":
            let bubble = UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 5, bottomTrailingRadius: 18,
                                                topTrailingRadius: 18)
            bubble.fill(s.agentBubble).overlay(bubble.stroke(s.outline, lineWidth: 1.5))
        case "phone":
            RoundedRectangle(cornerRadius: 26).fill(s.background)
                .overlay(RoundedRectangle(cornerRadius: 26).stroke(s.ink.opacity(0.75), lineWidth: 3))
        default:
            RoundedRectangle(cornerRadius: 12).fill(s.background)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(s.outline, lineWidth: 1.5))
        }
    }

    /// A callout beside the frame, an arrow pointing back at its row.
    @ViewBuilder
    private func note(_ r: YLComponent) -> some View {
        let s = theme.swatch(scheme)
        if let n = r.string("note") {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "arrow.left")
                    .font(theme.font(theme.type.caption - 1, .black))
                    .foregroundStyle(s.accent)
                    .accessibilityHidden(true)
                Text(n).font(theme.font(theme.type.caption, .bold)).foregroundStyle(s.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 118, alignment: .leading)
            .accessibilityHidden(true)
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }
}

/// One drawn line: its text with its marks, a button, or a filler bar.
private struct SketchRow: View {
    let r: YLComponent
    let i: Int
    let frame: String
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        let text = r.string("text").flatMap { $0.isEmpty ? nil : $0 }
        let x = r.flag("x"), hi = r.flag("hi"), dim = r.flag("dim"), button = r.flag("button")
        let ink = frame == "bubble" ? s.agentInk : s.ink
        Group {
            if let text {
                let words = Text(text)
                    .font(theme.font(theme.type.body, button ? .heavy : .semibold))
                    .strikethrough(x, color: s.accent)
                    .foregroundStyle(dim || x ? ink.opacity(0.45) : ink)
                    .fixedSize(horizontal: false, vertical: true)
                if button {
                    words
                        .padding(.horizontal, theme.spacing.l).padding(.vertical, theme.spacing.s)
                        .background(hi ? AnyShapeStyle(marker) : AnyShapeStyle(s.surface), in: Capsule())
                        .overlay(Capsule().stroke(dim ? s.outline : s.ink.opacity(0.6), lineWidth: 1.5))
                        .frame(maxWidth: .infinity)
                } else {
                    words.background(alignment: .leading) { if hi { swipe } }
                }
            } else {
                // Filler: a bar whose width varies with its place, so it reads as text.
                Capsule().fill(s.outline.opacity(dim ? 0.5 : 1))
                    .frame(width: [132, 96, 116, 80][i % 4], height: 10)
                    .padding(.vertical, 5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("sketch-row")
        .accessibilityLabel(text ?? "Blank line")
        .accessibilityValue(marks)
        .accessibilityHint(r.string("note") ?? "")
    }

    /// The marks VoiceOver reads after the words, in a fixed order.
    private var marks: String {
        [r.flag("x") ? "crossed out" : nil, r.flag("hi") ? "highlighted" : nil,
         r.flag("dim") ? "greyed" : nil, r.flag("button") ? "button" : nil].compactMap { $0 }.joined(separator: ", ")
    }

    private var marker: Color {
        scheme == .dark ? Color(red: 1, green: 0.82, blue: 0.25).opacity(0.36) : Color(red: 1, green: 0.8, blue: 0).opacity(0.45)
    }

    /// A highlighter pass, a touch past the words and a little crooked.
    private var swipe: some View {
        RoundedRectangle(cornerRadius: 4).fill(marker)
            .padding(.horizontal, -4).padding(.vertical, -1)
            .rotationEffect(.degrees(-0.8))
    }
}

/// Every frame cell's bounds, so the frame draws once behind all of them.
private struct SketchBox: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) { value += nextValue() }
}

extension View {
    /// A part of a story drawing on its beat; nothing at all outside a story page.
    /// `whole` is the frame itself: it fades in without travelling, the rows travel on it.
    @ViewBuilder
    func onBeat(_ phase: StoryPage.Phase?, _ order: Int, _ reduce: Bool, _ spring: Animation, whole: Bool = false) -> some View {
        if let phase {
            if whole {
                opacity(phase == .on ? 1 : 0)
                    .animation(phase == .on ? spring.delay(0.05 + 0.09 * Double(order)) : .easeIn(duration: 0.16), value: phase)
            } else {
                beat(phase, order, reduce, spring)
            }
        } else {
            self
        }
    }
}
