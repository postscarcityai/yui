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
        /// Take the screen saved as `name` off the shelf.
        case forget
        /// Empty the screen.
        case clear
        /// Bare `>S`: later lines go to `screen`.
        case focus
        /// `end`: close the open group (deck, plan, narrate); `target` is its id.
        case end
        /// Restyle the agent's look: `props` (a named set in `props.name`). No id, no event.
        case theme
        /// `close` or bare `>chat`: close the stage; later lines go to screen 1. Screen is `full`.
        case close
        /// `>2 talk`: page 2 keeps the composer; `props.on` false (`talk off`) takes it away.
        case talk
        /// `menu review@dana "Invite Dana?"`: an item in the agent's drawer, `id` and
        /// `props` {bucket, label, sub?, say?, show?, url?}; `menu done dana` gives props {done: true}.
        case menu
        /// The line was rejected: `message`. Every other line still renders.
        case error
    }

    public var op: Op
    public var screen: String
    public var preset: String?
    public var id: String?
    public var target: String?
    public var name: String?
    /// The open group this add joined (a page under a deck): the group's id.
    public var inGroup: String?
    /// Only what the line said. Defaults are the renderer's job.
    public var props: [String: YLValue]?
    public var message: String?
    /// The source line, for logs.
    public var line: String

    enum CodingKeys: String, CodingKey {
        case op, screen, preset, id, target, name, inGroup = "in", props, message, line
    }

    public init(op: Op, screen: String, preset: String? = nil, id: String? = nil, target: String? = nil,
                name: String? = nil, inGroup: String? = nil, props: [String: YLValue]? = nil,
                message: String? = nil, line: String) {
        self.op = op
        self.screen = screen
        self.preset = preset
        self.id = id
        self.target = target
        self.name = name
        self.inGroup = inGroup
        self.props = props
        self.message = message
        self.line = line
    }
}
