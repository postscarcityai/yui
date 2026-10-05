import SwiftUI
import YuiLines

// Agents draw (YUI-84, the native side of YUI-83; TestFlight feedback on build 96:
// "draw a little window that has certain things crossed out and other things
// highlighted"). `sketch [title] frame=window|phone|bubble before=`, then `row`
// lines: +x struck out, +hi lit, +dim greyed, +button a button, no text a filler
// bar, note= a callout. One `after` line splits it into a before and after of the
// same frame. Sends nothing.
//
// Drawn as a blueprint (feedback AOGmS_cF, ALkikjiu, ACHcboRE: "this is not good
// graphic design", "re-create wireframes of these UI"): thin lines that trace
// themselves on, no box inside a box. A before and after sit side by side, the
// before dashed and crossed, the after lit and ticked, so the change reads at a
// glance. Callouts are numbered, as on a drawing, with the words in a key under
// the frame, so a row keeps the frame's whole width.

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

/// The picture itself: one frame, or a before and after pair side by side.
/// With a `phase` (a story page) it draws on when the page arrives.
struct SketchDrawing: View {
    let sketch: YLComponent
    /// The sketch's `row` and `after` members, in line order.
    let parts: [YLComponent]
    var phase: StoryPage.Phase? = nil
    /// The page's beat the drawing starts on.
    var firstBeat = 0
    /// The lines have traced on. A sketch outside a story page draws on when it appears.
    @State private var appeared = false
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    static let frames: Set<String> = ["window", "phone", "bubble"]

    private var on: Bool { reduceMotion || (phase.map { $0 == .on } ?? appeared) }

    var body: some View {
        let s = theme.swatch(scheme)
        let frame = Self.frames.contains(sketch.string("frame") ?? "") ? sketch.string("frame")! : "window"
        let title = sketch.string("title").flatMap { $0.isEmpty ? nil : $0 }
        let cut = parts.firstIndex { $0.preset == "after" }
        let rows = { (list: ArraySlice<YLComponent>) in list.filter { $0.preset == "row" } }
        let before = rows(cut.map { parts[..<$0] } ?? parts[...])
        let after = cut.map { rows(parts[($0 + 1)...]) } ?? []
        // Callouts count across both sides, in line order.
        let numbers = Self.numbers(before + after)
        VStack(alignment: .leading, spacing: theme.spacing.m) {
            if let title {
                Text(title.uppercased())
                    .font(theme.font(theme.type.caption - 2, .heavy))
                    .tracking(1.4)
                    .foregroundStyle(s.inkSoft)
                    .accessibilityAddTraits(.isHeader)
                    .blueprintStep(on, 0, reduceMotion)
            }
            if let cut {
                // Side by side: the eye compares across. Large type stacks them so the words keep their room.
                let pair = Group {
                    side(frame, .before(sketch.string("before") ?? "Before"), before, numbers, step: 1)
                    side(frame, .after(parts[cut].string("label") ?? "After"), after, numbers, step: before.count + 3)
                }
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: theme.spacing.l) { pair }
                } else {
                    HStack(alignment: .top, spacing: theme.spacing.m) { pair }
                }
            } else {
                side(frame, .alone, before, numbers, step: 1)
                    .frame(maxWidth: 340, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { appeared = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title ?? "Sketch")
    }

    /// Which side of a pair a frame is.
    enum Side: Equatable {
        case alone, before(String), after(String)
        var label: String? {
            switch self {
            case .alone: nil
            case .before(let l), .after(let l): l
            }
        }
        var isAfter: Bool { if case .after = self { true } else { false } }
        var isBefore: Bool { if case .before = self { true } else { false } }
    }

    /// Each noted row's number, by its serial.
    static func numbers(_ rows: [YLComponent]) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for r in rows where r.string("note")?.isEmpty == false { out[r.serial] = out.count + 1 }
        return out
    }

