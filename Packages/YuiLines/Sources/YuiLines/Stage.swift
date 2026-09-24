/// The stage (spec `yuigui/spec/YL.md` section 5, "The stage"): a full-screen
/// layer over the chat for moments that deserve the whole phone.
extension YuiLines {
    /// Presets that open on the stage unless they say `+inline`.
    public static let stagePresets: Set<String> = ["timer", "camera", "mic", "deck", "plan"]

    /// A timer with rounds or rest. Workouts always open on the stage.
    public static func isWorkout(preset: String, props: [String: YLValue]) -> Bool {
        guard preset == "timer", props["up"]?.bool != true else { return false }
        return (props["rounds"]?.number ?? 1) > 1 || (props["rest"]?.number ?? 0) > 0
    }

    /// Whether an added component opens on the stage. `style` is the agent's
    /// style profile (`screen=chat|full`, `gallery=...`). Mirrors `onStage`
    /// in the JS reference parser.
    public static func opensOnStage(preset: String, screen: String, props: [String: YLValue],
                                    style: [String: String] = [:]) -> Bool {
        if screen == "full" { return true }
        if isWorkout(preset: preset, props: props) { return true }
        if props["inline"]?.bool == true { return false }
        if style["screen"] == "chat" { return false }
        if style["screen"] == "full" { return true }
        if stagePresets.contains(preset) { return true }
        return preset == "gallery" && (props["layout"]?.string ?? style["gallery"]) == "row3d"
    }

    /// `opensOnStage` for a parsed node: only adds can open on the stage.
    public static func opensOnStage(_ node: YLNode, style: [String: String] = [:]) -> Bool {
        guard node.op == .add, let preset = node.preset else { return false }
        return opensOnStage(preset: preset, screen: node.screen, props: node.props ?? [:], style: style)
    }
}
