import AudioToolbox
import SwiftUI
import YuiLines

/// `timer`: work/rest rounds on a progress ring, or a stopwatch with `+up`.
/// Beeps on the last 3 seconds of a phase and on every phase change.
/// The clock lives in `TimerRuns` when the chat hosts it, so the same timer
/// keeps its time between the stage and the chat (YUI-13). Started, it also
/// runs on the lock screen and in the Dynamic Island (LiveTimer, YUI-30).
struct TimerPreset: View {
    let c: YLComponent
    @State private var local = TimerRun()
    @State private var now = Date.now
    @Environment(\.ylTimers) private var timers
    @Environment(\.ylScope) private var scope
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.ylEmit) private var emit

    private var run: TimerRun { timers?.run(scope, c) ?? local }
    private var plan: TimerPlan { c.timerPlan }
    private var running: Bool { run.running }
    private var elapsed: TimeInterval { run.elapsed(at: now) }

    var body: some View {
        let s = theme.swatch(scheme)
        let plan = plan
        let st = plan.state(at: elapsed)
        let tint = st.resting ? s.mint : s.accent
        PresetCard {
            HStack {
                PresetTitle(text: c.string("label") ?? (plan.up ? "Stopwatch" : "Timer"))
                Spacer()
                if !plan.up, plan.rounds > 1 {
                    Text("Round \(st.round)/\(plan.rounds)")
                        .font(theme.font(theme.type.caption, .heavy).monospacedDigit())
                        .foregroundStyle(s.userInk)
                        .padding(.horizontal, theme.spacing.m)
                        .padding(.vertical, theme.spacing.xs)
                        .background(s.butter, in: Capsule())
                }
            }
            ZStack {
                Circle().stroke(s.outline, lineWidth: 14)
                Circle()
                    .trim(from: 0, to: st.progress)
                    .stroke(tint, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: theme.spacing.xs) {
                    Text(clock(st.shown))
                        .font(theme.font(theme.type.display * 1.7, theme.strong).monospacedDigit())
                        .foregroundStyle(s.ink)
                        .contentTransition(.numericText(countsDown: !plan.up))
                    Text(st.done ? "Done!" : plan.up ? (running ? "Going" : "Ready") : st.resting ? "Rest" : "Work")
                        .font(theme.font(theme.type.caption, .heavy))
                        .foregroundStyle(st.done ? s.ink : tint)
                        .textCase(.uppercase)
                }
            }
            .frame(width: 190, height: 190)
            .frame(maxWidth: .infinity)
            .padding(.vertical, theme.spacing.s)
            HStack(spacing: theme.spacing.s) {
                OptionPill(text: st.done ? "Again" : running ? "Pause" : elapsed > 0 ? "Resume" : "Start",
                           fill: running ? s.lavender : s.accent, ink: running ? s.userInk : s.onAccent, grow: true, action: toggle)
                Button("Reset", systemImage: "arrow.counterclockwise", action: reset)
                    .labelStyle(.iconOnly)
                    .font(theme.font(theme.type.body, .black))
                    .foregroundStyle(s.ink)
                    .frame(width: 48, height: 48)
                    .background(s.background, in: Circle())
                    .overlay(Circle().stroke(s.outline, lineWidth: 1.5))
                    .buttonStyle(BounceButtonStyle())
                    .disabled(elapsed == 0)
            }
        }
        .task(id: running) {
            while running, !Task.isCancelled {
                now = .now
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .onAppear {
            now = .now
            // It ran out while no view was watching: finish it now, once.
            if running, plan.state(at: elapsed).done, !run.finished {
                run.banked = elapsed
                run.since = nil
                run.finished = true
                emit(c.event(["done": .bool(true), "rounds": .number(Double(plan.rounds))]))
            }
            if c.flag("auto"), !run.started { toggle() }
        }
        .onChange(of: st.beepKey) { old, new in
            guard running, old != new else { return }
            beep(new.phase != old.phase)
        }
        .onChange(of: st.done) { _, done in
            guard done, running, !run.finished else { return }
            run.banked = elapsed
            run.since = nil
            run.finished = true
            emit(c.event(["done": .bool(true), "rounds": .number(Double(plan.rounds))]))
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: st.beepKey.phase)
    }

    private func toggle() {
        withAnimation(theme.spring) {
            if plan.state(at: elapsed).done { reset() }
            if let since = run.since {
                run.banked += Date.now.timeIntervalSince(since)
                run.since = nil
            } else {
                now = .now
                run.since = now
                if !run.started {
                    run.started = true
                    emit(c.event(["started": .bool(true)]))
                }
            }
        }
        LiveTimer.shared.sync(run, key: liveKey, c, theme: theme, scheme: scheme)
    }

    private func reset() {
        withAnimation(theme.spring) {
            run.since = nil
            run.banked = 0
            run.finished = false
        }
        LiveTimer.shared.reset(key: liveKey)
    }

    /// Same key as `TimerRuns`: one lock-screen timer per reply and component (YUI-30).
    private var liveKey: String { "\(scope)#\(c.serial)" }

    private func beep(_ phaseChange: Bool) {
        guard c.string("sound") != "off" else { return }
        AudioServicesPlaySystemSound(phaseChange ? 1005 : 1103)
    }

    private func clock(_ t: TimeInterval) -> String { Self.clock(t, up: plan.up) }

    static func clock(_ t: TimeInterval, up: Bool) -> String {
        let n = Int(t.rounded(up ? .down : .up))
        return n >= 3600 ? String(format: "%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60)
            : String(format: "%d:%02d", n / 60, n % 60)
    }
}

/// Where a work/rest schedule is after `t` seconds. Pure, so patches can
/// change the plan under a running timer.
struct TimerPlan {
    var work: Double
    var rest: Double
    var rounds: Int
    var up: Bool

    struct State: Equatable {
        var round = 1
        var resting = false
        var shown: TimeInterval = 0
        var progress: Double = 0
        var done = false
        /// Changes on each beep-worthy second: the last 3 of a phase, and each phase start.
        var beepKey = BeepKey()
    }

    struct BeepKey: Equatable { var phase = 0; var count = 0 }

    func state(at t: TimeInterval) -> State {
        if up || work <= 0 {
            return State(shown: t, progress: t.truncatingRemainder(dividingBy: 60) / 60,
                         beepKey: BeepKey(phase: 0, count: 0))
        }
        var left = t
        var phase = 0
        for round in 1...rounds {
            for resting in [false, true] {
                let len = resting ? (round < rounds ? rest : 0) : work
                guard len > 0 else { continue }
                if left < len {
                    let remain = len - left
                    let tick = remain <= 3 ? Int(remain.rounded(.up)) : 0
                    return State(round: round, resting: resting, shown: remain, progress: left / len,
                                 beepKey: BeepKey(phase: phase, count: tick))
                }
                left -= len
                phase += 1
            }
        }
        return State(round: rounds, shown: 0, progress: 1, done: true, beepKey: BeepKey(phase: phase, count: 0))
    }
}
