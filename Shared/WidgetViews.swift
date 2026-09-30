import AppIntents
import Charts
import SwiftUI
import WidgetKit
import YuiLines

// How a saved screen draws as a widget (YUI-40). Compiled into the widget extension and, for the
// light/dark shots and tests, into the app.

struct SavedScreenEntry: TimelineEntry {
    let date: Date
    let screen: WidgetScreen?
    let hideOnLock: Bool
}

struct SavedScreenBackground: View {
    let screen: WidgetScreen?
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        if let s = screen { Color(hex: s.palette(dark: scheme == .dark).background) } else { Color(.systemBackground) }
    }
}

// MARK: Drawing

/// The agent's colors and type for one widget.
struct WidgetLook {
    let ink, inkSoft, accent, mint, surface, onAccent: Color
    let design: Font.Design

    init(_ s: WidgetScreen, dark: Bool) {
        let p = s.palette(dark: dark)
        ink = Color(hex: p.ink); inkSoft = Color(hex: p.inkSoft); accent = Color(hex: p.accent)
        mint = Color(hex: p.mint); surface = Color(hex: p.surface); onAccent = Color(hex: p.onAccent)
        design = switch s.design {
        case "serif": .serif
        case "monospaced": .monospaced
        case "default": .default
        default: .rounded
        }
    }

    func font(_ size: Double, _ weight: Font.Weight = .bold) -> Font { .system(size: size, weight: weight, design: design) }
}

private extension View {
    /// Values the person may not want on a locked phone (the lock screen switch, spec section 8).
    @ViewBuilder func sensitive(_ on: Bool) -> some View { if on { privacySensitive() } else { self } }
}

struct SavedScreenView: View {
    let entry: SavedScreenEntry
    /// The app's own gallery (shots, tests) draws at a size without a widget around it.
    var familyOverride: WidgetFamily?
    @Environment(\.widgetFamily) private var envFamily
    private var family: WidgetFamily { familyOverride ?? envFamily }
    @Environment(\.colorScheme) private var scheme

    private var accessory: Bool { [.accessoryRectangular, .accessoryCircular, .accessoryInline].contains(family) }

    var body: some View {
        if let screen = entry.screen {
            let look = WidgetLook(screen, dark: scheme == .dark)
            let part = screen.parts.first { WidgetScreen.drawn.contains($0.preset) || ["done", "now", "next"].contains($0.preset) }
            content(screen, part, look)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .widgetURL(Self.link(screen))
        } else {
            empty
        }
    }

