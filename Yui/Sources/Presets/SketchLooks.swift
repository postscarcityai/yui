import SwiftUI
import YuiLines

// Drawings that look designed (YUI-267, TestFlight notes Oct 1: "this is not good
// graphic design", "deploy the Apple liquid glass effect", "animate that, re-create
// the wireframes"). Three looks for the same `sketch`, behind `-yuiSketchLook A|B|C`
// until one is picked: A glass cards with a headline and checkmark rows, B animated
// phone wireframes with a tap ripple and a callout, C a beginning, middle and end
// strip. Same rows, same flags (+x +hi +dim +button note=): only the drawing changes.

enum SketchLook: String {
    case classic, glass = "A", wire = "B", strip = "C"

    /// `-yuiSketchLook A` (a launch argument lands in UserDefaults).
    static var current: SketchLook {
        SketchLook(rawValue: UserDefaults.standard.string(forKey: "yuiSketchLook") ?? "") ?? .classic
    }
}

/// One drawn line, read once.
struct SketchLine: Identifiable {
    let id: Int
    let text: String?
    let x: Bool, hi: Bool, dim: Bool, button: Bool
    let note: String?

    init(_ c: YLComponent, id: Int) {
        self.id = id
        text = c.string("text").flatMap { $0.isEmpty ? nil : $0 }
        x = c.flag("x"); hi = c.flag("hi"); dim = c.flag("dim"); button = c.flag("button")
        note = c.string("note")
    }
}

/// One side of a sketch: its label and its lines.
struct SketchSide: Identifiable {
    let id: Int
    let label: String?
    let good: Bool
    let lines: [SketchLine]
}

extension SketchSide {
    static func sides(sketch: YLComponent, parts: [YLComponent]) -> [SketchSide] {
        func lines(_ list: ArraySlice<YLComponent>, from: Int) -> [SketchLine] {
            list.filter { $0.preset == "row" }.enumerated().map { SketchLine($0.element, id: from + $0.offset) }
        }
        if let cut = parts.firstIndex(where: { $0.preset == "after" }) {
            return [SketchSide(id: 0, label: sketch.string("before") ?? "Before", good: false, lines: lines(parts[..<cut], from: 0)),
                    SketchSide(id: 1, label: parts[cut].string("label") ?? "After", good: true, lines: lines(parts[(cut + 1)...], from: 100))]
        }
        return [SketchSide(id: 0, label: nil, good: false, lines: lines(parts[...], from: 0))]
    }
}

/// The entry point `SketchDrawing` calls when a look is chosen.
struct SketchLookView: View {
    let look: SketchLook
    let sketch: YLComponent
    let parts: [YLComponent]
    @Environment(\.yuiTheme) private var theme

    var body: some View {
        let sides = SketchSide.sides(sketch: sketch, parts: parts)
        let title = sketch.string("title").flatMap { $0.isEmpty ? nil : $0 }
        VStack(alignment: .leading, spacing: theme.spacing.m) {
            switch look {
            case .glass: GlassSketch(title: title, sides: sides)
            case .wire: WireSketch(title: title, sides: sides)
            case .strip: StripSketch(title: title, sides: sides)
            case .classic: EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title ?? "Sketch")
    }
}

// MARK: shared bits

private struct Ink {
    let s: Swatch
    let scheme: ColorScheme
    var good: Color { ChartPalette.good(scheme) }
    var bad: Color { Color(red: 0.95, green: 0.38, blue: 0.42) }
    var marker: Color { scheme == .dark ? Color(red: 1, green: 0.82, blue: 0.25) : Color(red: 1, green: 0.74, blue: 0) }
}

/// The mark in front of a line: a check when it is the point, a cross when it is gone.
private struct Mark: View {
    let line: SketchLine
    let ink: Ink
    var size: CGFloat = 20
    var body: some View {
        Group {
            if line.x { Image(systemName: "xmark.circle.fill").foregroundStyle(ink.bad) }
            else if line.hi { Image(systemName: "checkmark.circle.fill").foregroundStyle(ink.good) }
            else if line.button { Image(systemName: "hand.tap.fill").foregroundStyle(ink.s.inkSoft) }
            else { Image(systemName: "circle.fill").font(.system(size: size * 0.3)).foregroundStyle(ink.s.outline) }
        }
        .font(.system(size: size, weight: .bold))
        .frame(width: size + 4)
        .accessibilityHidden(true)
    }
}

private func lineLabel(_ l: SketchLine) -> String {
    [l.text ?? "Blank line", l.x ? "crossed out" : nil, l.hi ? "highlighted" : nil, l.note.map { "Note: \($0)" }]
        .compactMap { $0 }.joined(separator: ", ")
}

/// A line fades and rises in on its own beat, once.
private struct Rise: ViewModifier {
    let order: Int
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.yuiTheme) private var theme
    func body(content: Content) -> some View {
        content
            .opacity(on || reduce ? 1 : 0)
            .offset(y: on || reduce ? 0 : 10)
            .onAppear {
                guard !reduce else { on = true; return }
                withAnimation(theme.spring.delay(0.08 * Double(order))) { on = true }
            }
    }
}

