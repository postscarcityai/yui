import ActivityKit
import AVFoundation
import SwiftUI
import UIKit
import YuiLines

// The timer on the lock screen and in the Dynamic Island (YUI-30).
// One Live Activity at a time, for the timer that started last. The widget
// counts each phase on its own; the app updates it at every phase change,
// answers Pause/Resume/End, and ends it when the rounds are done.
// While a timer with sound runs, its audio session keeps the app awake so
// rounds advance and the beeps keep going with the phone locked (Info.plist:
// audio). With sound off there is no audio, so the lock screen counts the
// current phase and catches up when the app next runs.

extension TimerActivityAttributes.ContentState {
    /// What the widget shows for `plan` after `elapsed` seconds, seen at `now`.
    static func make(plan: TimerPlan, elapsed: TimeInterval, running: Bool, now: Date = .now) -> Self {
        if plan.up || plan.work <= 0 {
            let start = now.addingTimeInterval(-elapsed)
            let end = start.addingTimeInterval(24 * 3600)
            return Self(phase: .up, round: 1, start: start, end: end, finish: end, running: running,
                        shown: elapsed, progress: elapsed.truncatingRemainder(dividingBy: 60) / 60)
        }
        let st = plan.state(at: elapsed)
        if st.done {
            return Self(phase: .done, round: plan.rounds, start: now, end: now, finish: now, running: false,
                        shown: 0, progress: 1)
        }
        let total = Double(plan.rounds) * plan.work + Double(plan.rounds - 1) * plan.rest
        let len = st.resting ? plan.rest : plan.work
        return Self(phase: st.resting ? .rest : .work, round: st.round,
                    start: now.addingTimeInterval(-len * st.progress), end: now.addingTimeInterval(st.shown),
                    finish: now.addingTimeInterval(max(0, total - elapsed)), running: running,
                    shown: st.shown, progress: st.progress)
    }
}

@MainActor
final class LiveTimer {
    static let shared = LiveTimer()

    private var activity: Activity<TimerActivityAttributes>?
    private var run: TimerRun?
    private var plan = TimerPlan(work: 60, rest: 0, rounds: 1, up: false)
    private var key = ""
    private var sound = true
    private var shown: TimerActivityAttributes.ContentState?
    private var ticker: Task<Void, Never>?
    private var tickerID = 0
    private var queue: Task<Void, Never>?
    private let audio = TimerAudio()

    /// At launch: wire the buttons and clear whatever a killed app left on the lock screen.
    func setUp() {
        TimerIntentBridge.toggle = { [weak self] in self?.toggle($0) }
        TimerIntentBridge.end = { [weak self] in self?.end($0) }
        let current = activity?.id
        Task {
            for a in Activity<TimerActivityAttributes>.activities where a.id != current {
                await a.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// The timer view calls this after Start, Pause and Resume.
    func sync(_ run: TimerRun, key: String, _ c: YLComponent, theme: YuiTheme, scheme: ColorScheme) {
        if key != self.key {
            guard run.running else { return }
            close(.immediate)
            self.key = key
            self.run = run
            plan = c.timerPlan
            sound = c.string("sound") != "off"
            start(TimerActivityAttributes(
                id: key, label: c.string("label") ?? (plan.up ? "Stopwatch" : "Timer"),
                rounds: plan.rounds, up: plan.up, palette: theme.palette(for: scheme), design: theme.type.design))
        } else {
            plan = c.timerPlan
            if activity == nil, run.running {
                // Taken off the lock screen, then resumed: put it back.
                start(TimerActivityAttributes(
                    id: key, label: c.string("label") ?? (plan.up ? "Stopwatch" : "Timer"),
                    rounds: plan.rounds, up: plan.up, palette: theme.palette(for: scheme), design: theme.type.design))
            }
        }
        refresh()
    }

    /// Reset in the app: the timer is back at zero, so it leaves the lock screen.
    func reset(key: String) {
        guard key == self.key else { return }
        close(.immediate)
    }

    // MARK: buttons

    private func toggle(_ id: String) {
        guard id == key, let run else { return }
        if plan.state(at: run.elapsed()).done { return }
        if let since = run.since {
            run.banked += Date.now.timeIntervalSince(since)
            run.since = nil
        } else {
            run.since = .now
        }
        refresh()
    }

    private func end(_ id: String) {
        guard id == key, let run else { return }
        if let since = run.since {
            run.banked += Date.now.timeIntervalSince(since)
            run.since = nil
        }
        close(.immediate)
    }

    // MARK: activity

    private func start(_ attributes: TimerActivityAttributes) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, let run else { return }
        let state = TimerActivityAttributes.ContentState.make(plan: plan, elapsed: run.elapsed(), running: run.running)
        guard let a = try? Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil))
        else { return }
        activity = a
        shown = state
        Task { [weak self] in
            for await s in a.activityStateUpdates where s == .dismissed || s == .ended {
                // Swiped away on the lock screen: the timer keeps going in the app.
                if self?.activity?.id == a.id { self?.activity = nil }
            }
        }
    }