    private func side(_ frame: String, _ side: Side, _ rows: [YLComponent], _ numbers: [Int: Int], step: Int) -> some View {
        let s = theme.swatch(scheme)
        let good = ChartPalette.good(scheme), bad = ChartPalette.bad(scheme)
        let line: Color = switch side {
        case .alone: s.ink.opacity(0.6)
        case .before: s.ink.opacity(0.32)
        case .after: s.accent
        }
        let noted = rows.filter { numbers[$0.serial] != nil }
        return VStack(alignment: .leading, spacing: theme.spacing.s) {
            if let label = side.label {
                HStack(spacing: 6) {
                    Image(systemName: side.isAfter ? "checkmark" : "xmark")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(s.background)
                        .frame(width: 17, height: 17)
                        .background(side.isAfter ? good : bad, in: Circle())
                        .scaleEffect(on ? 1 : 0.2)
                        .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.5).delay(Blueprint.delay(step + rows.count + 1)), value: on)
                        .accessibilityHidden(true)
                    Text(label.uppercased())
                        .font(theme.font(theme.type.caption - 2, .heavy))
                        .tracking(1.4)
                        .foregroundStyle(side.isAfter ? good : s.inkSoft)
                        .accessibilityIdentifier("sketch-label")
                }
                .blueprintStep(on, step, reduceMotion)
            }
            VStack(alignment: .leading, spacing: theme.spacing.s) {
                if frame == "window" {
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { _ in Circle().stroke(line, lineWidth: 1).frame(width: 6, height: 6) }
                    }
                    .accessibilityHidden(true)
                } else if frame == "phone" {
                    // A phone reads as a phone before a word is read (YUI-267, direction A's best idea, kept
                    // in the blueprint's own line): the time, the island, the bars and the battery.
                    ZStack {
                        Capsule().stroke(line, lineWidth: 1).frame(width: 34, height: 7)
                        HStack(spacing: 2) {
                            Text("9:41").font(.system(size: 8, weight: .heavy, design: .rounded)).foregroundStyle(line)
                            Spacer(minLength: 0)
                            ForEach(0..<3, id: \.self) { i in
                                Capsule().fill(line).frame(width: 2, height: 3 + CGFloat(i) * 2)
                            }
                            RoundedRectangle(cornerRadius: 2).stroke(line, lineWidth: 1).frame(width: 12, height: 6)
                                .padding(.leading, 2)
                        }
                    }
                    .accessibilityHidden(true)
                }
                ForEach(Array(rows.enumerated()), id: \.element.serial) { i, r in
                    SketchRow(r: r, i: i, frame: frame, number: numbers[r.serial], faded: side.isBefore,
                              on: on, step: step + 1 + i)
                        .blueprintStep(on, step + 1 + i, reduceMotion)
                }
                if rows.isEmpty { Color.clear.frame(height: 28) }
                if frame == "phone" {
                    // Its home bar.
                    Capsule().fill(line.opacity(0.75)).frame(width: 40, height: 3)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, theme.spacing.m)
            .padding(.top, frame == "bubble" ? theme.spacing.m : theme.spacing.s + 2)
            .padding(.bottom, frame == "phone" ? theme.spacing.s : theme.spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let shape = Blueprint.frame(frame)
                ZStack {
                    // The after is lit from behind, so it is the one the eye lands on.
                    if side.isAfter {
                        shape.fill(s.accent.opacity(scheme == .dark ? 0.10 : 0.07))
                            .opacity(on ? 1 : 0)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.5).delay(Blueprint.delay(step) + 0.35), value: on)
                    }
                    shape
                        .trim(from: 0, to: on ? 1 : 0)
                        .stroke(line, style: StrokeStyle(lineWidth: side.isAfter ? 1.75 : side.isBefore ? 1.25 : 1.5,
                                                         lineCap: .round, dash: side.isBefore ? [5, 5] : []))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.7).delay(Blueprint.delay(step)), value: on)
                }
                .shadow(color: side.isAfter ? s.accent.opacity(0.35) : .clear, radius: 14)
            }
            // The key: each numbered callout's words, under its frame.
            if !noted.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(noted, id: \.serial) { r in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Blueprint.Number(n: numbers[r.serial] ?? 0, color: r.flag("x") ? bad : s.accent, ink: s.background)
                            Text(r.string("note") ?? "")
                                .font(theme.font(theme.type.caption, .semibold))
                                .foregroundStyle(s.ink.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 2)
                .accessibilityHidden(true)
                .blueprintStep(on, step + rows.count + 1, reduceMotion)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }
}

