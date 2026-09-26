import Foundation
import YuiLines

// What an agent put in its drawer (YUI-86, spec yuigui/spec/YL.md section 5,
// The drawer): `menu review|backlog|shortcut` items, and `menu done id`. Kept on
// the phone per agent and rebuilt from the thread as it loads, like the shelf.

struct AgentMenu: Codable, Equatable, Sendable {
    private(set) var lists = YLMenu()
    /// The newest reply applied. History replays on every open, so an older reply is skipped.
    private var at: Date = .distantPast

    /// Review items the person tapped: the agent has them now, so they stop waiting
    /// (feedback AI3Pbaid). They stay in the drawer until `menu done`; a later line
    /// putting the same id back makes it wait again.
    private(set) var seen: Set<String> = []

    var review: [YLMenuItem] { lists.review }
    /// Review items still waiting on the person.
    var waiting: [YLMenuItem] { lists.review.filter { !seen.contains($0.id) } }
    var backlog: [YLMenuItem] { lists.backlog }
    var shortcuts: [YLMenuItem] { lists.shortcut }

    /// One reply's `menu` lines, in order. A reply as new as the last one applied
    /// is applied again whole, which gives the same lists.
    mutating func apply(_ nodes: [YLNode], at: Date) {
        guard at >= self.at else { return }
        self.at = at
        lists = YuiLines.menu(nodes, into: lists)
        seen.subtract(nodes.compactMap(\.id))
    }

    /// The person tapped a review item: it went to the agent.
    mutating func markSeen(_ id: String) {
        if lists.review.contains(where: { $0.id == id }) { seen.insert(id) }
    }

    /// The person held it and chose Remove.
    mutating func remove(_ id: String) {
        lists.apply(YLNode(op: .menu, screen: "1", id: id, props: ["done": .bool(true)], line: "menu done \(id)"))
        seen.remove(id)
    }

    init() {}

    // Files written before `seen` have no key for it.
    private enum CodingKeys: String, CodingKey { case lists, at, seen }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lists = try c.decode(YLMenu.self, forKey: .lists)
        at = try c.decode(Date.self, forKey: .at)
        seen = try c.decodeIfPresent(Set<String>.self, forKey: .seen) ?? []
    }

    // MARK: On the phone

    static func file(agentID: String) -> URL {
        URL.applicationSupportDirectory.appending(path: "yui-menu-\(agentID).json")
    }

    static func load(agentID: String) -> AgentMenu {
        guard let data = try? Data(contentsOf: file(agentID: agentID)),
              let menu = try? JSONDecoder().decode(AgentMenu.self, from: data) else { return AgentMenu() }
        return menu
    }

    func store(agentID: String) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        try? data.write(to: Self.file(agentID: agentID), options: .atomic)
    }
}
