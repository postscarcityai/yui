import AppIntents
import SwiftUI
import WidgetKit

// "Talk to Yui" (YUI-40, spec WIDGETS.md section 6): a control for Control Center, the lock screen and the
// Action button. It opens the thread of the agent the person picked, with hands-free voice on.

struct TalkConfig: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Talk to Yui"
    static let description = IntentDescription("Open an agent's thread with hands-free voice on.")

    @Parameter(title: "Agent") var agent: AgentEntity?
}

struct TalkControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: WidgetKinds.talk, intent: TalkConfig.self) { config in
            ControlWidgetButton(action: TalkToAgentIntent(agent: config.agent)) {
                Label("Talk to \(config.agent?.name ?? "Yui")", systemImage: "waveform")
            }
        }
        .displayName("Talk to Yui")
        .description("Open an agent's thread with hands-free voice on.")
    }
}