    /// Push the current state and keep the clock watched while it runs.
    private func refresh() {
        guard let run else { return }
        let state = TimerActivityAttributes.ContentState.make(plan: plan, elapsed: run.elapsed(), running: run.running)
        push(state)
        if run.running, state.phase != .done { watch() } else { stopWatching() }
    }

    private func push(_ state: TimerActivityAttributes.ContentState) {
        shown = state
        guard let activity else { return }
        if state.phase == .done { self.activity = nil }
        let id = activity.id
        send(id, state, end: state.phase == .done, policy: .after(.now + 120))
    }

    private func close(_ policy: ActivityUIDismissalPolicy) {
        stopWatching()
        if let id = activity?.id {
            send(id, nil, end: true, policy: policy)
        }
        activity = nil
        run = nil
        key = ""
        shown = nil
    }

    /// Updates land in the order they were made.
    private func send(_ id: String, _ state: TimerActivityAttributes.ContentState?, end: Bool,
                      policy: ActivityUIDismissalPolicy) {
        let before = queue
        queue = Task {
            await before?.value
            await Self.apply(id, state, end: end, policy: policy)
        }
    }

    /// Activities aren't Sendable: look this one up where it is used.
    nonisolated private static func apply(_ id: String, _ state: TimerActivityAttributes.ContentState?, end: Bool,
                                          policy: ActivityUIDismissalPolicy) async {
        guard let a = Activity<TimerActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        if end {
            await a.end(content, dismissalPolicy: policy)
        } else if let content {
            await a.update(content)
        }
    }

    /// Ticks four times a second while the timer runs: a new phase updates the
    /// widget, and with the app in the background the beeps come from here.
    private func watch() {
        if sound { audio.start() }
        guard ticker == nil else { return }
        tickerID += 1
        let id = tickerID
        ticker = Task { [weak self] in
            var beepKey = TimerPlan.BeepKey()
            while !Task.isCancelled, let self, let run = self.run, run.running {
                let elapsed = run.elapsed()
                let st = self.plan.state(at: elapsed)
                if st.beepKey != beepKey {
                    if self.sound, UIApplication.shared.applicationState != .active {
                        self.audio.beep(st.beepKey.phase != beepKey.phase)
                    }
                    beepKey = st.beepKey
                }
                let state = TimerActivityAttributes.ContentState.make(plan: self.plan, elapsed: elapsed, running: true)
                if state.phase != self.shown?.phase || state.round != self.shown?.round {
                    self.push(state)
                }
                if state.phase == .done { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let self, self.tickerID == id, !Task.isCancelled else { return }
            self.ticker = nil
            // Let the last beep ring out before the session goes quiet.
            try? await Task.sleep(for: .seconds(1.5))
            if self.ticker == nil { self.audio.stop() }
        }
    }

    private func stopWatching() {
        ticker?.cancel()
        ticker = nil
        audio.stop()
    }
}

/// Keeps the app awake while a timer runs (silent loop, mixed with the
/// person's music) and plays the phase beeps when the system sounds can't.
@MainActor
final class TimerAudio {
    private var keepAlive: AVAudioPlayer?
    private lazy var tick = try? AVAudioPlayer(data: Self.wav(hz: 880, seconds: 0.12, volume: 0.6))
    private lazy var change = try? AVAudioPlayer(data: Self.wav(hz: 1320, seconds: 0.4, volume: 0.7))

    func start() {
        guard keepAlive == nil else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)
        let p = try? AVAudioPlayer(data: Self.wav(hz: 0, seconds: 1, volume: 0))
        p?.numberOfLoops = -1
        p?.play()
        keepAlive = p
    }

    func stop() {
        guard let p = keepAlive else { return }
        p.stop()
        keepAlive = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func beep(_ phaseChange: Bool) {
        guard let p = phaseChange ? change : tick else { return }
        p.currentTime = 0
        p.play()
    }

    /// A mono 16-bit sine as a WAV file (hz 0 = silence), faded at both ends.
    static func wav(hz: Double, seconds: Double, volume: Double) -> Data {
        let rate = 44_100
        let n = Int(Double(rate) * seconds)
        var d = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + n * 2))
        d.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        d.append(contentsOf: Array("data".utf8)); put(UInt32(n * 2))
        let fade = Double(rate) * 0.01
        for i in 0..<n {
            let env = min(1, Double(i) / fade, Double(n - i) / fade)
            let s = hz == 0 ? 0 : sin(2 * .pi * hz * Double(i) / Double(rate)) * volume * env
            put(Int16(s * Double(Int16.max)))
        }
        return d
    }
}
