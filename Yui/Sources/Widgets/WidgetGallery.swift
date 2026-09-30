#if DEBUG
import SwiftUI
import WidgetKit

struct WidgetGalleryOverlay: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay { if ProcessInfo.processInfo.arguments.contains("-yuiWidgetsGallery") { WidgetGallery() } }
    }
}

/// Every pinned saved screen, drawn by the widget's own views at small, medium and the
/// rectangular lock screen size, from the same app group copy the widget reads (YUI-40 shots and tests).
struct WidgetGallery: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // Redrawn twice a second from the app group copy, so a button tapped here (its intent runs in the app,
        // like a widget's does in the extension) shows at once (YUI-40 step 3 shots and tests).
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            // Checklists first, then timers: the buttons the shots are about sit at the top.
            gallery(WidgetStore.read().screens.sorted { rank($0) < rank($1) })
        }
    }

    private func rank(_ s: WidgetScreen) -> Int {
        switch s.parts.first?.preset { case "list": 0; case "timer": 1; default: 2 }
    }

    private func gallery(_ screens: [WidgetScreen]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("widgets: \(screens.count)").font(.caption).accessibilityIdentifier("gallery-count")
                Text(screens.map(\.name).joined(separator: ", ")).font(.caption2).accessibilityIdentifier("gallery-names")
                Text("ticked: " + screens.flatMap { $0.parts.flatMap(\.ticked) }.joined(separator: ",")).font(.caption2).accessibilityIdentifier("gallery-ticked")
                let queue = WidgetQueue.pending()
                Text("queue: \(queue.count)").font(.caption).accessibilityIdentifier("gallery-queue")
                Text(queue.last?.body ?? "no event").font(.caption2).accessibilityIdentifier("gallery-event")
                ForEach(screens) { s in
                    Text("\(s.agentName) / \(s.name)").font(.caption.bold())
                    HStack(alignment: .top, spacing: 12) {
                        tile(s, .systemSmall, 158, 158)
                        tile(s, .accessoryRectangular, 172, 76)
                    }
                    .accessibilityIdentifier("gallery-\(s.name)")
                    tile(s, .systemMedium, 338, 158)
                }
            }
            .padding(16)
        }
        .background(Color(.systemBackground))
        .accessibilityIdentifier("widget-gallery")
    }

    private func tile(_ s: WidgetScreen, _ family: WidgetFamily, _ w: CGFloat, _ h: CGFloat) -> some View {
        SavedScreenView(entry: SavedScreenEntry(date: .now, screen: s, hideOnLock: false), familyOverride: family)
            .padding(family == .accessoryRectangular ? 6 : 14)
            .frame(width: w, height: h)
            .background(SavedScreenBackground(screen: s))
            .clipShape(RoundedRectangle(cornerRadius: family == .accessoryRectangular ? 12 : 22))
    }
}
#endif
