/// One parsed YL line. Mirrors the ops of the JS reference parser
/// (`yuigui/site/lib/yl/yl.mjs`); spec in `yuigui/spec/YL.md`.
public struct YLNode: Codable, Equatable, Sendable {
    public enum Op: String, Codable, Sendable {
        /// Add a component: `preset`, `id`, `props`.
        case add
        /// Update a live component: `target` (an id or a preset name), `props`.
        case patch
        /// Save the current screen under `name`.
        case save
        /// Restore the screen saved as `name`.
        case show
        /// Empty the screen.
        case clear
        /// Bare `>S`: later lines go to `screen`.
        case focus
        /// Restyle the agent's look: `props` (a named set in `props.name`). No id, no event.
        case theme
        /// The line was rejected: `message`. Every other line still renders.
        case error
    }

    public var op: Op
    public var screen: String
    public var preset: String?
    public var id: String?
    public var target: String?
    public var name: String?
    /// Only what the line said. Defaults are the renderer's job.
    public var props: [String: YLValue]?
    public var message: String?
    /// The source line, for logs.
    public var line: String

    public init(op: Op, screen: String, preset: String? = nil, id: String? = nil, target: String? = nil,
                name: String? = nil, props: [String: YLValue]? = nil, message: String? = nil, line: String) {
        self.op = op
        self.screen = screen
        self.preset = preset
        self.id = id
        self.target = target
        self.name = name
        self.props = props
        self.message = message
        self.line = line
    }
}