    @ViewBuilder private func content(_ s: WidgetScreen, _ part: WidgetPart?, _ look: WidgetLook) -> some View {
        let hide = entry.hideOnLock && accessory
        if let part {
            switch family {
            case .accessoryInline: inline(s, part)
            case .accessoryCircular: circular(part, look).sensitive(hide)
            case .accessoryRectangular: rect(s, part, look).sensitive(hide)
            default:
                VStack(alignment: .leading, spacing: 6) {
                    body(s, part, look)
                    Spacer(minLength: 0)
                    footer(s, look)
                }
            }
        } else {
            // Nothing a widget draws: the screen's name and an Open button (the tap itself).
            VStack(spacing: 6) {
                Text(s.name).font(look.font(15, .heavy)).foregroundStyle(look.ink).lineLimit(2).multilineTextAlignment(.center)
                Text("Open in Yui").font(look.font(12)).foregroundStyle(look.accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Home screen

    @ViewBuilder private func body(_ s: WidgetScreen, _ p: WidgetPart, _ look: WidgetLook) -> some View {
        let small = family == .systemSmall
        switch p.preset {
        case "stat": StatBody(s: s, p: p, look: look, small: small)
        case "chart": ChartBody(p: p, look: look, small: small)
        case "list": ListBody(s: s, p: p, look: look, rows: small ? 3 : 4)
        case "timer": TimerBody(s: s, p: p, look: look, small: small)
        case "card": CardBody(s: s, p: p, look: look, small: small)
        case "table": TableBody(p: p, look: look, rows: small ? 0 : 3)
        default: TimelineBody(s: s, look: look, rows: small ? 1 : 3)
        }
    }

    /// "as of 9:40" when the copy is older than a few hours: never a spinner, never blank (spec section 3).
    @ViewBuilder private func footer(_ s: WidgetScreen, _ look: WidgetLook) -> some View {
        if Date.now.timeIntervalSince(s.at) > 3 * 3600 {
            Text("as of \(s.at.formatted(date: .omitted, time: .shortened))")
                .font(look.font(10, .semibold)).foregroundStyle(look.inkSoft)
        } else if family != .systemSmall {
            Text(s.name).font(look.font(10, .semibold)).foregroundStyle(look.inkSoft).lineLimit(1)
        }
    }

    // MARK: Lock screen

    @ViewBuilder private func rect(_ s: WidgetScreen, _ p: WidgetPart, _ look: WidgetLook) -> some View {
        switch p.preset {
        case "stat":
            VStack(alignment: .leading, spacing: 0) {
                Text(StatBody.value(p)).font(.system(size: 22, weight: .bold, design: look.design))
                Text([StatBody.delta(p), p.string("label")].compactMap { $0 }.joined(separator: "  ")).font(.caption2).lineLimit(1)
            }
        case "chart":
            ChartBody(p: p, look: look, small: true, compact: true)
        case "list":
            let next = p.list("items").first { !p.ticked.contains($0) }
            let label = VStack(alignment: .leading, spacing: 0) {
                Text(p.string("title") ?? s.name).font(.caption2.weight(.semibold))
                Text(next ?? "All done").font(.headline).lineLimit(2)
            }
            // The next item is a button: one tap ticks it (Face ID first on a locked phone).
            if p.flag("check"), let next {
                Button(intent: WidgetTickIntent(agent: s.agentID, screen: s.name, part: p.ylID, item: next)) { label }.buttonStyle(.plain)
            } else {
                label
            }
        case "timer":
            VStack(alignment: .leading, spacing: 0) {
                Text(p.string("label") ?? "Timer").font(.caption2.weight(.semibold))
                TimerBody.time(p, size: 24, look: look)
            }
        case "card":
            VStack(alignment: .leading, spacing: 0) {
                Text(p.string("title") ?? s.name).font(.headline).lineLimit(2)
                if let sub = p.string("sub") { Text(sub).font(.caption2).lineLimit(1) }
            }
        default:
            let now = TimelineBody.rows(s).first { $0.kind == "now" } ?? TimelineBody.rows(s).first
            VStack(alignment: .leading, spacing: 0) {
                Text("Now").font(.caption2.weight(.semibold))
                Text(now?.text ?? s.name).font(.headline).lineLimit(2)
            }
        }
    }

    @ViewBuilder private func circular(_ p: WidgetPart, _ look: WidgetLook) -> some View {
        switch p.preset {
        case "stat":
            ZStack {
                AccessoryWidgetBackground()
                Text(StatBody.value(p, unit: false)).font(.system(size: 15, weight: .bold, design: look.design)).minimumScaleFactor(0.5).padding(4)
            }
        case "timer":
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "timer").font(.title3)
            }
        default:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: Self.symbol(p.preset)).font(.title3)
            }
        }
    }

    private func inline(_ s: WidgetScreen, _ p: WidgetPart) -> some View {
        switch p.preset {
        case "stat": Text("\(p.string("label") ?? s.name) \(StatBody.value(p)) \(StatBody.delta(p) ?? "")")
        case "list": Text(p.list("items").first { !p.ticked.contains($0) } ?? s.name)
        case "timeline", "now", "next", "done":
            Text("Now: \(TimelineBody.rows(s).first { $0.kind == "now" }?.text ?? s.name)")
        default: Text(p.string("title") ?? p.string("label") ?? s.name)
        }
    }

    static func symbol(_ preset: String) -> String {
        switch preset {
        case "chart": "chart.xyaxis.line"
        case "list": "checklist"
        case "card": "rectangle.on.rectangle"
        case "table": "tablecells"
        default: "star.fill"
        }
    }

