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
        /// Text and icons drawn on an `accent` fill (send button, primary buttons).
        var onAccent: String
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
        /// "default" (SF Pro, Yui's base) | "rounded" | "serif" | "monospaced"
        var design: String
        var body: Double
        var caption: Double
        var title: Double
        var display: Double
        /// Headings and names: "regular" | "semibold" | "bold" | "heavy"
        var weight: String
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
            background: "#FFF9F0", surface: "#FFFFFF", ink: "#3A3340", inkSoft: "#6E6478",
            outline: "#F0E4D6", brand: "#FF7E8A", accent: "#FF7E8A", mint: "#BDEBD6",
            lavender: "#D9CCF7", butter: "#FFE8A3", userBubble: "#FFA8B0", userInk: "#3A3340",
            agentBubble: "#FFFFFF", agentInk: "#3A3340", onAccent: "#3A3340"),
        dark: Palette(
            background: "#231D33", surface: "#2F2842", ink: "#F6EEF7", inkSoft: "#A99FB8",
            outline: "#3D3452", brand: "#FF7E8A", accent: "#FF7E8A", mint: "#9FCDB9",
            lavender: "#B8ABDD", butter: "#E6D08F", userBubble: "#F28D97", userInk: "#2A2238",
            agentBubble: "#352D4A", agentInk: "#F6EEF7", onAccent: "#2A2238"),
        radius: Radii(bubble: 22, bubbleTail: 8, pill: 26, card: 28, avatar: 18),
        spacing: Spacing(xs: 4, s: 8, m: 12, l: 16, xl: 24),
        // YUI-211: a sleek sans base. SF Pro (the system face), semibold headings, the scale in YuiType.
        type: Typography(design: "default", body: 17, caption: 13, title: 22, display: 34, weight: "semibold"),
        motion: Motion(springResponse: 0.35, springDamping: 0.55, bounceScale: 1.18),
        agents: [:]
    )
}

// MARK: - SwiftUI bridges

// A plain key, not `@Entry`: the macro needs Xcode's plugin, and
// scripts/check_themes.sh compiles this file with bare swiftc.
private struct YuiThemeKey: EnvironmentKey {
    static let defaultValue = YuiTheme.yui
}

extension EnvironmentValues {
    var yuiTheme: YuiTheme {
        get { self[YuiThemeKey.self] }
        set { self[YuiThemeKey.self] = newValue }
    }
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

    /// A size on the Yui type scale (YuiType), set in the theme's design and scaled with Dynamic Type.
    func font(_ size: Double, _ weight: Font.Weight = .regular) -> Font {
        guard let style = YuiType.style(for: size) else {
            return .system(size: size, weight: weight, design: fontDesign)
        }
        return .system(style, design: fontDesign, weight: weight)
    }

    /// The heading weight this theme wears (agent names, titles).
    var strong: Font.Weight {
        switch type.weight {
        case "regular": .medium
        case "semibold": .semibold
        case "bold": .bold
        default: .heavy
        }
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
    let userBubble, userInk, agentBubble, agentInk, onAccent: Color

    init(_ p: YuiTheme.Palette) {
        background = Color(hex: p.background); surface = Color(hex: p.surface)
        ink = Color(hex: p.ink); inkSoft = Color(hex: p.inkSoft); outline = Color(hex: p.outline)
        brand = Color(hex: p.brand); accent = Color(hex: p.accent); mint = Color(hex: p.mint)
        lavender = Color(hex: p.lavender); butter = Color(hex: p.butter)
        userBubble = Color(hex: p.userBubble); userInk = Color(hex: p.userInk)
        agentBubble = Color(hex: p.agentBubble); agentInk = Color(hex: p.agentInk)
        onAccent = Color(hex: p.onAccent)
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


/// The Yui type scale (YUI-211). Sizes are points at the default text size; each rides a system
/// text style, so the whole scale follows the person's text size setting up to the accessibility sizes.
/// display 34, title1 28, title2 22, headline 17 semibold, body 17, callout 15, subhead 15,
/// caption 13, footnote 12. Line spacing is tighter on display and looser on caption.
enum YuiType: CaseIterable {
    case display, title1, title2, headline, body, callout, subhead, caption, footnote

    var size: Double {
        switch self {
        case .display: 34
        case .title1: 28
        case .title2: 22
        case .headline, .body: 17
        case .callout, .subhead: 15
        case .caption: 13
        case .footnote: 12
        }
    }

    var textStyle: Font.TextStyle {
        switch self {
        case .display: .largeTitle
        case .title1: .title
        case .title2: .title2
        case .headline: .headline
        case .body: .body
        case .callout, .subhead: .subheadline
        case .caption: .footnote
        case .footnote: .caption
        }
    }

    /// Extra points between lines, on top of the face's own.
    var lineSpacing: Double {
        switch self {
        case .display: -1
        case .title1, .title2: 0
        case .headline, .body: 2
        case .callout, .subhead: 2
        case .caption, .footnote: 3
        }
    }

    /// Points of tracking: tighter on display, looser on caption.
    var tracking: Double {
        switch self {
        case .display: -0.6
        case .title1: -0.4
        case .title2: -0.2
        case .headline, .body: 0
        case .callout, .subhead: 0.1
        case .caption: 0.2
        case .footnote: 0.3
        }
    }

    /// The text style for a literal size: the scale's own, or the nearest one within a point
    /// (16 and 14 ride callout and subhead, 20 and 21 ride title3). Nil for numerals and icon glyphs
    /// outside the text range, which stay fixed.
    static func style(for size: Double) -> Font.TextStyle? {
        switch size {
        case 33...35: .largeTitle
        case 27...29: .title
        case 21.5...22.5: .title2
        case 19.5...21.5: .title3
        case 16.5...18.5: .body
        case 15.5...16.5: .callout
        case 13.5...15.5: .subheadline
        case 12.5...13.5: .footnote
        case 11.5...12.5: .caption
        case 10.5...11.5: .caption2
        default: nil
        }
    }
}

extension View {
    /// A scale token as a font plus its line spacing. Tracking rides Text via `yuiTracking`.
    func yuiText(_ token: YuiType, _ theme: YuiTheme, weight: Font.Weight? = nil) -> some View {
        font(.system(token.textStyle, design: theme.fontDesign, weight: weight ?? (token == .headline ? .semibold : .regular)))
            .lineSpacing(token.lineSpacing)
    }
}

extension Text {
    /// The scale token's tracking; tabular numbers for counters and timers.
    func yuiTracking(_ token: YuiType, tabular: Bool = false) -> Text {
        let t = tracking(token.tracking)
        return tabular ? t.monospacedDigit() : t
    }
}
