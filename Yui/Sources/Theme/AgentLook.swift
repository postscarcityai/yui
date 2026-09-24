import Foundation

/// One agent's look, as stored in `yui_agents.theme` (spec: yuigui/spec/AGENTS.md).
/// A small recipe, not a token set: the app compiles it into a full `YuiTheme`
/// (light + dark) with `AgentLook.theme(...)`, and the guardrails run there, so
/// nothing an agent or a person writes can make text unreadable.
/// Every field is optional. An empty look means "this agent's own default",
/// seeded from its name so no two agents start out alike.
struct AgentLook: Codable, Equatable, Sendable {
    /// A named set (`AgentLook.sets`), stored as `preset`. Fields below override it.
    var preset: String?
    /// "#RRGGBB".
    var accent: String?
    /// Light-mode paper, "#RRGGBB". Dark mode is derived from the accent.
    var bg: String?
    /// "round" | "soft" | "square" | a number of points.
    var radius: String?
    /// "rounded" | "default" | "serif" | "mono"
    var font: String?
    /// Headings and names: "regular" | "bold" | "heavy"
    var weight: String?
    /// "bouncy" | "calm" | "snappy"
    var motion: String?
    /// Preferred screens: screen=chat|full, gallery=row|feed|row3d|grid,
    /// chart=line|bar|area|scatter|pie|donut, buttons=row|stack.
    var style: [String: String]?
    /// When it was set (the theme line's message time, or when the person picked it)
    /// and by whom ("agent" | "user"). An older theme line never overrides a newer pick.
    var at: String?
    var by: String?

    enum CodingKeys: String, CodingKey {
        case preset, accent, bg, radius, font, weight, motion, style, at, by
    }

    init(preset: String? = nil, accent: String? = nil, bg: String? = nil, radius: String? = nil,
         font: String? = nil, weight: String? = nil, motion: String? = nil, style: [String: String]? = nil,
         at: String? = nil, by: String? = nil) {
        self.preset = preset; self.accent = accent; self.bg = bg; self.radius = radius; self.font = font
        self.weight = weight; self.motion = motion; self.style = style; self.at = at; self.by = by
    }

    /// Forgiving: the column is plain jsonb, so a field of the wrong type is
    /// dropped instead of failing the whole agent list.
    init(from decoder: Decoder) throws {
        self.init()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        func str(_ k: CodingKeys) -> String? {
            if let s = try? c.decode(String.self, forKey: k) { return s }
            if let n = try? c.decode(Double.self, forKey: k) { return n == n.rounded() ? String(Int(n)) : String(n) }
            return nil
        }
        preset = str(.preset); accent = str(.accent); bg = str(.bg); radius = str(.radius); font = str(.font)
        weight = str(.weight); motion = str(.motion); at = str(.at); by = str(.by)
        style = try? c.decode([String: String].self, forKey: .style)
    }

    var isEmpty: Bool {
        preset == nil && accent == nil && bg == nil && radius == nil && font == nil && weight == nil && motion == nil
    }
}

// MARK: - Vocabulary

extension AgentLook {
    struct Recipe: Sendable {
        var accent: String
        var bg: String? = nil
        var radius = "soft"
        var font = "rounded"
        var weight = "heavy"
        var motion = "bouncy"
    }