/// One drawn line: its text with its marks, a button, or a filler bar.
private struct SketchRow: View {
    let r: YLComponent
    let i: Int
    let frame: String
    /// Its callout's number, drawn at the row's end.
    var number: Int?
    /// On the before side of a pair: everything sits back.
    var faded = false
    var on = true
    var step = 0
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let s = theme.swatch(scheme)
        let text = r.string("text").flatMap { $0.isEmpty ? nil : $0 }
        let x = r.flag("x"), hi = r.flag("hi"), dim = r.flag("dim"), button = r.flag("button")
        let bad = ChartPalette.bad(scheme)
        let ink = (dim || x ? s.ink.opacity(0.5) : s.ink).opacity(faded && !hi ? 0.8 : 1)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Group {
                if let text {
                    // Struck through on every line it wraps to.
                    let words = Text(text)
                        .font(theme.font(theme.type.caption + 2, button || hi ? .bold : .medium))
                        .strikethrough(x && !button, color: bad)
                        .foregroundStyle(ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if button {
                        words
                            .padding(.horizontal, theme.spacing.m).padding(.vertical, 6)
                            .background(hi ? s.accent.opacity(0.22) : .clear, in: Capsule())
                            .overlay(Capsule().stroke(hi ? s.accent : s.ink.opacity(dim ? 0.25 : 0.5), lineWidth: 1.25))
                            .overlay { if x { strike(bad) } }
                            .frame(maxWidth: .infinity)
                    } else if hi {
                        // Lit: a bar of the agent's color down its edge, a wash behind.
                        words
                            .padding(.leading, 9).padding(.trailing, 6).padding(.vertical, 4)
                            .background(s.accent.opacity(scheme == .dark ? 0.20 : 0.14), in: .rect(cornerRadius: 6))
                            .overlay(alignment: .leading) {
                                Capsule().fill(s.accent).frame(width: 3).padding(.vertical, 3)
                            }
                    } else {
                        words
                    }
                } else {
                    // Filler: a bar whose width varies with its place, so it reads as text.
                    Capsule().fill(s.ink.opacity(dim ? 0.10 : 0.18))
                        .frame(width: [112, 84, 100, 68][i % 4], height: 7)
                        .padding(.vertical, 4)
                }
            }
            if let number, !button {
                Spacer(minLength: 0)
                Blueprint.Number(n: number, color: x ? bad : s.accent, ink: s.background)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("sketch-row")
        .accessibilityLabel(text ?? "Blank line")
        .accessibilityValue(marks)
        .accessibilityHint(r.string("note") ?? "")
    }

    /// Struck out: one line drawn through the words, left to right, after they land.
    private func strike(_ color: Color) -> some View {
        GeometryReader { g in
            Path { p in
                p.move(to: CGPoint(x: -2, y: g.size.height * 0.56))
                p.addLine(to: CGPoint(x: g.size.width + 2, y: g.size.height * 0.46))
            }
            .trim(from: 0, to: on ? 1 : 0)
            .stroke(color, style: StrokeStyle(lineWidth: 1.75, lineCap: .round))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.35).delay(Blueprint.delay(step) + 0.3), value: on)
        }
        .accessibilityHidden(true)
    }

    /// The marks VoiceOver reads after the words, in a fixed order.
    private var marks: String {
        [r.flag("x") ? "crossed out" : nil, r.flag("hi") ? "highlighted" : nil,
         r.flag("dim") ? "greyed" : nil, r.flag("button") ? "button" : nil].compactMap { $0 }.joined(separator: ", ")
    }
}

/// What every blueprint drawing shares: its frames, its numbered callouts and its timing.
enum Blueprint {
    /// Parts come on in line order, a beat apart.
    static func delay(_ step: Int) -> Double { 0.08 + 0.11 * Double(step) }

    /// A frame's outline: a phone's deep corners, a window's shallow ones, a bubble's tail corner.
    static func frame(_ kind: String) -> AnyShape {
        switch kind {
        case "phone": AnyShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        case "bubble": AnyShape(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 5, bottomTrailingRadius: 18,
                                                       topTrailingRadius: 18, style: .continuous))
        default: AnyShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    /// A callout's number in a small disc, as on a drawing.
    struct Number: View {
        let n: Int
        let color: Color
        let ink: Color

        var body: some View {
            Text("\(n)")
                .font(.system(size: 10, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(ink)
                .frame(width: 16, height: 16)
                .background(color, in: Circle())
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// One part of a blueprint coming on at its step: it rises a little as it fades in. Reduce Motion: it is just there.
    func blueprintStep(_ on: Bool, _ step: Int, _ reduce: Bool) -> some View {
        opacity(on ? 1 : 0)
            .offset(y: on || reduce ? 0 : 8)
            .animation(reduce ? nil : .spring(duration: 0.45, bounce: 0.18).delay(Blueprint.delay(step)), value: on)
    }

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
