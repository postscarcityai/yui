import AppIntents
import Foundation
import WidgetKit
import YuiLines

// The buttons on a saved screen's widget (YUI-40 step 3, spec WIDGETS.md section 5). Compiled into the
// app and the widget extension. A tick and a cta run in the widget's process: they change the copy in the
// app group at once (the widget redraws, and a reload after an intent does not count against the budget),
// then the event goes to the relay, or waits in the offline queue. Start on a timer is a Live Activity
// intent: it runs in the app, which owns the clock.

enum WidgetKinds {
    static let savedScreen = "YuiSavedScreen"
    static let talk = "com.yuigui.app.talk"
}

/// The edit sheet of a pinned widget: which saved screen, and the lock screen switch.
struct SavedScreenConfig: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Saved screen"
    static let description = IntentDescription("Pick one of your agent's saved screens.")

    @Parameter(title: "Saved screen") var screen: ScreenEntity?
    @Parameter(title: "Hide on the lock screen until unlocked", default: true) var hideOnLock: Bool
}

struct WidgetTickIntent: AppIntent {
    static let title: LocalizedStringResource = "Tick an item"
    static let isDiscoverable = false

    @Parameter(title: "Agent") var agent: String
    @Parameter(title: "Saved screen") var screen: String
    @Parameter(title: "List") var part: String
    @Parameter(title: "Item") var item: String

    init() {}
    init(agent: String, screen: String, part: String, item: String) {
        self.agent = agent; self.screen = screen; self.part = part; self.item = item
    }

    func perform() async throws -> some IntentResult {
        guard let r = WidgetStore.toggleTick(agent: agent, screen: screen, part: part, item: item) else { return .result() }
        WidgetTickLog.add(WidgetTick(agentID: agent, partID: part, item: item, checked: r.checked, at: .now))
        WidgetQueue.add(WidgetEvent.make(screen: r.screen, part: r.part,
                                         value: ["item": .string(item), "checked": .bool(r.checked)]))
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.savedScreen)
        await WidgetQueue.flush()
        return .result()
    }
}

struct WidgetCtaIntent: AppIntent {
    static let title: LocalizedStringResource = "Tap a button"
    static let isDiscoverable = false

    @Parameter(title: "Agent") var agent: String
    @Parameter(title: "Saved screen") var screen: String
    @Parameter(title: "Component") var part: String
    @Parameter(title: "Label") var label: String

    init() {}
    init(agent: String, screen: String, part: String, label: String) {
        self.agent = agent; self.screen = screen; self.part = part; self.label = label
    }

    func perform() async throws -> some IntentResult {
        guard let s = WidgetStore.screen(agent: agent, name: screen), let p = s.parts.first(where: { $0.ylID == part }) else { return .result() }
        WidgetQueue.add(WidgetEvent.make(screen: s, part: p, value: ["cta": .string(label)]))
        await WidgetQueue.flush()
        return .result()
    }
}

/// Where Start lands in the app process. Set by LiveTimer at launch; the widget process never runs the body.
@MainActor
enum WidgetTimerBridge {
    static var start: ((String, String, String) -> Void)?
}

struct WidgetTimerStartIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start the timer"
    static let isDiscoverable = false

    @Parameter(title: "Agent") var agent: String
    @Parameter(title: "Saved screen") var screen: String
    @Parameter(title: "Timer") var part: String

    init() {}
    init(agent: String, screen: String, part: String) {
        self.agent = agent; self.screen = screen; self.part = part
    }

    func perform() async throws -> some IntentResult {
        let (a, s, p) = (agent, screen, part)
        // A cold start for this intent: the app may not have wired the bridge yet, so wait for it (up to 3 s).
        for _ in 0..<12 {
            if await MainActor.run(body: { WidgetTimerBridge.start.map { $0(a, s, p); return true } ?? false }) { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return .result()
    }
}

/// "Talk to Yui": the Action button, Control Center and the lock screen open that agent's thread with
/// hands-free voice on (YUI-14). No agent picked means the default agent (Yui's own thread when none is marked).
struct TalkToAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to Yui"
    static let isDiscoverable = false

    @Parameter(title: "Agent") var agent: AgentEntity?

    init() {}
    init(agent: AgentEntity?) { self.agent = agent }

    static func link(agent id: String?) -> URL {
        URL(string: "yui://agent/\(id ?? AgentRoster.defaultID)/thread?talk=1")!
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(Self.link(agent: agent?.id)))
    }
}