    /// Named sets, in picker order. The last six are personality sets (a coach, a wizard,
    /// a lawyer...); an agent whose handle matches a set name starts in that set.
    static let sets: [(name: String, recipe: Recipe)] = [
        ("yui", Recipe(accent: "#FF7E8A", bg: "#FFF9F0", radius: "yui")),
        ("coral", Recipe(accent: "#FF6F7D", bg: "#FFF6F4", radius: "round")),
        ("peach", Recipe(accent: "#FF9466", bg: "#FFF7F1", radius: "round")),
        ("sunset", Recipe(accent: "#F2663A", bg: "#FFF4EC", radius: "soft", motion: "snappy")),
        ("autumn", Recipe(accent: "#C8642B", bg: "#F7F0E6", radius: "soft", font: "serif", weight: "bold", motion: "calm")),
        ("lemon", Recipe(accent: "#E5B800", bg: "#FFFBEA", radius: "round")),
        ("matcha", Recipe(accent: "#7FA650", bg: "#F6F8EF", radius: "round", motion: "calm")),
        ("forest", Recipe(accent: "#2F7D4F", bg: "#F2F6F1", radius: "soft", font: "default", weight: "bold", motion: "calm")),
        ("mint", Recipe(accent: "#2FB58C", bg: "#F0FAF6", radius: "round")),
        ("ocean", Recipe(accent: "#1E86C8", bg: "#F1F7FC", radius: "soft", font: "default", weight: "bold", motion: "calm")),
        ("sky", Recipe(accent: "#4AA8F0", bg: "#F2F8FF", radius: "round")),
        ("lavender", Recipe(accent: "#9B87F5", bg: "#F7F4FF", radius: "round")),
        ("berry", Recipe(accent: "#B8336A", bg: "#FCF2F6", radius: "soft", weight: "bold")),
        ("candy", Recipe(accent: "#FF5FAE", bg: "#FFF1F7", radius: "round", motion: "bouncy")),
        ("midnight", Recipe(accent: "#5B6CFF", bg: "#F1F2FF", radius: "soft", font: "default", weight: "bold", motion: "snappy")),
        ("mono", Recipe(accent: "#4A4A4A", bg: "#FFFFFF", radius: "square", font: "default", weight: "bold", motion: "snappy")),
        ("wizard", Recipe(accent: "#7B5CFF", bg: "#F6F4FF", radius: "soft", font: "serif", weight: "bold", motion: "calm")),
        ("coach", Recipe(accent: "#FF5A36", bg: "#FFF6F2", radius: "square", font: "default", weight: "heavy", motion: "snappy")),
        ("zen", Recipe(accent: "#4E9A6B", bg: "#F5F8F2", radius: "round", font: "serif", weight: "regular", motion: "calm")),
        ("studio", Recipe(accent: "#2F7BFF", bg: "#F3F7FF", radius: "round", font: "rounded", weight: "heavy", motion: "bouncy")),
        ("night", Recipe(accent: "#8A7CF0", bg: "#F7F5FF", radius: "round", font: "serif", weight: "bold", motion: "calm")),
        ("counsel", Recipe(accent: "#1F3A68", bg: "#FAF8F3", radius: "square", font: "serif", weight: "bold", motion: "calm")),
    ]

    static func recipe(_ name: String) -> Recipe? { sets.first { $0.name == name.lowercased() }?.recipe }

    static let papers = ["cream": "#FFF9F0", "paper": "#FBFAF7", "white": "#FFFFFF", "mist": "#F3F6FA",
                         "sand": "#F7F0E6", "blush": "#FFF1F3"]
    static let radii = ["round", "soft", "square"]
    static let fonts = ["rounded", "default", "serif", "mono"]
    static let weights = ["regular", "bold", "heavy"]
    static let motions = ["bouncy", "calm", "snappy"]
    static let styleKeys: [String: [String]] = [
        "screen": ["chat", "full"],
        "gallery": ["row", "feed", "row3d", "grid"],
        "chart": ["line", "bar", "area", "scatter", "pie", "donut"],
        "buttons": ["row", "stack"],
    ]

    /// Seeded defaults: a stable pick per name, so a new agent is instantly its own.
    private static let seedAccents = ["#FF6F7D", "#FF9466", "#E5A100", "#7FA650", "#2FB58C", "#1FA2B8",
                                      "#1E86C8", "#5B6CFF", "#7B5CFF", "#B061E0", "#E0508F", "#C8642B"]
    private static let seedPapers = ["#FFF9F0", "#FBFAF7", "#F3F6FA", "#F7F0E6", "#FFF1F3", "#F4F8F2"]

