import SwiftUI
import WidgetKit

/// Yui's widget extension: Live Activities only, for now (YUI-30).
@main
struct YuiWidgets: WidgetBundle {
    var body: some Widget {
        TimerLiveActivity()
    }
}
