import AppIntents
import CoreSpotlight
import Foundation
import YuiLines

// Pinned saved screens, as the widget draws them (YUI-40, spec yuigui/spec/WIDGETS.md).
// Compiled into the app and the widget extension. The app writes the copy into the
// app group; the widget and the App Intents only read it (the widget buttons of step 3
// write through `WidgetStore.update`).

enum WidgetGroup {
    static let id = "group.com.yuigui.app"
    static var url: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) }
    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }
}

/// One component of a saved screen: the parsed props, never raw lines.
struct WidgetPart: Codable, Equatable, Sendable {
    var ylID: String
    var preset: String
    var props: [String: YLValue]
    /// A checklist's ticked items (kept on the phone, YUI-183).
    var ticked: [String] = []
    /// A timer started from the widget or Siri: the Live Activity's key while it exists, and when the
    /// running phase ends (nil while paused). The widget shows Pause and a counting clock from these.
    var liveKey: String?
    var endsAt: Date?

    func string(_ k: String) -> String? {
        switch props[k] {
        case .string(let s): s
        case .number(let n): n.rounded() == n ? String(Int(n)) : String(n)
        default: nil
        }
    }

    func number(_ k: String) -> Double? { props[k]?.number }
    func flag(_ k: String) -> Bool { props[k]?.bool ?? false }
    func list(_ k: String) -> [String] {
        (props[k]?.array ?? []).compactMap { v in
            switch v {
            case .string(let s): s
            case .number(let n): n.rounded() == n ? String(Int(n)) : String(n)
            default: nil
            }
        }
    }
    func numbers(_ k: String) -> [Double] {
        if let n = props[k]?.number { return [n] }
        return (props[k]?.array ?? []).compactMap { $0.number ?? Double($0.string ?? "") }
    }
}

/// A saved screen pinned (or pinnable) as a widget, with the look of the agent that saved it.
struct WidgetScreen: Codable, Equatable, Sendable, Identifiable {
    var agentID: String
    var agentName: String
    var name: String
    var parts: [WidgetPart]
    var light: YuiTheme.Palette
    var dark: YuiTheme.Palette
    var design: String
    /// When the agent last changed it (the save or the newest patch the phone saw).
    var at: Date
    var id: String { "\(agentID)/\(name)" }

    func palette(dark isDark: Bool) -> YuiTheme.Palette { isDark ? dark : light }

    /// Components a widget can draw; the rest are a title and an Open button.
    static let drawn: Set<String> = ["stat", "chart", "list", "timer", "card", "timeline", "table"]
}

struct WidgetSnapshot: Codable, Equatable, Sendable {
    var screens: [WidgetScreen] = []
    /// The saved screen the person held and chose "Pin as widget" on: the edit sheet offers it first.
    var pinNext: String?
}

enum WidgetStore {
    static var file: URL? { WidgetGroup.url?.appending(path: "yui-widgets.json") }

    static func read() -> WidgetSnapshot {
        guard let file, let data = try? Data(contentsOf: file),
              let snap = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return WidgetSnapshot() }
        return snap
    }

    static func write(_ snap: WidgetSnapshot) {
        guard let file, let data = try? JSONEncoder().encode(snap) else { return }
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func update(_ change: (inout WidgetSnapshot) -> Void) {
        var snap = read()
        change(&snap)
        write(snap)
    }

    static func screen(agent: String, name: String) -> WidgetScreen? {
        read().screens.first { $0.agentID == agent && $0.name == name }
    }

    /// A widget row was tapped: flips the item in the copy (spec section 5, "right away on the widget") and
    /// returns the new state, or nil when the screen, list or item is not there.
    static func toggleTick(agent: String, screen: String, part: String, item: String) -> (screen: WidgetScreen, part: WidgetPart, checked: Bool)? {
        var out: (WidgetScreen, WidgetPart, Bool)?
        update { snap in
            guard let si = snap.screens.firstIndex(where: { $0.agentID == agent && $0.name == screen }),
                  let pi = snap.screens[si].parts.firstIndex(where: { $0.ylID == part && $0.preset == "list" }),
                  snap.screens[si].parts[pi].list("items").contains(item) else { return }
            var on = Set(snap.screens[si].parts[pi].ticked)
            let checked = !on.contains(item)
            if checked { on.insert(item) } else { on.remove(item) }
            snap.screens[si].parts[pi].ticked = on.sorted()
            out = (snap.screens[si], snap.screens[si].parts[pi], checked)
        }
        return out
    }
}