private extension View {
    func rise(_ order: Int) -> some View { modifier(Rise(order: order)) }
}

// MARK: A, glass cards with a headline and checkmark rows

struct GlassSketch: View {
    let title: String?
    let sides: [SketchSide]
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = Ink(s: theme.swatch(scheme), scheme: scheme)
        VStack(alignment: .leading, spacing: theme.spacing.m) {
            if let title {
                Text(title).font(theme.font(theme.type.title, .black)).foregroundStyle(ink.s.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(sides) { side in card(side, ink) }
        }
    }

    private func card(_ side: SketchSide, _ ink: Ink) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.s) {
            if let label = side.label {
                HStack(spacing: 6) {
                    Image(systemName: side.good ? "checkmark.seal.fill" : "clock.arrow.circlepath")
                    Text(label.uppercased()).tracking(0.8)
                }
                .font(theme.font(theme.type.caption, .black))
                .foregroundStyle(side.good ? ink.good : ink.s.inkSoft)
                .accessibilityIdentifier("sketch-label")
            }
            ForEach(Array(side.lines.enumerated()), id: \.element.id) { i, l in
                row(l, ink).rise(i + (side.good ? 3 : 0))
            }
        }
        .padding(theme.spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(side.good ? ink.good.opacity(0.14) : nil), in: .rect(cornerRadius: 24))
        .opacity(side.good || side.label == nil ? 1 : 0.9)
    }

    private func row(_ l: SketchLine, _ ink: Ink) -> some View {
        HStack(alignment: .top, spacing: theme.spacing.s) {
            Mark(line: l, ink: ink)
            VStack(alignment: .leading, spacing: 2) {
                if let text = l.text {
                    Text(text)
                        .font(theme.font(theme.type.body, l.hi ? .heavy : .semibold))
                        .strikethrough(l.x, color: ink.bad)
                        .foregroundStyle(l.dim || l.x ? ink.s.ink.opacity(0.5) : ink.s.ink)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Capsule().fill(ink.s.outline).frame(width: 110, height: 9).padding(.vertical, 6)
                }
                if let n = l.note {
                    Text(n).font(theme.font(theme.type.caption, .bold))
                        .foregroundStyle(l.x ? ink.bad : (l.hi ? ink.good : ink.s.inkSoft))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, l.button ? theme.spacing.s : 0)
        .background { if l.button { Capsule().fill(ink.s.ink.opacity(0.08)) } }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("sketch-row")
        .accessibilityLabel(lineLabel(l))
    }
}

// MARK: B, animated phone wireframes

struct WireSketch: View {
    let title: String?
    let sides: [SketchSide]
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = Ink(s: theme.swatch(scheme), scheme: scheme)
        VStack(alignment: .leading, spacing: theme.spacing.m) {
            if let title {
                Text(title).font(theme.font(theme.type.title, .black)).foregroundStyle(ink.s.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            HStack(alignment: .top, spacing: theme.spacing.s) {
                ForEach(sides) { side in phone(side, ink) }
            }
        }
    }

    private func phone(_ side: SketchSide, _ ink: Ink) -> some View {
        VStack(spacing: theme.spacing.s) {
            Capsule().fill(ink.s.outline).frame(width: 40, height: 5).padding(.top, 2).accessibilityHidden(true)
            if let label = side.label {
                Text(label.uppercased()).tracking(0.8)
                    .font(theme.font(theme.type.caption - 1, .black))
                    .foregroundStyle(side.good ? ink.good : ink.s.inkSoft)
                    .accessibilityIdentifier("sketch-label")
            }
            ForEach(Array(side.lines.enumerated()), id: \.element.id) { i, l in
                WireElement(line: l, ink: ink, order: i, good: side.good)
            }
            Spacer(minLength: 0)
        }
        .padding(theme.spacing.s)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(ink.s.background.opacity(0.5), in: .rect(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(ink.s.ink.opacity(side.good ? 0.7 : 0.3), lineWidth: 2.5))
    }
}

/// One wireframe element: a glass banner that slides in, a tap ripple on the point,
/// a strike that draws across what is gone, a callout under it.
private struct WireElement: View {
    let line: SketchLine
    let ink: Ink
    let order: Int
    let good: Bool
    @State private var on = false
    @State private var ripple = false
    @Environment(\.yuiTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack(alignment: .topTrailing) {
                HStack(alignment: .top, spacing: 6) {
                    Mark(line: line, ink: ink, size: 14)
                    if let text = line.text {
                        Text(text).font(theme.font(theme.type.caption + 1, line.hi ? .heavy : .semibold))
                            .foregroundStyle(line.dim || line.x ? ink.s.ink.opacity(0.5) : ink.s.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .strikethrough(line.x, color: ink.bad)
                    } else {
                        Capsule().fill(ink.s.outline).frame(width: 60, height: 7).padding(.vertical, 4)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular.tint(line.hi ? ink.good.opacity(0.2) : nil), in: .rect(cornerRadius: 14))
                if line.hi && !reduce {
                    Circle().stroke(ink.good, lineWidth: 2).frame(width: 22, height: 22)
                        .scaleEffect(ripple ? 1.9 : 0.5).opacity(ripple ? 0 : 0.9)
                        .padding(.top, -2).padding(.trailing, 2)
                        .accessibilityHidden(true)
                }
            }
            if let n = line.note {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.turn.left.up")
                    Text(n)
                }
                .font(theme.font(theme.type.caption - 1, .bold))
                .foregroundStyle(line.x ? ink.bad : (line.hi ? ink.good : ink.s.inkSoft))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 6)
            }
        }
        .opacity(on || reduce ? 1 : 0)
        .offset(y: on || reduce ? 0 : -26)
        .onAppear {
            guard !reduce else { on = true; return }
            let base = 0.12 * Double(order) + (good ? 0.5 : 0)
            withAnimation(.spring(duration: 0.6, bounce: 0.3).delay(base)) { on = true }
            if line.hi { withAnimation(.easeOut(duration: 1.1).delay(base + 0.7).repeatForever(autoreverses: false)) { ripple = true } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("sketch-row")
        .accessibilityLabel(lineLabel(line))
    }
}

// MARK: C, a beginning, middle and end strip

struct StripSketch: View {
    let title: String?
    let sides: [SketchSide]
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    /// The beats: what was (the first side), why or what changed (every note, the
    /// middle), what is (the last side). One side alone is one beat.
    private struct Beat: Identifiable { let id: Int; let name: String; let icon: String; let lines: [SketchLine]; let tone: Int }

    private var beats: [Beat] {
        guard let first = sides.first else { return [] }
        guard sides.count > 1, let last = sides.last else {
            return [Beat(id: 0, name: first.label ?? "Now", icon: "1.circle.fill", lines: first.lines, tone: 1)]
        }
        let notes = (first.lines + last.lines).compactMap { l -> SketchLine? in
            l.note.map { SketchLine.note($0, id: 200 + l.id, hi: l.hi, x: l.x) }
        }
        var out = [Beat(id: 0, name: first.label ?? "Before", icon: "1.circle.fill", lines: first.lines.map(\.withoutNote), tone: 0)]
        if !notes.isEmpty { out.append(Beat(id: 1, name: "Why", icon: "2.circle.fill", lines: notes, tone: 2)) }
        out.append(Beat(id: 2, name: last.label ?? "After", icon: out.count == 1 ? "2.circle.fill" : "3.circle.fill",
                        lines: last.lines.map(\.withoutNote), tone: 1))
        return out
    }

    var body: some View {
        let ink = Ink(s: theme.swatch(scheme), scheme: scheme)
        let beats = beats
        VStack(alignment: .leading, spacing: theme.spacing.m) {
            if let title {
                Text(title).font(theme.font(theme.type.title, .black)).foregroundStyle(ink.s.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(beats.enumerated()), id: \.element.id) { i, b in
                    HStack(alignment: .top, spacing: theme.spacing.m) {
                        rail(i, last: i == beats.count - 1, tone: b.tone, ink)
                        beat(b, ink).rise(i * 2)
                    }
                }
            }
        }
        .onAppear {
            guard !reduce else { drawn = true; return }
            withAnimation(.easeInOut(duration: 1.0).delay(0.2)) { drawn = true }
        }
    }

    private func tint(_ tone: Int, _ ink: Ink) -> Color { tone == 0 ? ink.bad : (tone == 1 ? ink.good : ink.s.accent) }

    private func rail(_ i: Int, last: Bool, tone: Int, _ ink: Ink) -> some View {
        VStack(spacing: 0) {
            Text("\(i + 1)").font(theme.font(theme.type.caption, .black)).foregroundStyle(.white)
                .frame(width: 26, height: 26).background(tint(tone, ink), in: Circle())
            if !last {
                Capsule().fill(ink.s.outline).frame(width: 3)
                    .scaleEffect(y: drawn ? 1 : 0, anchor: .top)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 26)
        .accessibilityHidden(true)
    }

    private func beat(_ b: Beat, _ ink: Ink) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.xs) {
            Text(b.name.uppercased()).tracking(0.8).font(theme.font(theme.type.caption, .black))
                .foregroundStyle(tint(b.tone, ink)).accessibilityIdentifier("sketch-label")
            ForEach(b.lines) { l in
                HStack(alignment: .top, spacing: theme.spacing.s) {
                    Mark(line: l, ink: ink, size: 18)
                    Text(l.text ?? "")
                        .font(theme.font(theme.type.body, l.hi ? .heavy : .semibold))
                        .strikethrough(l.x, color: ink.bad)
                        .foregroundStyle(l.dim || l.x ? ink.s.ink.opacity(0.5) : ink.s.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("sketch-row")
                .accessibilityLabel(lineLabel(l))
            }
        }
        .padding(theme.spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(b.tone == 1 ? ink.good.opacity(0.14) : nil), in: .rect(cornerRadius: 22))
        .padding(.bottom, theme.spacing.s)
    }
}

private extension SketchLine {
    /// A note made into a line of its own: the middle of the strip.
    static func note(_ text: String, id: Int, hi: Bool, x: Bool) -> SketchLine {
        SketchLine(text: text, id: id, hi: hi, x: false, note: nil)
    }

    var withoutNote: SketchLine { SketchLine(text: text, id: id, hi: hi, x: x, dim: dim, button: button, note: nil) }

    init(text: String?, id: Int, hi: Bool = false, x: Bool = false, dim: Bool = false, button: Bool = false, note: String?) {
        self.id = id; self.text = text; self.hi = hi; self.x = x; self.dim = dim; self.button = button; self.note = note
    }
}