    static func seeded(_ name: String) -> Recipe {
        var h: UInt64 = 0xcbf29ce484222325 // FNV-1a, stable across launches (unlike Hasher)
        for b in name.lowercased().utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        func pick<T>(_ a: [T], _ salt: UInt64) -> T { a[Int((h / salt) % UInt64(a.count))] }
        return Recipe(accent: pick(seedAccents, 1), bg: pick(seedPapers, 13), radius: pick(radii, 101),
                      font: pick(["rounded", "rounded", "default", "serif"], 1009),
                      weight: pick(["heavy", "bold"], 10007), motion: pick(motions, 100003))
    }
}

// MARK: - Theme lines

extension AgentLook {
    /// Applies a YL `theme` line's props (spec YL.md, "theme"). A set name starts fresh,
    /// `reset` goes back to the seeded default, keys change only what they say.
    /// Anything unknown is ignored. The style profile survives a new set.
    func applying(_ props: [String: String], at: String?, by: String) -> AgentLook {
        var o = self
        if let name = props["name"]?.lowercased().trimmingCharacters(in: .whitespaces) {
            if name == "reset" || name == "default" {
                o = AgentLook(style: style)
            } else if Self.recipe(name) != nil {
                o = AgentLook(preset: name, style: style)
            }
        }
        if let v = props["accent"] {
            if let hex = Self.hex(v) { o.accent = hex } else if let r = Self.recipe(v) { o.accent = r.accent }
        }
        if let v = props["bg"] {
            if let hex = Self.hex(v) { o.bg = hex } else if let p = Self.papers[v.lowercased()] { o.bg = p }
        }
        if let v = props["radius"]?.lowercased() {
            if Self.radii.contains(v) { o.radius = v } else if let n = Double(v), n >= 0 { o.radius = Self.num(min(n, 28)) }
        }
        if let v = props["font"]?.lowercased() {
            let f = v == "monospaced" ? "mono" : v
            if Self.fonts.contains(f) { o.font = f }
        }
        if let v = props["weight"]?.lowercased(), Self.weights.contains(v) { o.weight = v }
        if let v = props["motion"]?.lowercased(), Self.motions.contains(v) { o.motion = v }
        for (k, allowed) in Self.styleKeys {
            if let v = props[k]?.lowercased(), allowed.contains(v) {
                var s = o.style ?? [:]
                s[k] = v
                o.style = s
            }
        }
        o.at = at
        o.by = by
        return o
    }

    static func hex(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("#"), t.count == 7, UInt32(t.dropFirst(), radix: 16) != nil else { return nil }
        return t.uppercased()
    }

    private static func num(_ n: Double) -> String { n == n.rounded() ? String(Int(n)) : String(n) }
}

// MARK: - Compiling a look into a theme

extension AgentLook {
    /// The full theme for an agent. `name` seeds the default; `isYui` keeps Yui's own
    /// shipped look pixel for pixel when its look is empty.
    static func theme(_ look: AgentLook?, name: String, isYui: Bool = false) -> YuiTheme {
        let look = look ?? AgentLook()
        if look.isEmpty && isYui || look.preset == "yui" && look.isOnlySet { return .yui }
        var r = look.preset.flatMap(recipe) ?? (isYui ? recipe("yui")! : recipe(name) ?? seeded(name))
        if let v = look.accent { r.accent = v }
        if let v = look.bg { r.bg = v }
        if let v = look.radius { r.radius = v }
        if let v = look.font { r.font = v }
        if let v = look.weight { r.weight = v }
        if let v = look.motion { r.motion = v }
        return compile(r, name: look.preset ?? name.lowercased())
    }

    private var isOnlySet: Bool {
        accent == nil && bg == nil && radius == nil && font == nil && weight == nil && motion == nil
    }

