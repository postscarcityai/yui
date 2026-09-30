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
    private let screens = WidgetStore.read().screens

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("widgets: \(screens.count)").font(.caption).accessibilityIdentifier("gallery-count")
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
