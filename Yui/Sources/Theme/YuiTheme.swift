import SwiftUI

/// Every visual decision in the app, as plain Codable data.
/// Views read it from the environment and never hard-code a color, radius or spring,
/// so an agent can later hand the app a new token set as JSON and restyle it live.
struct YuiTheme: Codable, Equatable, Sendable {
    var name: String
    var light: Palette
    var dark: Palette
    var radius: Radii
    var spacing: Spacing
    var type: Typography
    var motion: Motion
    /// Agent handle -> palette token override for its avatar chip. Empty by default:
    /// each agent's color comes from the registry (yui_agents.color).
    var agents: [String: String]

    struct Palette: Codable, Equatable, Sendable {
        /// Hex strings, "#RRGGBB" or "#RRGGBBAA".
        var background: String
        var surface: String
        var ink: String
        var inkSoft: String
        var outline: String
        /// The wordmark coral. Tints the logo; `accent` follows it for primary controls.
        var brand: String
        var accent: String
        var mint: String
        var lavender: String
        var butter: String
        var userBubble: String
        var userInk: String
        var agentBubble: String
        var agentInk: String
    }

    struct Radii: Codable, Equatable, Sendable {
        var bubble: Double
        var bubbleTail: Double
        var pill: Double
        var card: Double
        var avatar: Double
    }

    struct Spacing: Codable, Equatable, Sendable {
        var xs: Double
        var s: Double
        var m: Double
        var l: Double
        var xl: Double
    }

    struct Typography: Codable, Equatable, Sendable {
        /// "rounded" | "default" | "serif" | "monospaced"
        var design: String
        var body: Double
        var caption: Double
        var title: Double
        var display: Double
    }

    struct Motion: Codable, Equatable, Sendable {
        var springResponse: Double
        var springDamping: Double
        /// Scale a tapped control pops to before settling.
        var bounceScale: Double
    }

    func palette(for scheme: ColorScheme) -> Palette { scheme == .dark ? dark : light }
}

extension YuiTheme {
    /// Default look: Korean stationery cute. Cream paper, soft plum ink, the coral wordmark
    /// as the one brand color, pastels as supporting accents.
    static let yui = YuiTheme(
        name: "yui",
        light: Palette(
            background: "#FFF9F0", surface: "#FFFFFF", ink: "#3A3340", inkSoft: "#8C8294",
            outline: "#F0E4D6", brand: "#FF7E8A", accent: "#FF7E8A", mint: "#BDEBD6",
            lavender: "#D9CCF7", butter: "#FFE8A3", userBubble: "#FFA8B0", userInk: "#3A3340",
            agentBubble: "#FFFFFF", agentInk: "#3A3340"),
        dark: Palette(
            background: "#231D33", surface: "#2F2842", ink: "#F6EEF7", inkSoft: "#A99FB8",
            outline: "#3D3452", brand: "#FF7E8A", accent: "#FF7E8A", mint: "#9FCDB9",
            lavender: "#B8ABDD", butter: "#E6D08F", userBubble: "#F28D97", userInk: "#2A2238",
            agentBubble: "#352D4A", agentInk: "#F6EEF7"),
        radius: Radii(bubble: 22, bubbleTail: 8, pill: 26, card: 28, avatar: 18),
        spacing: Spacing(xs: 4, s: 8, m: 12, l: 16, xl: 24),
        type: Typography(design: "rounded", body: 17, caption: 13, title: 20, display: 28),
        motion: Motion(springResponse: 0.35, springDamping: 0.55, bounceScale: 1.18),
        agents: [:]
    )
}

// MARK: - SwiftUI bridges

extension EnvironmentValues {
    @Entry var yuiTheme: YuiTheme = .yui
}

extension YuiTheme {
    var fontDesign: Font.Design {
        switch type.design {
        case "serif": .serif
        case "monospaced": .monospaced
        case "default": .default
        default: .rounded
        }
    }

    func font(_ size: Double, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: fontDesign)
    }

    /// Unmapped agents get a stable pastel picked from their name.
    func agentColorToken(for name: String) -> String {
        if let token = agents[name.lowercased()] { return token }
        let pastels = ["mint", "lavender", "butter"]
        return pastels[name.lowercased().unicodeScalars.reduce(0) { $0 + Int($1.value) } % pastels.count]
    }

    var spring: Animation {
        .spring(response: motion.springResponse, dampingFraction: motion.springDamping)
    }
}

extension Color {
    /// Parses "#RRGGBB" or "#RRGGBBAA". Bad input renders magenta so it is easy to spot.
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard let v = UInt64(s, radix: 16), s.count == 6 || s.count == 8 else {
            self = Color(red: 1, green: 0, blue: 1)
            return
        }
        let rgba = s.count == 6 ? (v << 8) | 0xFF : v
        self = Color(
            red: Double((rgba >> 24) & 0xFF) / 255,
            green: Double((rgba >> 16) & 0xFF) / 255,
            blue: Double((rgba >> 8) & 0xFF) / 255,
            opacity: Double(rgba & 0xFF) / 255)
    }
}

/// System / Light / Dark, persisted under `appearance`.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// A palette resolved to SwiftUI colors for the current scheme.
struct Swatch {
    let background, surface, ink, inkSoft, outline, brand, accent, mint, lavender, butter: Color
    let userBubble, userInk, agentBubble, agentInk: Color

    init(_ p: YuiTheme.Palette) {
        background = Color(hex: p.background); surface = Color(hex: p.surface)
        ink = Color(hex: p.ink); inkSoft = Color(hex: p.inkSoft); outline = Color(hex: p.outline)
        brand = Color(hex: p.brand); accent = Color(hex: p.accent); mint = Color(hex: p.mint)
        lavender = Color(hex: p.lavender); butter = Color(hex: p.butter)
        userBubble = Color(hex: p.userBubble); userInk = Color(hex: p.userInk)
        agentBubble = Color(hex: p.agentBubble); agentInk = Color(hex: p.agentInk)
    }
}

extension Swatch {
    /// Looks up a color by its palette token name. Unknown names fall back to `lavender`.
    func color(token: String) -> Color {
        switch token {
        case "brand": brand
        case "accent": accent
        case "mint": mint
        case "butter": butter
        case "userBubble": userBubble
        case "agentBubble": agentBubble
        case "surface": surface
        default: lavender
        }
    }
}

extension YuiTheme {
    func swatch(_ scheme: ColorScheme) -> Swatch { Swatch(palette(for: scheme)) }
}
