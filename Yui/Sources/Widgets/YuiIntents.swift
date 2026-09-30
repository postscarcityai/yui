import AppIntents
import Foundation
import SwiftUI

// Siri, Shortcuts and the Action button (YUI-40 step 2, spec WIDGETS.md section 6): three App Intents, each
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

struct YuiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
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
