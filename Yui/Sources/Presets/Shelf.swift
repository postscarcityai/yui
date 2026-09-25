import Foundation
import SwiftUI
import YuiLines

// Saved screens and the shelf (YUI-32, spec yuigui/spec/YL.md section 5).
// `save workout` keeps a screen under a name; `show workout` brings it back
// fresh in a later reply for two tokens; the person taps it on the shelf at
// the top of the thread for none. The shelf is rebuilt from the thread as it
// loads and kept on the phone per agent, so it outlives the 90-day retention.

/// A screen the agent saved, as it stood: its components with their patches merged in.
struct SavedScreen: Codable, Equatable, Sendable {
    struct Part: Codable, Equatable, Sendable {
        var ylID: String
        var preset: String
        var screen: String
        var props: [String: YLValue]
        var line: String
        var inGroup: String?
    }

    var name: String
    var parts: [Part]
    /// Saved from the stage (`>full` ... `save name`): it opens on the stage again.
    var stage: Bool
    /// When the reply that saved it was written. A newer save of the name wins.
    var at: Date = .distantPast

    init(name: String, components: [YLComponent], stage: Bool) {
        self.name = name
        self.parts = components.map {
            Part(ylID: $0.ylID, preset: $0.preset, screen: $0.screen, props: $0.props, line: $0.line, inGroup: $0.inGroup)
        }
        self.stage = stage
    }
}

/// What a reply did to the shelf, in line order.
enum ShelfOp: Equatable, Sendable {
    case save(SavedScreen)
    case forget(String)
}

/// One agent's saved screens, plus the ones the person took off by hand.
struct Shelf: Codable, Equatable, Sendable {
    private(set) var entries: [String: SavedScreen] = [:]
    /// Name -> when the person removed it. Only a save written after that brings it back.
    private var removed: [String: Date] = [:]

    /// Newest first, the order the bar shows them in.
    var screens: [SavedScreen] { entries.values.sorted { $0.at == $1.at ? $0.name < $1.name : $0.at > $1.at } }

    subscript(name: String) -> SavedScreen? { entries[name] }

    /// Applies a reply's save or forget, stamped with the reply's time. History
    /// replays on every open, so an op older than what is already here is a no-op.
    @discardableResult
    mutating func apply(_ op: ShelfOp, at: Date) -> Bool {
        switch op {
        case .save(var s):
            if let r = removed[s.name], r >= at { return false }
            if let old = entries[s.name], old.at >= at { return false }
            s.at = at
            entries[s.name] = s
            return true
        case .forget(let name):
            guard let old = entries[name], old.at <= at else { return false }
            entries[name] = nil
            return true
        }
    }

    /// The person held it and chose Remove.
    mutating func remove(_ name: String, at: Date = .now) {
        entries[name] = nil
        removed[name] = at
    }

    // MARK: On the phone

    static func file(agentID: String) -> URL {
        URL.applicationSupportDirectory.appending(path: "yui-shelf-\(agentID).json")
    }

    static func load(agentID: String) -> Shelf {
        guard let data = try? Data(contentsOf: file(agentID: agentID)),
              let shelf = try? JSONDecoder().decode(Shelf.self, from: data) else { return Shelf() }
        return shelf
    }

    func store(agentID: String) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        try? data.write(to: Self.file(agentID: agentID), options: .atomic)
    }
}

extension YLScreen {
    /// Puts a saved screen back, fresh, tagged with its name so events carry
    /// `saved`. Saved from the stage, it goes back on the stage; otherwise on `screen`.
    mutating func restore(_ s: SavedScreen, on screen: String) {
        let to = s.stage ? "full" : screen
        restore(s.parts.map { p in
            YLComponent(serial: 0, ylID: p.ylID, preset: p.preset, screen: to, props: p.props, line: p.line,
                        inGroup: p.inGroup, saved: s.name)
        }, on: to)
    }
}

/// The shelf at the top of the thread: the agent's saved screens as chips.
/// A tap reopens one on the stage with no turn; hold for Remove.
struct ShelfBar: View {
    let screens: [SavedScreen]
    let open: (String) -> Void
    let remove: (String) -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: theme.spacing.s) {
                ForEach(screens, id: \.name) { s in
                    Button { open(s.name) } label: {
                        Label(s.name, systemImage: s.stage || s.parts.contains(where: \.isWorkout) ? "figure.run" : "star.fill")
                            .font(theme.font(theme.type.caption, .bold))
                            .foregroundStyle(c.ink)
                            .padding(.horizontal, theme.spacing.m)
                            .padding(.vertical, theme.spacing.s)
                            .background(c.accent.opacity(0.16), in: Capsule())
                            .overlay(Capsule().stroke(c.accent.opacity(0.35), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Remove", systemImage: "minus.circle", role: .destructive) { remove(s.name) }
                    }
                    .accessibilityLabel("Open \(s.name)")
                    .accessibilityHint("Saved screen. Opens full screen.")
                }
            }
            .padding(.horizontal, theme.spacing.l)
            .padding(.vertical, theme.spacing.s)
        }
        .background(c.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Saved screens")
        .accessibilityIdentifier("shelf")
    }
}

extension SavedScreen.Part {
    var isWorkout: Bool { YuiLines.isWorkout(preset: preset, props: props) }
}