    static func compile(_ r: Recipe, name: String) -> YuiTheme {
        let accent = RGB(hex: r.accent) ?? RGB(hex: "#FF7E8A")!
        let h = accent.hsl.h
        let sat = accent.hsl.s
        let yui = YuiTheme.yui

        // Light paper must stay paper: very light, never a dark background.
        var paper = RGB(hex: r.bg ?? "") ?? RGB(h: h, s: 0.70, l: 0.975)
        if paper.hsl.l < 0.93 { paper = RGB(h: paper.hsl.h, s: paper.hsl.s, l: 0.93) }

        func palette(dark: Bool) -> YuiTheme.Palette {
            let base = dark ? yui.dark : yui.light
            let bg = dark ? RGB(h: h, s: min(0.32, sat), l: 0.13) : paper
            let surface = dark ? RGB(h: h, s: min(0.26, sat), l: 0.19) : RGB(h: h, s: 0.5, l: 0.995)
            let outline = dark ? RGB(h: h, s: min(0.22, sat), l: 0.28) : RGB(h: h, s: min(0.45, sat), l: 0.90)
            let darkInk = RGB(h: h, s: min(0.30, sat), l: 0.15)
            let ink = (dark ? RGB(h: h, s: min(0.35, sat), l: 0.95) : RGB(h: h, s: min(0.22, sat), l: 0.22))
                .readable(on: [bg, surface], min: Guard.text)
            let inkSoft = (dark ? RGB(h: h, s: 0.14, l: 0.70) : RGB(h: h, s: 0.10, l: 0.46))
                .readable(on: [bg, surface], min: Guard.text)

            // Accent: a control against the paper (3:1), and it carries text (4.5:1).
            // Move it away from the paper until both hold; its ink is whichever of
            // white or dark ink reads better on it.
            var acc = accent.movedAway(from: bg, min: Guard.control)
            var onAccent = RGB.better(of: [.white, darkInk], on: acc)
            if RGB.contrast(onAccent, acc) < Guard.text {
                acc = dark ? acc.lighten(until: { RGB.contrast(darkInk, $0) >= Guard.text })
                           : acc.darken(until: { RGB.contrast(.white, $0) >= Guard.text })
                onAccent = RGB.better(of: [.white, darkInk], on: acc)
            }

            let userBubble = dark ? RGB(h: h, s: max(0.45, min(0.8, sat)), l: 0.72) : RGB(h: h, s: max(0.5, min(0.9, sat)), l: 0.86)
            let pastels = [RGB(hex: base.mint)!, RGB(hex: base.lavender)!, RGB(hex: base.butter)!]
            let userInk = darkInk.readable(on: [userBubble] + pastels, min: Guard.text)
            let agentBubble = dark ? RGB(h: h, s: min(0.24, sat), l: 0.22) : surface
            let agentInk = ink.readable(on: [agentBubble], min: Guard.text)

            return YuiTheme.Palette(
                background: bg.hex, surface: surface.hex, ink: ink.hex, inkSoft: inkSoft.hex,
                outline: outline.hex, brand: acc.hex, accent: acc.hex, mint: base.mint,
                lavender: base.lavender, butter: base.butter, userBubble: userBubble.hex, userInk: userInk.hex,
                agentBubble: agentBubble.hex, agentInk: agentInk.hex, onAccent: onAccent.hex)
        }

        let radius: YuiTheme.Radii = switch r.radius {
        case "yui": yui.radius
        case "round": .init(bubble: 24, bubbleTail: 8, pill: 28, card: 30, avatar: 22)
        case "square": .init(bubble: 10, bubbleTail: 4, pill: 12, card: 12, avatar: 8)
        case "soft": .init(bubble: 18, bubbleTail: 6, pill: 22, card: 22, avatar: 14)
        default:
            // A number: clamped to a scale that still reads as a bubble.
            { n in .init(bubble: n, bubbleTail: max(3, n / 3), pill: n + 4, card: n + 6, avatar: max(6, n * 0.8)) }(
                min(28, max(4, Double(r.radius) ?? 18)))
        }
        let motion: YuiTheme.Motion = switch r.motion {
        case "calm": .init(springResponse: 0.55, springDamping: 0.9, bounceScale: 1.04)
        case "snappy": .init(springResponse: 0.22, springDamping: 0.75, bounceScale: 1.1)
        default: yui.motion
        }
        var type = yui.type
        type.design = r.font == "mono" ? "monospaced" : (fonts.contains(r.font) ? r.font : "rounded")
        type.weight = weights.contains(r.weight) ? r.weight : "heavy"

        return YuiTheme(name: name, light: palette(dark: false), dark: palette(dark: true), radius: radius,
                        spacing: yui.spacing, type: type, motion: motion, agents: [:])
    }

