import AudioToolbox
import SwiftUI
import YuiLines

/// `timer`: work/rest rounds on a progress ring, or a stopwatch with `+up`.
/// Beeps on the last 3 seconds of a phase and on every phase change.
struct TimerPreset: View {
    let c: YLComponent
    @State private var banked: TimeInterval = 0
    @State private var since: Date?
    @State private var now = Date.now
    @State private var started = false
    @State private var finished = false
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.ylEmit) private var emit

    private var plan: TimerPlan {
        TimerPlan(work: c.number("work") ?? 60, rest: c.number("rest") ?? 0,
                  rounds: max(1, Int(c.number("rounds") ?? 1)), up: c.flag("up"))
    }
    private var running: Bool { since != nil }
    private var elapsed: TimeInterval { banked + (since.map { now.timeIntervalSince($0) } ?? 0) }

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
        .onAppear { if c.flag("auto"), !started { toggle() } }
        .onChange(of: st.beepKey) { old, new in
            guard running, old != new else { return }
            beep(new.phase != old.phase)
        }
        .onChange(of: st.done) { _, done in
            guard done, running, !finished else { return }
            banked = elapsed
            since = nil
            finished = true
            emit(c.event(["done": .bool(true), "rounds": .number(Double(plan.rounds))]))
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: st.beepKey.phase)
    }

    private func toggle() {
        withAnimation(theme.spring) {
            if plan.state(at: elapsed).done { reset() }
            if let since {
                banked += Date.now.timeIntervalSince(since)
                self.since = nil
            } else {
                now = .now
                since = now
                if !started {
                    started = true
                    emit(c.event(["started": .bool(true)]))
                }
            }
        }
    }

    private func reset() {
        withAnimation(theme.spring) {
            since = nil
            banked = 0
            finished = false
        }
    }

    private func beep(_ phaseChange: Bool) {
        guard c.string("sound") != "off" else { return }
        AudioServicesPlaySystemSound(phaseChange ? 1005 : 1103)
    }

    private func clock(_ t: TimeInterval) -> String {
        let n = Int(t.rounded(plan.up ? .down : .up))
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
