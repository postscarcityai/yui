import AppIntents
import Foundation
import SwiftUI

// Siri, Shortcuts and the Action button (YUI-40 step 2, spec WIDGETS.md section 6): App Intents, each
// with an entity parameter so one intent covers every agent and every saved screen, and three App Shortcuts
// with the app's name in every phrase. Siri only asks, shows and starts: no intent confirms a purchase,
// writes to anyone but the person's own agent, or deletes.

struct AskAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask an agent"
    static let description = IntentDescription("Send a message to one of your agents. The answer comes as a push.")

    @Parameter(title: "Agent") var agent: AgentEntity
    @Parameter(title: "Message", requestValueDialog: "What do you want to ask?") var message: String

    static var parameterSummary: some ParameterSummary { Summary("Ask \(\.$agent) \(\.$message)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let words = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, let account = await WidgetApp.waitForAccount(), let user = account.session?.userID, user != "demo" else {
            return .result(dialog: "Open Yui and sign in first.")
        }
        let item = Outbox.Item(id: UUID().uuidString.lowercased(), userID: user, agentID: agent.id, body: words,
                               kind: "text", meta: nil, queuedAt: .now)
        Outbox.shared.start(account: account)
        Outbox.shared.add(item)
        // Give the send a moment: "Sent" is only said once it left the phone; otherwise it waits in the outbox.
        for _ in 0..<16 where Outbox.shared.isPending(item.id) { try? await Task.sleep(for: .milliseconds(250)) }
        return .result(dialog: Outbox.shared.isPending(item.id) ? "Queued for \(agent.name). It goes when you are online." : "Sent to \(agent.name)")
    }
}

struct ShowScreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Show a saved screen"
    static let description = IntentDescription("Open a saved screen from one of your agents.")

    @Parameter(title: "Saved screen") var screen: ScreenEntity

    static var parameterSummary: some ParameterSummary { Summary("Show \(\.$screen)") }

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(Self.link(agent: screen.agentID, name: screen.name)))
    }

    /// The thread with the saved screen on the stage; the app checks both names against its own shelf.
    static func link(agent: String, name: String) -> URL {
        var c = URLComponents()
        c.scheme = "yui"; c.host = "agent"; c.path = "/\(agent)/thread"
        c.queryItems = [URLQueryItem(name: "show", value: name)]
        return c.url!
    }
}

struct StartTimerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start a timer"
    static let description = IntentDescription("Start a saved timer. It runs on the lock screen and in the Dynamic Island.")

    @Parameter(title: "Timer") var timer: TimerEntity

    static var parameterSummary: some ParameterSummary { Summary("Start \(\.$timer)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let t = timer
        for _ in 0..<12 {
            if await MainActor.run(body: { WidgetTimerBridge.start.map { $0(t.agentID, t.screen, t.part); return true } ?? false }) { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return .result(dialog: "Started \(t.name)")
    }
}

/// Which agent id a handle ("basil", "arnold") is on this account. The app writes it whenever the agent list
/// loads, so an intent that runs with no screen can address the agent.
enum AgentHandles {
    private static let key = "agentHandles"

    static func save(_ agents: [YuiAgent]) {
        var map: [String: String] = [:]
        for a in agents { map[a.handle.lowercased()] = a.id }
        WidgetGroup.defaults.set(map, forKey: key)
        let before = AgentRoster.read()
        let roster = agents.map { AgentRoster.Entry(id: $0.id, name: $0.name, isDefault: $0.isDefault) }
        AgentRoster.save(roster)
        if before != roster { Task { await WidgetIndex.reindex(WidgetStore.read()) } }
    }

    static func id(_ handle: String) -> String? {
        (WidgetGroup.defaults.dictionary(forKey: key) as? [String: String])?[handle.lowercased()]
    }

    static func clear() { WidgetGroup.defaults.removeObject(forKey: key); AgentRoster.clear() }
}

/// "Log my food" (YUI-253): Basil's camera, straight away. No chat first.
struct LogFoodIntent: AppIntent {
    static let title: LocalizedStringResource = "Log my food"
    static let description = IntentDescription("Open Basil's camera to snap a meal and say what it is.")

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(Self.link))
    }

    static var link: URL { URL(string: "yui://snap?agent=basil")! }
}

/// "Tell Yui I ate a bacon cheeseburger with fries" (YUI-253): the words go to Basil as a meal log, through the
/// app's own outbox, and Siri says Logged without opening the app. Basil's answer (the meal and today's calories)
/// is waiting in the thread as a push.
struct LogMealIntent: AppIntent {
    static let title: LocalizedStringResource = "Tell Basil what I ate"
    static let description = IntentDescription("Log a meal by saying it. Basil answers with the meal and today's calories.")

    @Parameter(title: "Meal", requestValueDialog: "What did you eat?") var meal: String

    static var parameterSummary: some ParameterSummary { Summary("Log \(\.$meal)") }

