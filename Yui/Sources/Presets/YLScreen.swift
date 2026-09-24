import Foundation
import YuiLines

/// One live component on screen: an `add` line with its patches merged in.
struct YLComponent: Identifiable, Equatable, Sendable {
    /// Render identity. YL ids can repeat (`timer@hiit` twice), so views key on this.
    let serial: Int
    /// The YL id events go back under: `@id` from the line, or `n1`, `c2`, ...
    let ylID: String
    let preset: String
    var screen: String
    var props: [String: YLValue]
    var line: String
    /// The group head's YL id when this add joined a deck, plan or narrate.
    var inGroup: String? = nil

    var id: Int { serial }
}

/// Screen state for one agent reply. Applies parser nodes in order the way
/// spec section 5 describes: adds, patches, clear, save/show. The chat is one
/// column, so every screen renders in line order.
struct YLScreen: Equatable, Sendable {
    private(set) var components: [YLComponent] = []
    private(set) var errors: [YLNode] = []
    /// `theme` lines in this reply, in order. They restyle the agent, not the screen.
    private(set) var looks: [[String: String]] = []
    private var saved: [String: [YLComponent]] = [:]
    private var serial = 0
    /// The component count when the last `close` line landed. Staged components
    /// at or under it arrived before the agent closed the stage (spec section 5).
    private(set) var closedAt = 0

    init() {}

    init(_ text: String) {
        for node in YuiLines.parse(text) { apply(node) }
    }

    mutating func apply(_ node: YLNode) {
        switch node.op {
        case .add:
            serial += 1
            components.append(YLComponent(serial: serial, ylID: node.id ?? "n\(serial)", preset: node.preset ?? "say",
                                          screen: node.screen, props: node.props ?? [:], line: node.line,
                                          inGroup: node.inGroup))
        case .patch:
            let target = node.target ?? ""
            guard let i = components.lastIndex(where: { $0.ylID == target || $0.preset == target }) else {
                errors.append(YLNode(op: .error, screen: node.screen, message: "patch: \"\(target)\" is not on screen",
                                     line: node.line))
                return
            }
            components[i].props.merge(node.props ?? [:]) { $1 }
        case .clear:
            components.removeAll { $0.screen == node.screen }
        case .save:
            saved[node.name ?? ""] = components.filter { $0.screen == node.screen }
        case .show:
            guard let shot = saved[node.name ?? ""] else {
                errors.append(YLNode(op: .error, screen: node.screen, message: "show: nothing saved as \"\(node.name ?? "")\"",
                                     line: node.line))
                return
            }
            components.removeAll { $0.screen == node.screen }
            for var c in shot {
                serial += 1
                c = YLComponent(serial: serial, ylID: c.ylID, preset: c.preset, screen: node.screen, props: c.props, line: c.line,
                                inGroup: c.inGroup)
                components.append(c)
            }
        case .focus, .end:
            // Group membership rides on each add (`inGroup`), so `end` has nothing left to do here.
            break
        case .close:
            closedAt = serial
        case .theme:
            looks.append((node.props ?? [:]).compactMapValues { v in v.string ?? v.number.map(YLComponent.format) })
        case .error:
            errors.append(node)
        }
    }

    var isEmpty: Bool { components.isEmpty && errors.isEmpty && looks.isEmpty }

    /// Whether a patch aimed at `target` (an id or a preset name) lands here.
    func has(_ target: String) -> Bool {
        components.contains { $0.ylID == target || $0.preset == target }
    }

    /// Something on the stage the agent has not closed again.
    func wantsStage(_ style: [String: String]) -> Bool {
        top.contains { $0.serial > closedAt && $0.onStage(style) }
    }

    /// Components drawn on their own: everything but group members, which their
    /// head draws (a page inside its deck). A member whose head is gone stands alone.
    var top: [YLComponent] { components.filter { head(of: $0) == nil } }

