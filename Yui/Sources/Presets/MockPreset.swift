import SwiftUI
import YuiLines

// Mock-ups (DRAW-2, the app half of DRAW-1). `mock [title] [frame=phone] [url=]`,
// then one `part` per line: a UI recreated from parts, so an agent can redraw a
// Yui screen, a screen it is proposing or a client's page instead of describing it.
// Frames: phone (default, anything unknown), window, watch, browser. Parts stack
// top to bottom in line order except a `nav` (always first), a `tabs` (always
// last of the screen) and a `sheet`, `alert` or `keyboard` (after those). Marks as
// in `sketch`: +hi a highlighter swipe, +x struck out, +dim greyed, note= a callout
// beside the frame with an arrow to it. Drawn in the agent's look, light and dark;
// nothing in it can be tapped and it sends nothing. Reduce Motion has nothing to
// show: it is still. In a deck or plan it is a page's picture; a lone `part` is a
// one-part mock.

struct MockPreset: View {
    let c: YLComponent
    @Environment(\.ylComponents) private var all

    var body: some View {
        let lone = c.preset != "mock"
        let head = lone ? [:] : c.props
        let members = lone ? [c] : all.members(of: c).filter { $0.preset == "part" }
        PresetCard { MockDrawing(head: head, parts: MockModel.parts(members.map(\.props))) }
    }
}

/// One part of the screen, read from a `part` line's props.
struct MockPart: Equatable {
    var kind = "text"
    var text = "", sub = "", value = "", ph = "", icon = "", action = "", size = "", ratio = "", body = "", note = ""
    var back: String? // nil: no back button; "": a bare ‹
    var tab: YLValue?
    var cols = 3
    var items: [String] = []
    var chev = false, ghost = false, on = false, hi = false, x = false, dim = false
}

enum MockModel {
    static let frames = ["phone", "window", "watch", "browser"]
    static let overlays: Set<String> = ["sheet", "alert", "keyboard"]
    static let kinds: Set<String> = ["nav", "tabs", "text", "row", "field", "button", "toggle", "slider", "segmented", "card",
                                     "image", "avatar", "grid", "divider", "space", "sheet", "alert", "keyboard"]

    private static func text(_ v: YLValue?) -> String {
        switch v {
        case .string(let s)?: s
        case .number(let n)?: YLComponent.format(n)
        default: ""
        }
    }

    static func part(_ p: [String: YLValue]) -> MockPart {
        var m = MockPart()
        let kind = text(p["kind"])
        m.kind = kind.isEmpty ? "text" : kind
        m.text = text(p["text"]); m.sub = text(p["sub"]); m.value = text(p["value"]); m.ph = text(p["ph"]); m.icon = text(p["icon"])
        m.action = text(p["action"]); m.size = text(p["size"]); m.ratio = text(p["ratio"]); m.body = text(p["body"]); m.note = text(p["note"])
        switch p["back"] {
        case .string(let s)?: m.back = s
        case .bool(true)?: m.back = ""
        case .number(let n)?: m.back = YLComponent.format(n)
        default: m.back = nil
        }
        m.tab = p["tab"]
        if let n = p["cols"]?.number ?? p["cols"]?.string.flatMap(Double.init) { m.cols = Int(n) }
        m.items = (p["items"].map { $0.array ?? [$0] } ?? []).map { text($0) }
        m.chev = p["chev"]?.bool ?? false; m.ghost = p["ghost"]?.bool ?? false; m.on = p["on"]?.bool ?? false
        m.hi = p["hi"]?.bool ?? false; m.x = p["x"]?.bool ?? false; m.dim = p["dim"]?.bool ?? false
        return m
    }

    /// nav first, tabs after the content, sheets, alerts and keyboards last,
    /// whatever the order of the lines; only the first nav and the first tabs count.
    static func parts(_ members: [[String: YLValue]]) -> [MockPart] {
        let all = members.map(part)
        let at = { (k: String) in all.filter { $0.kind == k } }
        let rest = all.filter { $0.kind != "nav" && $0.kind != "tabs" && !overlays.contains($0.kind) }
        return Array(at("nav").prefix(1)) + rest + Array(at("tabs").prefix(1)) + all.filter { overlays.contains($0.kind) }
    }

