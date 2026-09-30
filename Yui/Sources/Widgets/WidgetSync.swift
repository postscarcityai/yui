import Foundation
import WidgetKit
import YuiLines

// Keeps the widget's copy of the saved screens current (YUI-40, spec WIDGETS.md section 3).
// The app writes the parsed parts of each agent's shelf into the app group whenever the
// shelf changes; the widget only reads it. A change reloads the widget (free while the app runs).

@MainActor
enum WidgetSync {
    /// One agent's shelf, written over that agent's older copies. `at` is when the agent last changed each screen.
    static func publish(agent: YuiAgent, shelf: Shelf) {
        let theme = agent.yuiTheme
        let screens = shelf.screens.map { saved in
            WidgetScreen(
                agentID: agent.id, agentName: agent.name, name: saved.name,
                parts: saved.parts.map { p in
                    let ticked = p.preset == "list"
                        ? Array(ListTicks.shared.ticked(agent.id, p.ylID, items: YLValue.strings(p.props["items"]))) : []
                    return WidgetPart(ylID: p.ylID, preset: p.preset, props: p.props, ticked: ticked.sorted())
                },
                light: theme.light, dark: theme.dark, design: theme.type.design, at: saved.at)
        }
        var changed = false
        WidgetStore.update { snap in
            let old = snap.screens.filter { $0.agentID == agent.id }
            guard old != screens else { return }
            snap.screens.removeAll { $0.agentID == agent.id }
            snap.screens += screens
            changed = true
        }
        if changed { WidgetCenter.shared.reloadAllTimelines() }
    }

    /// Signed out, or an agent removed: its copies go with it.
    static func clear(agentID: String? = nil) {
        WidgetStore.update { snap in
            if let agentID { snap.screens.removeAll { $0.agentID == agentID } } else { snap = WidgetSnapshot() }
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// "Pin as widget": the edit sheet offers this screen first.
    static func pinNext(agent: String, name: String) {
        WidgetStore.update { $0.pinNext = "\(agent)/\(name)" }
    }
}

extension YLValue {
    static func strings(_ v: YLValue?) -> [String] {
        (v?.array ?? []).compactMap { $0.string }
    }
}