    /// The group head `c` joined: the newest head before it with that id.
    func head(of c: YLComponent) -> YLComponent? {
        guard let g = c.inGroup else { return nil }
        return components.last { $0.serial < c.serial && $0.ylID == g && YLComponent.groupHeads.contains($0.preset) }
    }
}

extension YLComponent {
    static let groupHeads: Set<String> = ["deck", "plan", "narrate"]
}

extension Array where Element == YLComponent {
    /// The members of group head `head`, in line order.
    func members(of head: YLComponent) -> [YLComponent] {
        let next = first { $0.serial > head.serial && $0.ylID == head.ylID && $0.preset == head.preset }?.serial ?? .max
        return filter { $0.inGroup == head.ylID && $0.serial > head.serial && $0.serial < next }
    }

    /// The newest inline table called `id` (by YL id or by name), for `chart data=id`.
    func table(_ id: String) -> YLComponent? {
        last { $0.preset == "table" && ($0.ylID == id || $0.string("name") == id) && $0.props["cols"] != nil }
    }
}

/// How a reply lays out: components alone, consecutive `step` lines as one
/// stepper (spec: step), and on the chat side each run of staged ones as one pill.
enum YLItem: Identifiable {
    case one(YLComponent)
    case steps([YLComponent])
    case pill([YLComponent])

    var id: String {
        switch self {
        case .one(let c): "c\(c.serial)"
        case .steps(let cs): "s\(cs[0].serial)"
        case .pill(let cs): "p\(cs[0].serial)"
        }
    }

    /// `pills` nil lays everything out in place (the stage); with a style,
    /// staged components fold into pills (the chat).
    static func layout(_ components: [YLComponent], pills style: [String: String]?) -> [YLItem] {
        var out: [YLItem] = []
        for c in components {
            if let style, c.onStage(style) {
                if case .pill(let run) = out.last { out[out.count - 1] = .pill(run + [c]) } else { out.append(.pill([c])) }
            } else if c.preset == "step" {
                if case .steps(let run) = out.last, run.last?.screen == c.screen {
                    out[out.count - 1] = .steps(run + [c])
                } else {
                    out.append(.steps([c]))
                }
            } else {
                out.append(.one(c))
            }
        }
        return out
    }
}

/// One interaction going back to the agent: `{id, preset, ...value}` (spec section 7).
struct YLEvent: Sendable {
    var id: String
    var preset: String
    var value: [String: YLValue]
    /// What the chat shows as the user's reply, or nil for quiet events (timer ticks, checklist taps).
    var echo: String?

    var json: String {
        var o = value
        o["id"] = .string(id)
        o["preset"] = .string(preset)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(YLValue.object(o))).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// How a preset view hands an event to whoever hosts it (the chat, the paste box).
struct YLEmit: Sendable {
    var send: @MainActor @Sendable (YLEvent) -> Void = { _ in }
    @MainActor func callAsFunction(_ e: YLEvent) { send(e) }
}

extension YLComponent {
    func string(_ key: String) -> String? { props[key]?.string }
    func number(_ key: String) -> Double? { props[key]?.number }
    func flag(_ key: String) -> Bool { props[key]?.bool ?? false }
    func strings(_ key: String) -> [String]? {
        props[key]?.array?.compactMap { v in v.string ?? v.number.map { YLComponent.format($0) } }
    }

    func event(_ value: [String: YLValue], echo: String? = nil) -> YLEvent {
        YLEvent(id: ylID, preset: preset, value: value, echo: echo)
    }

    /// An answer event. Answers can change (spec section 7): every one after the
    /// first carries `changed: true`, and the agent treats the newest as the answer.
    func answer(_ value: [String: YLValue], echo: String, changed: Bool) -> YLEvent {
        var value = value
        if changed { value["changed"] = .bool(true) }
        return event(value, echo: echo)
    }

    /// `+lock`: the agent froze this component. The answer shown stays, taps do nothing.
    var locked: Bool { flag("lock") }

    static func format(_ n: Double) -> String {
        n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n)
    }
}