    /// WCAG AA: body text 4.5:1, UI controls 3:1, plus a little headroom so
    /// rounding to 8-bit hex never lands a hair under the line.
    enum Guard {
        static let text = 4.6
        static let control = 3.1
    }
}

// MARK: - Color math (sRGB, WCAG 2 relative luminance)

struct RGB: Equatable, Sendable {
    var r, g, b: Double

    static let white = RGB(r: 1, g: 1, b: 1)

    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    init?(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard s.count == 6 || s.count == 8, let v = UInt64(s.prefix(6), radix: 16) else { return nil }
        r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255; b = Double(v & 0xFF) / 255
    }

    init(h: Double, s: Double, l: Double) {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double) = switch hp {
        case ..<1: (c, x, 0)
        case ..<2: (x, c, 0)
        case ..<3: (0, c, x)
        case ..<4: (0, x, c)
        case ..<5: (x, 0, c)
        default: (c, 0, x)
        }
        let m = l - c / 2
        r = r1 + m; g = g1 + m; b = b1 + m
    }

    var hex: String {
        func c(_ v: Double) -> String { String(format: "%02X", Int((min(1, max(0, v)) * 255).rounded())) }
        return "#" + c(r) + c(g) + c(b)
    }

    var hsl: (h: Double, s: Double, l: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        let h: Double = switch mx {
        case r: (g - b) / d + (g < b ? 6 : 0)
        case g: (b - r) / d + 2
        default: (r - g) / d + 4
        }
        return (h * 60, s, l)
    }

    var luminance: Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let x = a.luminance, y = b.luminance
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    static func better(of options: [RGB], on bg: RGB) -> RGB {
        options.max { contrast($0, bg) < contrast($1, bg) }!
    }

    private func withL(_ l: Double) -> RGB { let x = hsl; return RGB(h: x.h, s: x.s, l: min(1, max(0, l))) }

    func darken(until ok: (RGB) -> Bool) -> RGB {
        var c = self, l = hsl.l
        while !ok(c), l > 0 { l -= 0.01; c = withL(l) }
        return c
    }

    func lighten(until ok: (RGB) -> Bool) -> RGB {
        var c = self, l = hsl.l
        while !ok(c), l < 1 { l += 0.01; c = withL(l) }
        return c
    }

    /// Moves lightness away from `bg` until the contrast holds.
    func movedAway(from bg: RGB, min: Double) -> RGB {
        bg.luminance > 0.18 ? darken { RGB.contrast($0, bg) >= min } : lighten { RGB.contrast($0, bg) >= min }
    }

    /// Adjusts this ink until it reads on every background given.
    func readable(on bgs: [RGB], min: Double) -> RGB {
        let ok: (RGB) -> Bool = { c in bgs.allSatisfy { RGB.contrast(c, $0) >= min } }
        if ok(self) { return self }
        let avg = bgs.map(\.luminance).reduce(0, +) / Double(bgs.count)
        return avg > 0.18 ? darken(until: ok) : lighten(until: ok)
    }
}
