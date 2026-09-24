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

    init() {}

    init(_ text: String) {
        for node in YuiLines.parse(text) { apply(node) }
    }

    mutating func apply(_ node: YLNode) {
        switch node.op {
        case .add:
            serial += 1
            components.append(YLComponent(serial: serial, ylID: node.id ?? "n\(serial)", preset: node.preset ?? "say",
                                          screen: node.screen, props: node.props ?? [:], line: node.line))
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
                c = YLComponent(serial: serial, ylID: c.ylID, preset: c.preset, screen: node.screen, props: c.props, line: c.line)
                components.append(c)
            }
        case .focus:
            break
        case .theme:
            looks.append((node.props ?? [:]).compactMapValues { v in v.string ?? v.number.map(YLComponent.format) })
        case .error:
            errors.append(node)
        }
    }

    var isEmpty: Bool { components.isEmpty && errors.isEmpty && looks.isEmpty }
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

    static func format(_ n: Double) -> String {
        n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n)
    }
}