    /// The selected tab's index: a number from 1, or a name.
    static func pick(_ items: [String], _ tab: YLValue?) -> Int {
        switch tab {
        case .number(let n)?: return Int(n) - 1
        case .string(let s)?:
            if let i = items.firstIndex(where: { $0.lowercased() == s.lowercased() }) { return i }
            return Double(s).map { Int($0) - 1 } ?? -1
        default: return -1
        }
    }

    static func frame(_ p: [String: YLValue]) -> String {
        let f = p["frame"]?.string ?? "phone"
        return frames.contains(f) ? f : "phone"
    }

    /// What VoiceOver reads, top to bottom.
    static func describe(head: [String: YLValue], parts: [MockPart]) -> String {
        var out: [String] = []
        if let t = head["title"]?.string, !t.isEmpty { out.append(t + ".") }
        out.append("Mock screen, \(frame(head)):")
        let join = { (xs: [String]) in xs.filter { !$0.isEmpty }.joined(separator: ", ") }
        let said: [String] = parts.map { p in
            var s: String
            switch p.kind {
            case "nav": s = "Navigation bar, " + join([p.text, p.back.map { "back " + $0 } ?? "", p.action.isEmpty ? "" : "button " + p.action])
            case "tabs":
                let on = pick(p.items, p.tab)
                s = "Tabs, " + join(p.items.enumerated().map { $0.offset == on ? "\($0.element), selected" : $0.element })
            case "row": s = join([p.text, p.sub, p.value])
            case "field": s = "Field, " + join([p.text, p.value.isEmpty ? (p.ph.isEmpty ? "" : "placeholder " + p.ph) : p.value])
            case "button": s = "Button, " + p.text
            case "toggle": s = "Switch, \(p.text), \(p.on ? "on" : "off")"
            case "slider": s = "Slider, \(p.text), \(Int((min(1, max(0, Double(p.value) ?? 0.5)) * 100).rounded())) percent"
            case "segmented":
                let on = pick(p.items, p.tab)
                s = "Options, " + join(p.items.enumerated().map { $0.offset == on ? "\($0.element), selected" : $0.element })
            case "card": s = "Card, " + join([p.text, p.sub, p.body])
            case "image": s = "Image, " + p.text
            case "avatar": s = "Avatar, " + p.text
            case "grid": s = "Grid, " + join(p.items)
            case "divider", "space": return ""
            case "sheet": s = "Sheet, " + join([p.text] + p.items)
            case "alert": s = "Alert, " + join([p.text, p.body]) + (p.items.isEmpty ? "" : ", buttons " + join(p.items))
            case "keyboard": s = "Keyboard"
            default: s = p.text
            }
            let marks = join([p.x ? "crossed out" : "", p.hi ? "highlighted" : "", p.dim ? "greyed" : ""])
            return s + (marks.isEmpty ? "" : " (\(marks))") + (p.note.isEmpty ? "" : ". Note: " + p.note)
        }
        out.append(said.filter { !$0.isEmpty }.joined(separator: "; ") + ".")
        return out.joined(separator: " ")
    }
}

/// Every frame cell's bounds, so the frame draws once behind all of them.
private struct MockBox: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) { value += nextValue() }
}

struct MockDrawing: View {
    let head: [String: YLValue]
    let parts: [MockPart]
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private var frame: String { MockModel.frame(head) }
    private var title: String { head["title"]?.string ?? "" }
    private var url: String { head["url"]?.string ?? "" }

