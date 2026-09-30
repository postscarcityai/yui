import SwiftUI
import WidgetKit

/// Yui's widget extension: the timer's Live Activity (YUI-30) and saved screens pinned as widgets (YUI-40).
@main
struct YuiWidgets: WidgetBundle {
    var body: some Widget {
        TimerLiveActivity()
        SavedScreenWidget()
        TalkControl()
    }
}
