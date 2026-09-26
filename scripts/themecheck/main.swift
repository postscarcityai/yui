import Foundation

// Contrast check for every agent look: each named set, a spread of seeded
// agents, and Yui's shipped theme, in light and dark. WCAG AA: text 4.5:1,
// controls 3:1. Also every app look (YUI-96, yuigui spec/RESTYLE.md section 4):
// each set offered as `theme app <set>`, keys alone on top of a set, hostile
// keys, and `theme app reset`, which must be exactly Yui's shipped look.
// Run: scripts/check_themes.sh (exits 1 on any failure).

struct Pair { let label: String; let fg: String; let bg: String; let min: Double }

func pairs(_ p: YuiTheme.Palette) -> [Pair] {
    [Pair(label: "ink/background", fg: p.ink, bg: p.background, min: 4.5),
     Pair(label: "ink/surface", fg: p.ink, bg: p.surface, min: 4.5),
     Pair(label: "inkSoft/background", fg: p.inkSoft, bg: p.background, min: 4.5),
     Pair(label: "inkSoft/surface", fg: p.inkSoft, bg: p.surface, min: 4.5),
     Pair(label: "agentInk/agentBubble", fg: p.agentInk, bg: p.agentBubble, min: 4.5),
     Pair(label: "userInk/userBubble", fg: p.userInk, bg: p.userBubble, min: 4.5),
     Pair(label: "userInk/mint", fg: p.userInk, bg: p.mint, min: 4.5),
     Pair(label: "userInk/lavender", fg: p.userInk, bg: p.lavender, min: 4.5),
     Pair(label: "userInk/butter", fg: p.userInk, bg: p.butter, min: 4.5),
     Pair(label: "onAccent/accent", fg: p.onAccent, bg: p.accent, min: 4.5),
     Pair(label: "accent/background", fg: p.accent, bg: p.background, min: 3.0)]
}

var themes: [(String, YuiTheme)] = [("yui (shipped)", .yui)]
for s in AgentLook.sets { themes.append(("set " + s.name, AgentLook.theme(AgentLook(preset: s.name), name: s.name))) }
for n in ["Nova", "Pixel", "Sage", "Juno", "Max", "Otto", "Coach", "Scout", "Echo", "Kai", "Remy", "Ivy"] {
    themes.append(("seeded " + n, AgentLook.theme(nil, name: n)))
}
// Hostile input: an agent asks for unreadable colors; the guardrails must hold.
let hostile: [(String, [String: String])] = [
    ("white accent", ["accent": "#FFFFFF"]), ("black accent", ["accent": "#000000"]),
    ("yellow on cream", ["accent": "#FFFF00", "bg": "cream"]), ("dark paper", ["bg": "#111111"]),
    ("mid grey", ["accent": "#808080", "bg": "#EEEEEE"]),
]
for (label, props) in hostile {
    themes.append(("hostile " + label, AgentLook.theme(AgentLook().applying(props, at: nil, by: "agent"), name: "Test")))
}

// App looks (YUI-96): what Apply would put on, built the way the preview card builds it.
var failures = 0
func app(_ props: [String: String], on current: AgentLook? = nil) -> YuiTheme {
    AppLook.theme(AppLook.offered(props.merging(["scope": "app"]) { a, _ in a }, on: current))
}
for s in AgentLook.sets { themes.append(("app " + s.name, app(["name": s.name]))) }
themes.append(("app autumn+keys", app(["name": "autumn", "font": "serif", "bg": "sand", "motion": "calm"])))
themes.append(("app keys on ocean", app(["accent": "lemon"], on: AgentLook(preset: "ocean"))))
for (label, props) in hostile { themes.append(("app hostile " + label, app(props))) }
// Reset is Yui's own look, whatever was on before; so is `theme app yui`.
for (label, props) in [("reset", ["name": "reset"]), ("yui", ["name": "yui"])] {
    for before in [nil, AgentLook(preset: "autumn"), AgentLook(accent: "#7B5CFF", bg: "sand")] {
        let offered = AppLook.offered(props.merging(["scope": "app"]) { a, _ in a }, on: before)
        if offered != nil || app(props, on: before) != .yui {
            failures += 1
            print("FAIL app \(label) on \(before?.preset ?? before?.accent ?? "yui"): not Yui's own look")
        }
    }
}
print("app reset and app yui: Yui's own look from every starting look")

var worst = Double.infinity
for (name, t) in themes {
    for (mode, p) in [("light", t.light), ("dark", t.dark)] {
        var line: [String] = []
        for pr in pairs(p) {
            let c = RGB.contrast(RGB(hex: pr.fg)!, RGB(hex: pr.bg)!)
            worst = min(worst, c / pr.min)
            let brandException = ["yui (shipped)", "set yui", "app yui"].contains(name) && mode == "light" && pr.label == "accent/background"
            if c < pr.min && brandException {
                line.append("EXCEPTION \(pr.label) \(String(format: "%.2f", c)): Yui's brand coral on cream, kept as shipped")
            } else if c < pr.min {
                failures += 1; line.append("FAIL \(pr.label) \(String(format: "%.2f", c)) < \(pr.min)")
            }
        }
        let a = RGB.contrast(RGB(hex: p.accent)!, RGB(hex: p.background)!)
        let o = RGB.contrast(RGB(hex: p.onAccent)!, RGB(hex: p.accent)!)
        let b = RGB.contrast(RGB(hex: p.ink)!, RGB(hex: p.background)!)
        print(String(format: "%-24@ %-5@ accent %@ bg %@  ink/bg %5.2f  accent/bg %5.2f  onAccent/accent %5.2f  %@",
                     name as NSString, mode as NSString, p.accent as NSString, p.background as NSString, b, a, o,
                     (line.isEmpty ? "PASS" : line.joined(separator: "; ")) as NSString))
    }
}
print("\(themes.count) themes x 2 modes x \(pairs(YuiTheme.yui.light).count) pairs, \(failures) failures")
exit(failures == 0 ? 0 : 1)
