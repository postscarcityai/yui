import ActivityKit
import AppIntents
import Foundation

// A running timer on the lock screen and in the Dynamic Island (YUI-30).
// Compiled into the app and the widget extension. The widget only draws;
// the app owns the clock (LiveTimer) and answers the buttons.

struct TimerActivityAttributes: ActivityAttributes {
    /// What changes: the phase and its wall-clock window. Between updates the
    /// widget counts on its own with `Text(timerInterval:)`.
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable { case work, rest, up, done }

        var phase: Phase
        var round: Int
        /// Countdown: the phase runs `start...end`. Stopwatch: zero was at `start`.
        var start: Date
        var end: Date
        /// When the whole workout ends, if it keeps running.
        var finish: Date
        var running: Bool
        /// What the clock reads while paused (or at the moment of the update).
        var shown: TimeInterval
        /// How far into the phase, 0...1, while paused.
        var progress: Double
    }

    /// The timer's key in the thread (`TimerRuns`), so the buttons find it.
    var id: String
    var label: String
    var rounds: Int
    var up: Bool
    /// The agent's look (YuiTheme palette for the scheme the timer started in).
    var palette: YuiTheme.Palette
    var design: String

    /// "3:05", or "1:02:03" past an hour. Counting down rounds up, like the ring.
    static func clock(_ t: TimeInterval, up: Bool) -> String {
        let n = max(0, Int(t.rounded(up ? .down : .up)))
        return n >= 3600 ? String(format: "%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60)
            : String(format: "%d:%02d", n / 60, n % 60)
    }
}

extension TimerActivityAttributes.ContentState {
    var label: String {
        switch phase {
        case .work: "Work"
        case .rest: "Rest"
        case .up: running ? "Going" : "Paused"
        case .done: "Done!"
        }
    }
}

/// Where the buttons land in the app process. Set by LiveTimer at launch;
/// the widget process never runs these intents' bodies.
@MainActor
enum TimerIntentBridge {
    static var toggle: ((String) -> Void)?
    static var end: ((String) -> Void)?
}

/// Pause or resume from the lock screen or the Dynamic Island.
struct TimerToggleIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause or resume the timer"
    static let isDiscoverable = false

    @Parameter(title: "Timer") var id: String

    init() {}
    init(id: String) { self.id = id }

    func perform() async throws -> some IntentResult {
        let id = id
        await MainActor.run { TimerIntentBridge.toggle?(id) }
        return .result()
    }
}

/// Pause the timer and take it off the lock screen.
struct TimerEndIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "End the timer"
    static let isDiscoverable = false

    @Parameter(title: "Timer") var id: String

    init() {}
    init(id: String) { self.id = id }

    func perform() async throws -> some IntentResult {
        let id = id
        await MainActor.run { TimerIntentBridge.end?(id) }
        return .result()
    }
}
