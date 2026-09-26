import Foundation

/// Yui's own look (YUI-43, spec: yuigui/spec/RESTYLE.md): what everything that
/// is nobody's thread wears, the agent list, sheets, Settings, sign-in and Yui's
/// own thread. Any agent the person owns can offer one with `theme app ...`; only
/// the person's tap puts it on. Stored as `yui_users.look`, cached on the phone.
/// Plain Foundation, so scripts/check_themes.sh compiles it with bare swiftc.
struct AppLookState: Equatable, Sendable {
    /// The recipe on now. Nil: Yui's own shipped look (coral on cream).
    var look: AgentLook?
    /// What Undo goes back to, one step. `AgentLook()` is Yui's own; nil, nothing to undo.
    var prev: AgentLook?
    /// Settings > Look, "Agents keep their own looks". Off: every thread wears this look too.
    var agentsKeepLooks = true
    /// The agent whose card was applied; nil when it came from Settings.
    var via: String?
    /// When it was set, ISO-8601.
    var at: String?

    /// Yui's own look, nothing to undo.
    static let yui = AppLookState()
}

extension AppLookState {
    /// The `yui_users.look` shape: the recipe's keys flat, `prev` one level deep.
    /// `null` (nil here) only when it is Yui's own look with the default switch.
    var json: [String: Any]? {
        if look == nil, prev == nil, agentsKeepLooks { return nil }
        var o = Self.recipe(look)
        if let prev { o["prev"] = Self.recipe(prev) }
        o["agents_keep_looks"] = agentsKeepLooks
        if let via { o["via"] = via }
        if let at { o["at"] = at }
        return o
    }

    init(json: [String: Any]?) {
        self.init()
        guard let json else { return }
        look = Self.look(json)
        prev = (json["prev"] as? [String: Any]).map { Self.look($0) ?? AgentLook() }
        agentsKeepLooks = json["agents_keep_looks"] as? Bool ?? true
        via = json["via"] as? String
        at = json["at"] as? String
    }

    private static let keys = ["preset", "accent", "bg", "radius", "font", "weight", "motion"]

    private static func recipe(_ l: AgentLook?) -> [String: Any] {
        guard let l else { return [:] }
        let values = [l.preset, l.accent, l.bg, l.radius, l.font, l.weight, l.motion]
        var o: [String: Any] = [:]
        for (k, v) in zip(keys, values) { if let v { o[k] = v } }
        return o
    }

    private static func look(_ o: [String: Any]) -> AgentLook? {
        let v = keys.map { o[$0] as? String }
        let l = AgentLook(preset: v[0], accent: v[1], bg: v[2], radius: v[3], font: v[4], weight: v[5], motion: v[6])
        return l.isEmpty ? nil : l
    }
}

// MARK: - What a `theme app` line offers

enum AppLook {
    /// The full theme for an app look: Yui's own when nil or empty.
    static func theme(_ look: AgentLook?) -> YuiTheme { AgentLook.theme(look, name: "yui", isYui: true) }

    /// The look a `theme app` line's props would put on, on top of `current`.
    /// A set starts fresh, keys alone change only what they say, `reset` is Yui's own (nil).
    /// The parser already refused anything unknown, so the preview is exactly what Apply does.
    static func offered(_ props: [String: String], on current: AgentLook?) -> AgentLook? {
        var keys = props
        keys["scope"] = nil
        let name = keys["name"]?.lowercased()
        if name == "reset" { return nil }
        let base = name != nil ? AgentLook() : (current ?? AgentLook())
        var o = base.applying(keys, at: nil, by: "user")
        o.at = nil; o.by = nil; o.style = nil
        if o.isEmpty || o == AgentLook(preset: "yui") { return nil }
        return o
    }

    /// The words on the card: "autumn", "Yui's own look", or "this look" for keys alone.
    static func label(_ props: [String: String]) -> String {
        switch props["name"]?.lowercased() {
        case "reset": "Yui's own look"
        case let name?: name
        case nil: "this look"
        }
    }

    /// What a look is called in Settings.
    static func name(_ look: AgentLook?) -> String {
        guard let look else { return "Yui's own" }
        if let p = look.preset, look.accent == nil, look.bg == nil { return p.prefix(1).uppercased() + p.dropFirst() }
        return "Your own mix"
    }

    /// One line naming what the guard moved, or nil when nothing moved
    /// (RESTYLE.md section 4): the preview already shows the adjusted colors.
    static func guardNote(_ look: AgentLook?, props: [String: String]) -> String? {
        guard let look, look.preset != "yui" || look.accent != nil else { return nil }
        let asked = look.accent.flatMap { AgentLook.hex($0) ?? AgentLook.recipe($0)?.accent }
            ?? look.preset.flatMap { AgentLook.recipe($0)?.accent }
        guard let asked, let want = RGB(hex: asked)?.hex else { return nil }
        let t = theme(look)
        let light = t.light.accent != want, dark = t.dark.accent != want
        let color: String = {
            if let a = props["accent"], AgentLook.recipe(a) != nil { return a.prefix(1).uppercased() + a.dropFirst() }
            if props["accent"] != nil { return "Your color" }
            return look.preset.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "The color"
        }()
        switch (light, dark) {
        case (true, true): return "\(color) was adjusted in light and dark so text on it stays readable."
        case (true, false): return "\(color) was darkened so text on buttons stays readable."
        case (false, true): return "In dark mode \(color.lowercased()) was lightened so it stands out."
        default: return nil
        }
    }
}
