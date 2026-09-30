import AppIntents
import Charts
import SwiftUI
import WidgetKit
import YuiLines

// A saved screen pinned as a widget (YUI-40, spec yuigui/spec/WIDGETS.md).
// The person adds "Yui" from the widget gallery and picks the agent's saved screen.
// Drawn from the app group copy the app keeps; the timeline policy is .never, so a
// reload only ever has a reason (the app changed the copy, a push, a widget button).

struct SavedScreenConfig: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Saved screen"
    static let description = IntentDescription("Pick one of your agent's saved screens.")

    @Parameter(title: "Saved screen") var screen: ScreenEntity?
    @Parameter(title: "Hide on the lock screen until unlocked", default: true) var hideOnLock: Bool
}

struct SavedScreenProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SavedScreenEntry {
        SavedScreenEntry(date: .now, screen: Self.sample, hideOnLock: false)
    }

    func snapshot(for config: SavedScreenConfig, in context: Context) async -> SavedScreenEntry {
        let e = entry(config)
        return e.screen == nil && context.isPreview ? placeholder(in: context) : e
    }

    func timeline(for config: SavedScreenConfig, in context: Context) async -> Timeline<SavedScreenEntry> {
        Timeline(entries: [entry(config)], policy: .never)
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
    static let kind = "YuiSavedScreen"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: SavedScreenConfig.self, provider: SavedScreenProvider()) { entry in
            SavedScreenView(entry: entry)
                .containerBackground(for: .widget) { SavedScreenBackground(screen: entry.screen) }
        }
        .configurationDisplayName("Saved screen")
        .description("A screen your agent saved, kept current.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}
