import AppIntents
import Charts
import SwiftUI
import WidgetKit
import YuiLines

// A saved screen pinned as a widget (YUI-40, spec yuigui/spec/WIDGETS.md).
// The person adds "Yui" from the widget gallery and picks the agent's saved screen.
// Drawn from the app group copy the app keeps; the timeline policy is .never, so a
// reload only ever has a reason (the app changed the copy, a push, a widget button).

struct SavedScreenProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SavedScreenEntry {
        SavedScreenEntry(date: .now, screen: Self.sample, hideOnLock: false)
    }

    func snapshot(for config: SavedScreenConfig, in context: Context) async -> SavedScreenEntry {
        let e = entry(config)
        return e.screen == nil && context.isPreview ? placeholder(in: context) : e
    }

    func timeline(for config: SavedScreenConfig, in context: Context) async -> Timeline<SavedScreenEntry> {
        var e = entry(config)
        if let s = e.screen, !context.isPreview {
            WidgetBudget.log(screen: s.id)
            // Woken by a push (or the app, or a button): catch up with what the agent patched since the copy.
            e = SavedScreenEntry(date: .now, screen: await WidgetCatchUp.refresh(s), hideOnLock: e.hideOnLock)
            // A tick made offline goes out with this reload too.
            await WidgetQueue.flush()
        }
        return Timeline(entries: [e], policy: .never)
    }

    private func entry(_ c: SavedScreenConfig) -> SavedScreenEntry {
        let s = c.screen.flatMap { WidgetStore.screen(agent: $0.agentID, name: $0.name) }
        return SavedScreenEntry(date: .now, screen: s, hideOnLock: c.hideOnLock)
    }

    static let sample = WidgetScreen(
        agentID: "sample", agentName: "Coach", name: "weight",
        parts: [WidgetPart(ylID: "weight", preset: "stat", props: [
            "value": .number(178.9), "unit": .string("lb"), "label": .string("Weight"), "delta": .number(-2.3),
            "good": .string("down"), "spark": .array([181.2, 180.6, 179.8, 178.9].map { .number($0) })])],
        light: YuiTheme.yui.light, dark: YuiTheme.yui.dark, design: "rounded", at: .now)
}

struct SavedScreenWidget: Widget {
    static let kind = WidgetKinds.savedScreen

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: SavedScreenConfig.self, provider: SavedScreenProvider()) { entry in
            SavedScreenView(entry: entry)
                .containerBackground(for: .widget) { SavedScreenBackground(screen: entry.screen) }
        }
        .pushHandler(YuiWidgetPush.self)
        .configurationDisplayName("Saved screen")
        .description("A screen your agent saved, kept current.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

/// The WidgetKit push token (spec section 3): the app registers it with the pins, and a change while the app is
/// closed goes straight to the rows that are already registered.
struct YuiWidgetPush: WidgetPushHandler {
    func pushTokenDidChange(_ pushInfo: WidgetPushInfo, widgets: [WidgetInfo]) {
        let token = pushInfo.token.map { String(format: "%02x", $0) }.joined()
        WidgetSecrets.pushToken = token
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        Task { await WidgetRelay.pushToken(token, environment: environment) }
    }
}