    var body: some View {
        let s = theme.swatch(scheme)
        let notes = parts.contains { !$0.note.isEmpty }
        let hasNav = parts.contains { $0.kind == "nav" }
        let side: CGFloat = frame == "phone" ? 16 : 12
        VStack(alignment: .leading, spacing: theme.spacing.xs) {
            if frame == "watch", !title.isEmpty {
                Text(title).font(theme.font(theme.type.caption, .heavy)).foregroundStyle(s.inkSoft)
                    .accessibilityHidden(true)
            }
            Grid(alignment: .topLeading, horizontalSpacing: 6, verticalSpacing: 0) {
                GridRow {
                    bar(s, hasNav: hasNav).frame(maxWidth: cellWidth, alignment: .leading).anchorPreference(key: MockBox.self, value: .bounds) { [$0] }
                    if notes { Color.clear.frame(width: 0, height: 0) }
                }
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    GridRow {
                        cell(p, s)
                            .padding(.horizontal, side).padding(.vertical, 3)
                            .frame(maxWidth: cellWidth, alignment: .leading)
                            .anchorPreference(key: MockBox.self, value: .bounds) { [$0] }
                        if notes { note(p, s) }
                    }
                }
                GridRow {
                    Color.clear.frame(maxWidth: cellWidth).frame(height: frame == "phone" ? 18 : 10)
                        .anchorPreference(key: MockBox.self, value: .bounds) { [$0] }
                    if notes { Color.clear.frame(width: 0, height: 0) }
                }
            }
            .backgroundPreferenceValue(MockBox.self) { anchors in
                GeometryReader { g in
                    let r = anchors.map { g[$0] }.reduce(CGRect.null) { $0.union($1) }
                    if !r.isNull { box(s).frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MockModel.describe(head: head, parts: parts))
        .accessibilityValue("\(parts.count) parts")
        .accessibilityIdentifier("mock-drawing")
        .accessibilityAddTraits(.isImage)
    }

    private var cellWidth: CGFloat { frame == "watch" ? 190 : .infinity }

    // MARK: Frame

    private func box(_ s: Swatch) -> some View {
        let radius: CGFloat = frame == "phone" ? 28 : frame == "watch" ? 34 : 14
        let width: CGFloat = frame == "phone" ? 3 : frame == "watch" ? 4 : 2
        return RoundedRectangle(cornerRadius: radius, style: .continuous).fill(s.background)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(frame == "phone" ? s.ink.opacity(0.75) : s.outline, lineWidth: width))
    }

    @ViewBuilder
    private func bar(_ s: Swatch, hasNav: Bool) -> some View {
        switch frame {
        case "window", "browser":
            HStack(spacing: 8) {
                HStack(spacing: 4) { ForEach(0..<3, id: \.self) { _ in Circle().fill(s.outline).frame(width: 7, height: 7) } }
                if frame == "browser" {
                    Text(url.isEmpty ? title : url).font(theme.font(12, .regular)).foregroundStyle(s.inkSoft).lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(s.ink.opacity(0.06), in: Capsule())
                } else if !title.isEmpty, !hasNav {
                    Text(title).font(theme.font(12, .heavy)).foregroundStyle(s.inkSoft).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .overlay(alignment: .bottom) { Rectangle().fill(s.outline).frame(height: 2) }
            .padding(.bottom, 4)
        case "watch":
            Color.clear.frame(height: 14)
        default:
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(s.ink.opacity(0.75)).frame(width: 54, height: 7).frame(maxWidth: .infinity)
                if !title.isEmpty, !hasNav {
                    Text(title).font(theme.font(12, .heavy)).foregroundStyle(s.inkSoft)
                }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 2)
        }
    }

    // MARK: Cells

    private var marker: Color {
        scheme == .dark ? Color(red: 1, green: 0.82, blue: 0.25).opacity(0.36) : Color(red: 1, green: 0.8, blue: 0).opacity(0.45)
    }

    private func cell(_ p: MockPart, _ s: Swatch) -> some View {
        let bad = ChartPalette.bad(scheme)
        return part(p, s)
            .strikethrough(p.x, color: bad)
            .background {
                if p.hi { LinearGradient(colors: [.clear, marker, marker, .clear], startPoint: .leading, endPoint: .trailing).opacity(1) }
            }
            .overlay {
                if p.x { RoundedRectangle(cornerRadius: 3).stroke(bad, style: StrokeStyle(lineWidth: 2, dash: [5, 3])).padding(.horizontal, -3).padding(.vertical, -1) }
            }
            .opacity(p.dim ? 0.4 : p.x ? 0.6 : 1)
    }

    /// A callout beside the frame, an arrow pointing back at its part.
    @ViewBuilder
    private func note(_ p: MockPart, _ s: Swatch) -> some View {
        if !p.note.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "arrow.left").font(theme.font(theme.type.caption - 1, .black)).foregroundStyle(s.accent)
                Text(p.note).font(theme.font(theme.type.caption, .bold)).foregroundStyle(s.ink).fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 118, alignment: .leading)
            .padding(.vertical, 3)
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    @ViewBuilder
    private func part(_ p: MockPart, _ s: Swatch) -> some View {
        let ink = s.ink, soft = s.inkSoft, axis = s.outline, tile = s.ink.opacity(0.06)
        let fs: CGFloat = 13.5
        switch p.kind {
        case "nav":
            HStack(spacing: 8) {
                Text(p.back.map { "‹ " + $0 } ?? "").font(theme.font(14, .bold)).foregroundStyle(s.accent).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(p.text).font(theme.font(14, .heavy)).foregroundStyle(ink).lineLimit(1)
                Text(p.action).font(theme.font(14, .bold)).foregroundStyle(s.accent).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        case "tabs":
            let on = MockModel.pick(p.items, p.tab)
            HStack {
                ForEach(Array(p.items.enumerated()), id: \.offset) { i, t in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 6).fill(i == on ? s.accent : .clear).frame(width: 18, height: 18)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(i == on ? s.accent : soft, lineWidth: 1.8))
                        Text(t).font(theme.font(10.5, .bold)).foregroundStyle(i == on ? s.accent : soft).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 6)
            .overlay(alignment: .top) { Rectangle().fill(axis).frame(height: 1.5) }
        case "row":
            HStack(spacing: 10) {
                if !p.icon.isEmpty {
                    Text(p.icon).font(theme.font(15, .bold)).foregroundStyle(ink)
                        .frame(width: 28, height: 28)
                        .background(s.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(p.text).font(theme.font(fs, .bold)).foregroundStyle(ink)
                    if !p.sub.isEmpty { Text(p.sub).font(theme.font(11.5, .regular)).foregroundStyle(soft) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !p.value.isEmpty { Text(p.value).font(theme.font(13, .regular)).foregroundStyle(soft) }
                if p.chev { Text("›").font(theme.font(18, .regular)).foregroundStyle(soft) }
            }
            .padding(.vertical, 4)
            .overlay(alignment: .bottom) { Rectangle().fill(tile).frame(height: 1) }
        case "field":
            VStack(alignment: .leading, spacing: 3) {
                if !p.text.isEmpty { Text(p.text).font(theme.font(11.5, .regular)).foregroundStyle(soft) }
                Text(p.value.isEmpty ? (p.ph.isEmpty ? " " : p.ph) : p.value)
                    .font(theme.font(fs, .regular))
                    .foregroundStyle(p.value.isEmpty ? soft.opacity(0.7) : ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(axis, lineWidth: 1.5))
            }
        case "button":
            Text(p.text).font(theme.font(fs, .heavy))
                .foregroundStyle(p.ghost ? s.accent : s.onAccent)
                .frame(maxWidth: .infinity).padding(.vertical, 8).padding(.horizontal, 14)
                .background(p.ghost ? Color.clear : s.accent, in: Capsule())
                .overlay(Capsule().stroke(s.accent, lineWidth: 2))
        case "toggle":
            HStack(spacing: 10) {
                Text(p.text).font(theme.font(fs, .regular)).foregroundStyle(ink).frame(maxWidth: .infinity, alignment: .leading)
                Capsule().fill(p.on ? s.accent : axis).frame(width: 38, height: 22)
                    .overlay(alignment: p.on ? .trailing : .leading) { Circle().fill(.white).frame(width: 18, height: 18).padding(2) }
            }
            .padding(.vertical, 4)
        case "slider":
            VStack(alignment: .leading, spacing: 6) {
                if !p.text.isEmpty { Text(p.text).font(theme.font(fs, .regular)).foregroundStyle(ink) }
                let v = min(1, max(0, Double(p.value) ?? 0.5))
                Capsule().fill(axis).frame(height: 6)
                    .overlay(alignment: .leading) { GeometryReader { g in Capsule().fill(s.accent).frame(width: g.size.width * v) } }
            }
        case "segmented":
            let on = MockModel.pick(p.items, p.tab)
            HStack(spacing: 0) {
                ForEach(Array(p.items.enumerated()), id: \.offset) { i, t in
                    Text(t).font(theme.font(12.5, .bold)).foregroundStyle(i == on ? s.onAccent : soft).lineLimit(1)
                        .frame(maxWidth: .infinity).padding(.vertical, 5).padding(.horizontal, 4)
                        .background(i == on ? s.accent : .clear)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(axis, lineWidth: 1.5))
        case "card":
            VStack(alignment: .leading, spacing: 3) {
                Text(p.text).font(theme.font(fs, .heavy)).foregroundStyle(ink)
                if !p.sub.isEmpty { Text(p.sub).font(theme.font(11.5, .regular)).foregroundStyle(soft) }
                if !p.body.isEmpty { Text(p.body).font(theme.font(fs, .regular)).foregroundStyle(ink) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(tile, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(axis, lineWidth: 1.5))
        case "image":
            let parts = p.ratio.split(separator: ":").compactMap { Double($0) }
            let ratio = parts.count == 2 && parts[1] > 0 && parts[0] > 0 ? parts[0] / parts[1] : 16.0 / 9
            Canvas { ctx, size in
                var x = -size.height
                while x < size.width {
                    var l = Path(); l.move(to: CGPoint(x: x, y: size.height)); l.addLine(to: CGPoint(x: x + size.height, y: 0))
                    ctx.stroke(l, with: .color(tile), lineWidth: 5)
                    x += 14
                }
            }
            .aspectRatio(ratio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(axis, lineWidth: 1.5))
            .overlay { Text(p.text).font(theme.font(11.5, .regular)).foregroundStyle(soft) }
        case "avatar":
            Text(String(p.text.prefix(2))).font(theme.font(14, .heavy)).foregroundStyle(ink)
                .frame(width: 38, height: 38)
                .background(s.accent.opacity(0.22), in: Circle())
                .overlay(Circle().stroke(s.accent, lineWidth: 1.5))
        case "grid":
            let cols = min(6, max(1, p.cols))
            let cells = p.items.isEmpty ? Array(repeating: "", count: cols * 2) : p.items
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: cols), spacing: 6) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, t in
                    Text(t).font(theme.font(12, .bold)).foregroundStyle(ink).multilineTextAlignment(.center).padding(4)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(tile, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(axis, lineWidth: 1))
                }
            }
        case "divider":
            Rectangle().fill(axis).frame(height: 1.5).padding(.vertical, 4)
        case "space":
            Color.clear.frame(height: 16)
        case "sheet":
            VStack(spacing: 6) {
                Capsule().fill(axis).frame(width: 36, height: 4)
                if !p.text.isEmpty { Text(p.text).font(theme.font(fs, .heavy)).foregroundStyle(ink) }
                ForEach(Array(p.items.enumerated()), id: \.offset) { _, t in
                    Text(t).font(theme.font(fs, .regular)).foregroundStyle(ink)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                        .overlay(alignment: .top) { Rectangle().fill(axis).frame(height: 1) }
                }
            }
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
            .background(tile, in: UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16))
            .overlay(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16).stroke(axis, lineWidth: 1.5))
        case "alert":
            VStack(spacing: 4) {
                Text(p.text).font(theme.font(fs, .heavy)).foregroundStyle(ink)
                if !p.body.isEmpty { Text(p.body).font(theme.font(11.5, .regular)).foregroundStyle(soft) }
                HStack(spacing: 8) {
                    ForEach(Array(p.items.enumerated()), id: \.offset) { i, t in
                        let main = i == p.items.count - 1
                        Text(t).font(theme.font(13, .bold)).foregroundStyle(main ? s.onAccent : ink).lineLimit(1)
                            .frame(maxWidth: .infinity).padding(6)
                            .background(main ? s.accent : .clear, in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(main ? s.accent : axis, lineWidth: 1.5))
                    }
                }
                .padding(.top, 8)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(tile, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(axis, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
            .padding(.horizontal, 4)
        case "keyboard":
            VStack(spacing: 5) {
                key(10, s).padding(.horizontal, 0)
                key(9, s).padding(.horizontal, 12)
                key(7, s).padding(.horizontal, 30)
                HStack(spacing: 3) {
                    keycap(s).frame(width: 44)
                    keycap(s).frame(maxWidth: .infinity)
                    keycap(s).frame(width: 44)
                }
                .frame(height: 18)
            }
            .padding(.vertical, 6).padding(.horizontal, 4)
            .background(tile)
            .overlay(alignment: .top) { Rectangle().fill(axis).frame(height: 1.5) }
            .padding(.horizontal, -12)
        default:
            // Any kind the app does not know draws as text, so kinds can be added later.
            let size = p.size
            Text(p.text)
                .font(theme.font(size == "h1" ? 22 : size == "h2" ? 17 : size == "large" ? 19 : size == "small" ? 11.5 : fs,
                                 size == "h1" || size == "h2" || size == "large" ? .heavy : .regular))
                .foregroundStyle(size == "small" ? soft : ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func key(_ n: Int, _ s: Swatch) -> some View {
        HStack(spacing: 3) { ForEach(0..<n, id: \.self) { _ in keycap(s) } }.frame(height: 18)
    }
    private func keycap(_ s: Swatch) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(s.background)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(s.outline, lineWidth: 1))
    }
}