    // MARK: Empty, link

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "star").font(.title2)
            Text("Pick a saved screen").font(.footnote.weight(.semibold))
            Text("Hold to edit").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// `yui://agent/<id>/thread?show=<name>`: the thread, with the saved screen on the stage (no turn).
    static func link(_ s: WidgetScreen) -> URL? {
        var c = URLComponents()
        c.scheme = "yui"; c.host = "agent"; c.path = "/\(s.agentID)/thread"
        c.queryItems = [URLQueryItem(name: "show", value: s.name)]
        return c.url
    }
}

// MARK: Presets

/// A `cta` on a stat or card, as a button on the widget (spec section 5): the agent gets `{cta, saved, via: widget}`.
struct WidgetCTA: View {
    let s: WidgetScreen, p: WidgetPart, look: WidgetLook

    /// Only a button that sends something: a card whose `cta` has a `url` opens a link, and a widget cannot.
    static func label(_ p: WidgetPart) -> String? {
        guard p.props["url"] == nil, p.props["open"] == nil, let c = p.string("cta"), !c.isEmpty else { return nil }
        return c
    }

    var body: some View {
        if let label = Self.label(p) {
            Button(intent: WidgetCtaIntent(agent: s.agentID, screen: s.name, part: p.ylID, label: label)) {
                Text(label).font(look.font(12, .heavy)).foregroundStyle(look.onAccent).lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(look.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

struct StatBody: View {
    let s: WidgetScreen, p: WidgetPart, look: WidgetLook, small: Bool

    static func value(_ p: WidgetPart, unit: Bool = true) -> String {
        let v = p.string("value") ?? "–"
        guard unit, let u = p.string("unit") else { return v }
        return ["$", "€", "£", "¥"].contains(u) ? u + v : v + (u.count <= 2 ? "" : " ") + u
    }

    static func delta(_ p: WidgetPart) -> String? {
        guard let d = p.number("delta"), d != 0 else { return nil }
        let mag = abs(d).rounded() == abs(d) ? String(Int(abs(d))) : String(format: "%g", abs(d))
        return "\(d < 0 ? "▼" : "▲")\(mag)"
    }

    var body: some View {
        let d = p.number("delta") ?? 0
        let good = (p.string("good") ?? "up") == "up" ? d >= 0 : d <= 0
        VStack(alignment: .leading, spacing: 2) {
            if let label = p.string("label") {
                Text(label).font(look.font(13, .heavy)).foregroundStyle(look.inkSoft).lineLimit(1)
            }
            Text(Self.value(p)).font(look.font(small ? 34 : 40, .heavy)).foregroundStyle(look.ink)
                .minimumScaleFactor(0.5).lineLimit(1)
            HStack(spacing: 6) {
                if let delta = Self.delta(p) {
                    Text(delta).font(look.font(13, .heavy)).foregroundStyle(good ? look.mint : look.accent)
                }
                if !small, let sub = p.string("sub") { Text(sub).font(look.font(12, .semibold)).foregroundStyle(look.inkSoft).lineLimit(1) }
            }
            if !small, p.numbers("spark").count > 1 {
                Chart(Array(p.numbers("spark").enumerated()), id: \.offset) { i, v in
                    LineMark(x: .value("i", i), y: .value("v", v)).foregroundStyle(look.accent)
                }
                .chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: .automatic(includesZero: false))
                .frame(maxHeight: 40)
            }
            WidgetCTA(s: s, p: p, look: look)
        }
    }
}

struct ChartBody: View {
    let p: WidgetPart, look: WidgetLook, small: Bool
    var compact = false

    var body: some View {
        let ys = p.numbers("y"), xs = p.list("x")
        let type = p.string("type") ?? "line"
        VStack(alignment: .leading, spacing: 4) {
            if !compact, let t = p.string("title") { Text(t).font(look.font(13, .heavy)).foregroundStyle(look.inkSoft).lineLimit(1) }
            if ys.isEmpty {
                // A chart bound to a table (`data=`) has no series of its own here.
                Text("Open in Yui").font(look.font(12)).foregroundStyle(look.accent)
            } else if type == "pie" || type == "donut" {
                Chart(Array(ys.enumerated()), id: \.offset) { i, v in
                    SectorMark(angle: .value("v", v), innerRadius: .ratio(0.6)).foregroundStyle(by: .value("i", i))
                }
                .chartLegend(.hidden)
                .chartOverlay { _ in
                    Text(String(format: "%g", ys.reduce(0, +))).font(look.font(small ? 15 : 18, .heavy)).foregroundStyle(look.ink)
                }
            } else {
                Chart(Array(ys.enumerated()), id: \.offset) { i, v in
                    switch type {
                    case "bar": BarMark(x: .value("x", i), y: .value("y", v)).foregroundStyle(look.accent)
                    case "area": AreaMark(x: .value("x", i), y: .value("y", v)).foregroundStyle(look.accent.opacity(0.4))
                    default: LineMark(x: .value("x", i), y: .value("y", v)).foregroundStyle(look.accent)
                    }
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .chartYScale(domain: type == "line" ? .automatic(includesZero: false) : .automatic)
                .overlay(alignment: .topTrailing) {
                    if let last = ys.last { Text(String(format: "%g", last)).font(look.font(12, .heavy)).foregroundStyle(look.ink) }
                }
            }
        }
        .accessibilityLabel("\(p.string("title") ?? "Chart"), \(xs.count) points")
    }
}

struct ListBody: View {
    let s: WidgetScreen, p: WidgetPart, look: WidgetLook, rows: Int

    var body: some View {
        let items = p.list("items")
        VStack(alignment: .leading, spacing: 4) {
            if let t = p.string("title") { Text(t).font(look.font(13, .heavy)).foregroundStyle(look.inkSoft).lineLimit(1) }
            ForEach(Array(items.prefix(rows).enumerated()), id: \.offset) { i, item in
                let done = p.ticked.contains(item)
                let row = HStack(spacing: 6) {
                    Image(systemName: p.flag("check") ? (done ? "checkmark.circle.fill" : "circle") : (p.flag("num") ? "\(i + 1).circle" : "circle.fill"))
                        .font(.system(size: p.flag("check") || p.flag("num") ? 14 : 5))
                        .foregroundStyle(done ? look.mint : look.accent)
                    Text(item).font(look.font(13, .semibold)).foregroundStyle(done ? look.inkSoft : look.ink)
                        .strikethrough(done).lineLimit(1)
                    Spacer(minLength: 0)
                }
                // Each row of a checklist is a toggle: it flips on the widget at once, then the agent hears it.
                if p.flag("check") {
                    Button(intent: WidgetTickIntent(agent: s.agentID, screen: s.name, part: p.ylID, item: item)) { row.contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                } else {
                    row
                }
            }
            if items.count > rows {
                Text("\(items.count - rows) more in Yui").font(look.font(11, .semibold)).foregroundStyle(look.inkSoft)
            }
        }
    }
}

struct TimerBody: View {
    let s: WidgetScreen, p: WidgetPart, look: WidgetLook, small: Bool

    /// The first phase of the timer, as it reads before it starts.
    static func clock(_ p: WidgetPart) -> String {
        if p.flag("up") { return "0:00" }
        return TimerActivityAttributes.clock(p.number("work") ?? 60, up: false)
    }

    /// The clock: counting on its own while the timer runs (one entry, no reloads), still when it does not.
    @ViewBuilder static func time(_ p: WidgetPart, size: Double, look: WidgetLook) -> some View {
        let font = look.font(size, .heavy).monospacedDigit()
        if p.liveKey != nil, let end = p.endsAt, end > .now {
            Text(timerInterval: Date.now...end, countsDown: true).font(font)
        } else if p.liveKey != nil {
            Text(p.endsAt == nil ? "Paused" : "0:00").font(font)
        } else {
            Text(clock(p)).font(font)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(p.string("label") ?? "Timer").font(look.font(13, .heavy)).foregroundStyle(look.inkSoft).lineLimit(1)
            Self.time(p, size: small ? 38 : 44, look: look).foregroundStyle(look.ink)
            if let rounds = p.number("rounds"), rounds > 1 {
                Text("\(Int(rounds)) rounds").font(look.font(12, .semibold)).foregroundStyle(look.inkSoft)
            }
            button
        }
    }

    /// Start, Pause, Resume. Start and Pause run in the app (a Live Activity intent): the lock screen and the
    /// Dynamic Island carry the clock from then on.
    @ViewBuilder private var button: some View {
        if let key = p.liveKey {
            Button(intent: TimerToggleIntent(id: key)) { pill(p.endsAt == nil ? "Resume" : "Pause") }.buttonStyle(.plain)
        } else {
            Button(intent: WidgetTimerStartIntent(agent: s.agentID, screen: s.name, part: p.ylID)) { pill("Start") }.buttonStyle(.plain)
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text).font(look.font(12, .heavy)).foregroundStyle(look.onAccent)
            .padding(.horizontal, 12).padding(.vertical, 5).background(look.accent, in: Capsule())
    }
}

struct CardBody: View {
    let s: WidgetScreen, p: WidgetPart, look: WidgetLook, small: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let tag = p.string("tag") { Text(tag).font(look.font(11, .heavy)).foregroundStyle(look.accent) }
            Text(p.string("title") ?? "").font(look.font(small ? 16 : 18, .heavy)).foregroundStyle(look.ink).lineLimit(small ? 3 : 2)
            if !small, let b = p.string("body") { Text(b).font(look.font(13, .medium)).foregroundStyle(look.inkSoft).lineLimit(2) }
            if let sub = p.string("sub") { Text(sub).font(look.font(12, .semibold)).foregroundStyle(look.inkSoft).lineLimit(1) }
            WidgetCTA(s: s, p: p, look: look)
        }
    }
}

struct TableBody: View {
    let p: WidgetPart, look: WidgetLook, rows: Int

    var body: some View {
        let all = p.props["rows"]?.array ?? []
        VStack(alignment: .leading, spacing: 3) {
            Text(p.string("name") ?? p.string("title") ?? "Table").font(look.font(13, .heavy)).foregroundStyle(look.inkSoft).lineLimit(1)
            if rows == 0 || p.props["rows"] == nil {
                Text(p.props["rows"] == nil ? "Open in Yui" : "\(all.count) rows").font(look.font(22, .heavy)).foregroundStyle(look.ink)
            } else {
                ForEach(Array(all.suffix(rows).enumerated()), id: \.offset) { _, r in
                    Text((r.array ?? []).map { $0.string ?? ($0.number.map { String(format: "%g", $0) } ?? "") }.joined(separator: "  "))
                        .font(look.font(12, .semibold)).foregroundStyle(look.ink).lineLimit(1)
                }
            }
        }
    }
}

struct TimelineBody: View {
    let s: WidgetScreen, look: WidgetLook, rows: Int

    struct Row { let kind: String; let text: String }

    static func rows(_ s: WidgetScreen) -> [Row] {
        s.parts.filter { ["done", "now", "next"].contains($0.preset) }.map {
            Row(kind: $0.preset, text: $0.string("title") ?? $0.string("text") ?? $0.string("label") ?? "")
        }
    }

    var body: some View {
        let all = Self.rows(s)
        let now = all.firstIndex { $0.kind == "now" } ?? 0
        let shown = Array(all.dropFirst(now).prefix(rows))
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 6) {
                    Circle().fill(r.kind == "now" ? look.accent : look.inkSoft).frame(width: 7, height: 7)
                    Text(r.text).font(look.font(r.kind == "now" ? 15 : 13, r.kind == "now" ? .heavy : .semibold))
                        .foregroundStyle(r.kind == "now" ? look.ink : look.inkSoft).lineLimit(1)
                }
            }
        }
    }
}