/// A tick made on the widget, for the app to apply to its own list ticks the next time it runs (the
/// widget process cannot reach the app's UserDefaults).
struct WidgetTick: Codable, Equatable, Sendable {
    var agentID: String
    var partID: String
    var item: String
    var checked: Bool
    var at: Date
}

enum WidgetTickLog {
    private static var file: URL? { WidgetGroup.url?.appending(path: "yui-widget-ticks.json") }

    static func add(_ t: WidgetTick) {
        var all = take(clear: false)
        all.append(t)
        guard let file, let data = try? JSONEncoder().encode(Array(all.suffix(200))) else { return }
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Everything waiting, oldest first; the app clears it once applied.
    static func take(clear: Bool = true) -> [WidgetTick] {
        guard let file, let data = try? Data(contentsOf: file), let all = try? JSONDecoder().decode([WidgetTick].self, from: data) else { return [] }
        if clear { try? FileManager.default.removeItem(at: file) }
        return all
    }
}

// MARK: Entities (names only, YUI-40 step 2)

struct AgentEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Agent"
    static let defaultQuery = AgentQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct AgentQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [AgentEntity] {
        all().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [AgentEntity] { all() }
    func entities(matching string: String) async throws -> [AgentEntity] {
        all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
    private func all() -> [AgentEntity] {
        var seen = Set<String>()
        return WidgetStore.read().screens.compactMap { s in
            seen.insert(s.agentID).inserted ? AgentEntity(id: s.agentID, name: s.agentName) : nil
        }
    }
}

struct ScreenEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Saved screen"
    static let defaultQuery = ScreenQuery()
    var id: String
    var agentID: String
    var agentName: String
    var name: String
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(agentName)")
    }
}

struct ScreenQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ScreenEntity] {
        all().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [ScreenEntity] {
        let snap = WidgetStore.read()
        var list = all()
        // The one the person pinned from the shelf comes first.
        if let next = snap.pinNext, let i = list.firstIndex(where: { $0.id == next }) { list.insert(list.remove(at: i), at: 0) }
        return list
    }
    func entities(matching string: String) async throws -> [ScreenEntity] {
        all().filter { $0.name.localizedCaseInsensitiveContains(string) || $0.agentName.localizedCaseInsensitiveContains(string) }
    }
    func defaultResult() async -> ScreenEntity? {
        let snap = WidgetStore.read()
        let first = snap.pinNext.flatMap { id in all().first { $0.id == id } }
        return first ?? all().first
    }
    private func all() -> [ScreenEntity] {
        WidgetStore.read().screens.map { ScreenEntity(id: $0.id, agentID: $0.agentID, agentName: $0.agentName, name: $0.name) }
    }
}

/// A saved screen that holds a timer, for "Start Tabata in Yui" (spec section 6). The id is agent/screen/part.
struct TimerEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Timer"
    static let defaultQuery = TimerQuery()
    var id: String
    var agentID: String
    var screen: String
    var part: String
    var name: String
    var agentName: String
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(agentName)")
    }
}

struct TimerQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [TimerEntity] { all().filter { identifiers.contains($0.id) } }
    func suggestedEntities() async throws -> [TimerEntity] { all() }
    func entities(matching string: String) async throws -> [TimerEntity] {
        all().filter { $0.name.localizedCaseInsensitiveContains(string) || $0.screen.localizedCaseInsensitiveContains(string) }
    }
    private func all() -> [TimerEntity] { Self.timers(in: WidgetStore.read()) }

    static func timers(in snap: WidgetSnapshot) -> [TimerEntity] {
        snap.screens.flatMap { s in
            s.parts.filter { $0.preset == "timer" }.map { p in
                TimerEntity(id: "\(s.id)/\(p.ylID)", agentID: s.agentID, screen: s.name, part: p.ylID,
                            name: p.string("label") ?? s.name, agentName: s.agentName)
            }
        }
    }
}
