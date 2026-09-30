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
            // A timer started from the widget or Siri keeps running through a republish.
            var screens = screens
            for i in screens.indices {
                for j in screens[i].parts.indices {
                    guard let was = old.first(where: { $0.name == screens[i].name })?.parts.first(where: { $0.ylID == screens[i].parts[j].ylID }) else { continue }
                    screens[i].parts[j].liveKey = was.liveKey
                    screens[i].parts[j].endsAt = was.endsAt
                }
            }
            guard old != screens else { return }
            snap.screens.removeAll { $0.agentID == agent.id }
            snap.screens += screens
            changed = true
        }
        if changed {
            WidgetCenter.shared.reloadAllTimelines()
            // Spotlight and Siri know the new names, and the relay the new lasting ids.
            Task {
                await WidgetIndex.reindex(WidgetStore.read())
                YuiShortcuts.updateAppShortcutParameters()
                if let account = WidgetApp.account { await WidgetRegistry.sync(account: account) }
            }
        }
    }

    /// Signed out, or an agent removed: its copies go with it.
    static func clear(agentID: String? = nil) {
        WidgetStore.update { snap in
            if let agentID { snap.screens.removeAll { $0.agentID == agentID } } else { snap = WidgetSnapshot() }
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    #if DEBUG
    /// `-yuiWidgetsReset` (UI tests): the app group starts empty, once per launch.
    static func resetIfAsked() {
        guard ProcessInfo.processInfo.arguments.contains("-yuiWidgetsReset") else { return }
        WidgetStore.write(WidgetSnapshot())
        if let dir = WidgetGroup.url {
            for n in ["yui-widget-queue.json", "yui-widget-ticks.json"] { try? FileManager.default.removeItem(at: dir.appending(path: n)) }
        }
        WidgetSecrets.token = nil
    }
    #endif

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
