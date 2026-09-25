import Foundation
import YuiLines

// What an agent put in its drawer (YUI-86, spec yuigui/spec/YL.md section 5,
// The drawer): `menu review|backlog|shortcut` items, and `menu done id`. Kept on
// the phone per agent and rebuilt from the thread as it loads, like the shelf.

struct AgentMenu: Codable, Equatable, Sendable {
    private(set) var lists = YLMenu()
    /// The newest reply applied. History replays on every open, so an older reply is skipped.
    private var at: Date = .distantPast

    var review: [YLMenuItem] { lists.review }
    var backlog: [YLMenuItem] { lists.backlog }
    var shortcuts: [YLMenuItem] { lists.shortcut }

    /// One reply's `menu` lines, in order. A reply as new as the last one applied
    /// is applied again whole, which gives the same lists.
    mutating func apply(_ nodes: [YLNode], at: Date) {
        guard at >= self.at else { return }
        self.at = at
        lists = YuiLines.menu(nodes, into: lists)
    }

    /// The person held it and chose Remove.
    mutating func remove(_ id: String) {
        lists.apply(YLNode(op: .menu, screen: "1", id: id, props: ["done": .bool(true)], line: "menu done \(id)"))
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