    /// What Basil is sent: the drawer's own "Log a meal" words, then the meal.
    static func words(_ meal: String) -> String? {
        let said = meal.trimmingCharacters(in: .whitespacesAndNewlines)
        return said.isEmpty ? nil : "Log a meal: \(said)"
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let body = Self.words(meal), let account = await WidgetApp.waitForAccount(), let user = account.session?.userID, user != "demo" else {
            return .result(dialog: "Open Yui and sign in first.")
        }
        guard let basil = AgentHandles.id("basil") else { return .result(dialog: "Open Yui once so I can find Basil.") }
        let item = Outbox.Item(id: UUID().uuidString.lowercased(), userID: user, agentID: basil, body: body,
                               kind: "text", meta: nil, queuedAt: .now)
        Outbox.shared.start(account: account)
        Outbox.shared.add(item)
        for _ in 0..<16 where Outbox.shared.isPending(item.id) { try? await Task.sleep(for: .milliseconds(250)) }
        return .result(dialog: Outbox.shared.isPending(item.id) ? "Queued. It goes when you are online." : "Logged")
    }
}

/// "Start my workout" (YUI-253): Arnold's thread opens and today's coached session starts (YUI-220).
struct StartWorkoutIntent: AppIntent {
    static let title: LocalizedStringResource = "Start my workout"
    static let description = IntentDescription("Open today's coached workout with Arnold.")

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(Self.link))
    }

    static var link: URL { URL(string: "yui://agent/arnold/thread?workout=1")! }
}

/// Spotlight's tap on an agent (YUI-40 step 5), and the "Open agent" action in Shortcuts: that agent's thread.
struct OpenAgentIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open an agent"
    static let description = IntentDescription("Open one of your agents.")

    @Parameter(title: "Agent") var target: AgentEntity

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(Self.link(agent: target.id)))
    }

    static func link(agent id: String) -> URL { URL(string: "yui://agent/\(id)/thread")! }
}

/// Spotlight's tap on a saved screen: the thread with that screen on the stage.
struct OpenScreenIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open a saved screen"
    static let description = IntentDescription("Open a saved screen.")

    @Parameter(title: "Saved screen") var target: ScreenEntity

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(ShowScreenIntent.link(agent: target.agentID, name: target.name)))
    }
}

/// "Talk to Yui" for the Action button (Settings, Action Button, Shortcut): the thread of the agent you pick, or
/// your default agent when you pick none, with hands-free voice on.
struct TalkIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to an agent"
    static let description = IntentDescription("Open an agent's thread with hands-free voice on. No agent means your default agent.")

    @Parameter(title: "Agent") var agent: AgentEntity?

    static var parameterSummary: some ParameterSummary { Summary("Talk to \(\.$agent)") }

    /// The agent's id, else the default agent's.
    static func link(agent id: String?) -> URL { TalkToAgentIntent.link(agent: id ?? AgentRoster.defaultID) }

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(Self.link(agent: agent?.id)))
    }
}

struct YuiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: LogFoodIntent(),
                    phrases: ["Log my food in \(.applicationName)", "Log a meal in \(.applicationName)", "Snap my food in \(.applicationName)"],
                    shortTitle: "Log my food", systemImageName: "camera.fill")
        AppShortcut(intent: LogMealIntent(),
                    phrases: ["Tell \(.applicationName) what I ate", "Tell \(.applicationName) I ate something", "I ate something in \(.applicationName)"],
                    shortTitle: "Tell Basil what I ate", systemImageName: "fork.knife")
        AppShortcut(intent: StartWorkoutIntent(),
                    phrases: ["Start my workout in \(.applicationName)", "Start my workout with \(.applicationName)"],
                    shortTitle: "Start my workout", systemImageName: "figure.strengthtraining.traditional")
        AppShortcut(intent: TalkIntent(),
                    phrases: ["Talk to \(.applicationName)", "Start talking in \(.applicationName)"],
                    shortTitle: "Talk to an agent", systemImageName: "waveform")
        AppShortcut(intent: OpenAgentIntent(),
                    phrases: ["Open \(\.$target) in \(.applicationName)"],
                    shortTitle: "Open an agent", systemImageName: "person.crop.circle")
        AppShortcut(intent: AskAgentIntent(),
                    phrases: ["Ask \(\.$agent) in \(.applicationName)", "Message \(\.$agent) in \(.applicationName)"],
                    shortTitle: "Ask an agent", systemImageName: "bubble.left.fill")
        AppShortcut(intent: ShowScreenIntent(),
                    phrases: ["Show \(\.$screen) in \(.applicationName)", "Open \(\.$screen) in \(.applicationName)"],
                    shortTitle: "Show a saved screen", systemImageName: "rectangle.on.rectangle")
        AppShortcut(intent: StartTimerIntent(),
                    phrases: ["Start \(\.$timer) in \(.applicationName)"],
                    shortTitle: "Start a timer", systemImageName: "timer")
    }
}
