import AudioToolbox
import SwiftUI
import YuiLines

// Arnold coaches a timed workout, start to finish (YUI-220).
//
// Chris (TestFlight, build 370): "starting a workout is time based, flows, and Arnold
// coaches along the way." Start opens a session that runs on its own clock: a work
// set, then the rest countdown, then the next set, then the next move, with no taps
// between. A tap is optional (Done early, +15s, Skip, Pause). The last set of a lift
// goes to failure only when the first plan chose it: that one waits for Stop.
// The clock is dates, not ticks: a kill, a relaunch or a pause comes back to the
// right second, and steps that ended while the app was away are caught up.

/// One step of the session's schedule.
struct SessionStep: Equatable {
    enum Kind: Equatable { case work, fail, rest }
    let kind: Kind
    /// Index into the runner's moves.
    let move: Int
    /// The set, 1 based. For a rest: the set just finished.
    let set: Int
    /// Seconds it runs. 0: open ended (the failure set waits for Stop).
    let seconds: Int
}

/// Where the session's clock is: the step, when it ends, and whether it is paused.
struct SessionRun: Codable, Equatable {
    var step = 0
    var ends: Date
    /// Seconds left while paused.
    var paused: Int?
    var pausedAt: Date?
    var started: Date
    var finished: Date?

    var isPaused: Bool { paused != nil }
    func left(at now: Date = .now) -> Int { paused ?? max(0, Int(ends.timeIntervalSince(now).rounded(.up))) }
}

/// The schedule and its moves: pure, so the clock is tested without a screen.
struct SessionEngine {
    let runner: RunnerPlan
    let steps: [SessionStep]

    /// `-yuiRunnerFast` (UI tests): six second sets and five second rests.
    static var fast: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-yuiRunnerFast")
        #else
        false
        #endif
    }

    init(_ runner: RunnerPlan, fast: Bool = SessionEngine.fast) {
        self.runner = runner
        var out: [SessionStep] = []
        for (mi, m) in runner.moves.enumerated() {
            for n in 1...max(1, m.labels.count) {
                let last = n == m.labels.count
                out.append(SessionStep(kind: last && m.fail ? .fail : .work, move: mi, set: n,
                                       seconds: last && m.fail ? 0 : fast ? 6 : Self.workSeconds(m)))
                if !(mi == runner.moves.count - 1 && last) {
                    out.append(SessionStep(kind: .rest, move: mi, set: n, seconds: fast ? 5 : runner.rest))
                }
            }
        }
        steps = out
    }

    /// A work set on the clock: the runtime's number, else a timed move's seconds, else about four seconds a rep.
    static func workSeconds(_ m: RunnerMove) -> Int {
        if let w = m.work { return w }
        if let s = m.nudges.first(where: { $0.ylID.hasSuffix("-secs") })?.number("value") { return Int(s) }
        let reps = m.nudges.first(where: { $0.ylID.hasSuffix("-reps") })?.number("value") ?? 8
        return max(20, min(60, Int(reps) * 4))
    }

    func begin(at now: Date = .now) -> SessionRun {
        SessionRun(ends: end(of: 0, from: now), started: now)
    }

    private func end(of i: Int, from t: Date) -> Date {
        guard i < steps.count else { return t }
        return steps[i].seconds == 0 ? .distantFuture : t.addingTimeInterval(TimeInterval(steps[i].seconds))
    }

    func current(_ run: SessionRun) -> SessionStep? { run.finished == nil && run.step < steps.count ? steps[run.step] : nil }

    /// The next work step after `i`: where a rest says what is next.
    func nextWork(after i: Int) -> SessionStep? { steps.dropFirst(i + 1).first { $0.kind != .rest } }

    /// Completes step `i` at `base`: a finished work set ticks; the run moves on, the next step starting at `base`.
    private func complete(_ p: inout RunnerProgress, at base: Date, ticking: Bool = true) {
        guard var run = p.run, let s = current(run) else { return }
        if s.kind != .rest, ticking { mark(&p, s) }
        run.step += 1
        run.paused = nil
        run.pausedAt = nil
        if run.step >= steps.count { run.finished = base; run.ends = base } else { run.ends = end(of: run.step, from: base) }
        p.run = run
    }

    /// A set done: its row ticks (in order, never twice).
    private func mark(_ p: inout RunnerProgress, _ s: SessionStep) {
        let m = runner.moves[s.move]
        var t = (p.ticked[m.sets.ylID] ?? []).filter { $0 != m.skip }
        let label = m.labels[min(s.set, m.labels.count) - 1]
        if !t.contains(label) { t.append(label) }
        p.ticked[m.sets.ylID] = m.labels.filter { t.contains($0) }
    }

    /// Steps whose time ran out, caught up from where each one ended. True when anything moved.
    @discardableResult
    func tick(_ p: inout RunnerProgress, at now: Date = .now) -> Bool {
        var moved = false
        while let run = p.run, run.finished == nil, !run.isPaused, run.ends <= now {
            complete(&p, at: run.ends)
            moved = true
        }
        return moved
    }

    /// Done early: this step ends now, the next starts now.
    func doneEarly(_ p: inout RunnerProgress, at now: Date = .now) {
        complete(&p, at: now)
    }

    /// +15s on the step running.
    func addTime(_ p: inout RunnerProgress, _ s: Int = 15, at now: Date = .now) {
        guard var run = p.run, current(run) != nil else { return }
        if let left = run.paused { run.paused = left + s } else { run.ends = max(run.ends, now).addingTimeInterval(TimeInterval(s)) }
        p.run = run
    }

    /// Skip the move: its sets stay as they are, the run goes to the next move's first set.
    func skipMove(_ p: inout RunnerProgress, at now: Date = .now) {
        guard var run = p.run, let s = current(run) else { return }
        let m = runner.moves[s.move]
        if (p.ticked[m.sets.ylID] ?? []).isEmpty, let skip = m.skip { p.ticked[m.sets.ylID] = [skip] }
        if let next = steps.firstIndex(where: { $0.move > s.move }) {
            run.step = next
            run.ends = end(of: next, from: now)
            run.paused = nil
            run.pausedAt = nil
        } else {
            run.step = steps.count
            run.finished = now
            run.ends = now
        }
        p.run = run
    }

    func pause(_ p: inout RunnerProgress, at now: Date = .now) {
        guard var run = p.run, let s = current(run), s.kind != .fail, !run.isPaused else { return }
        run.paused = run.left(at: now)
        run.pausedAt = now
        p.run = run
    }

    func resume(_ p: inout RunnerProgress, at now: Date = .now) {
        guard var run = p.run, let left = run.paused else { return }
        if let at = run.pausedAt { run.started = run.started.addingTimeInterval(now.timeIntervalSince(at)) }
        run.ends = current(run)?.seconds == 0 ? .distantFuture : now.addingTimeInterval(TimeInterval(left))
        run.paused = nil
        run.pausedAt = nil
        p.run = run
    }

    /// Stop on the failure set: the reps it went to are logged, and the run moves on.
    func stop(_ p: inout RunnerProgress, reps: Int, at now: Date = .now) {
        guard let run = p.run, let s = current(run), s.kind == .fail else { return }
        p.values["\(runner.moves[s.move].tag)-fail"] = Double(reps)
        complete(&p, at: now)
    }

    // MARK: - what the screen says

    /// Sets ticked over sets in the plan (a skipped move counts none).
    func setsDone(_ p: RunnerProgress) -> (done: Int, of: Int) {
        let done = runner.moves.reduce(0) { $0 + (p.ticked[$1.sets.ylID] ?? []).filter(RunnerPlan.isSet).count }
        return (done, runner.moves.reduce(0) { $0 + $1.labels.count })
    }

    /// "Bench press 3x8 at 135" for a move, as the plan holds it now.
    func target(_ m: RunnerMove, _ p: RunnerProgress) -> String {
        var parts = ["\(m.labels.count)x" + (m.nudges.first.flatMap { n in
            (p.values[n.ylID] ?? n.number("value")).map { YLComponent.format($0) + (n.ylID.hasSuffix("-secs") ? "s" : "") }
        } ?? "")]
        if let lb = m.nudges.first(where: { $0.ylID.hasSuffix("-lb") }), let v = p.values[lb.ylID] ?? lb.number("value"), v > 0 {
            parts.append("at \(YLComponent.format(v))")
        }
        return "\(m.name) " + parts.joined(separator: " ")
    }

    /// The rest's "Next:" line: the next set of this move, or the next move.
    func nextLine(after i: Int, _ p: RunnerProgress) -> String {
        guard let n = nextWork(after: i) else { return "Next: finish" }
        let m = runner.moves[n.move]
        if n.set == 1 { return "Next: \(target(m, p))" }
        return "Next: \(m.name), set \(n.set) of \(m.labels.count)"
    }

    /// Arnold's load call for step `i` (feedback NOTE-35460): on a move's first set, and on the rest before it.
    func why(at i: Int) -> String? {
        guard i >= 0, i < steps.count else { return nil }
        let s = steps[i]
        let w: SessionStep? = s.kind == .rest ? nextWork(after: i) : s
        guard let w, w.set == 1, let why = runner.moves[w.move].why, !why.isEmpty else { return nil }
        return why
    }

    /// Arnold's line for a move: the runtime's, else one of the app's own.
    static func cue(_ m: RunnerMove) -> String {
        if let c = m.cue, !c.isEmpty { return c }
        let n = m.name.lowercased()
        if n.contains("plank") { return "Straight line. Squeeze everything." }
        if n.contains("squat") || n.contains("lunge") { return "Brace. Knees out. Drive up." }
        if n.contains("press") || n.contains("push") { return "Brace. Slow down." }
        return "Slow down. Own every rep."
    }

    /// 1:05 as the clock shows it.
    static func clock(_ s: Int) -> String { RestClock.label(s) }
}

// MARK: - the session screen

/// The session, full size: the phase, the big clock, Arnold's line, the optional buttons. Finished, it logs.
struct TimedSessionView: View {
    let runner: RunnerPlan
    @Binding var progress: RunnerProgress
    /// The plan was sent: the log is written.
    let logged: Bool
    let log: (String?) -> Void
    @State private var failReps = 8
    @State private var feel: String?
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private var engine: SessionEngine { SessionEngine(runner) }

    var body: some View {
        let s = theme.swatch(scheme)
        VStack(alignment: .leading, spacing: theme.spacing.m) {
            if let run = progress.run {
                if run.finished != nil { finished(run, s) } else { running(run, s) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            // The clock is dates: every quarter second, anything that ended moves on.
            while !Task.isCancelled {
                var p = progress
                if engine.tick(&p) { progress = p }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func running(_ run: SessionRun, _ s: Swatch) -> some View {
        let e = engine
        let step = e.steps[min(run.step, e.steps.count - 1)]
        let m = runner.moves[step.move]
        let resting = step.kind == .rest
        let accent = resting ? s.mint : step.kind == .fail ? s.butter : s.accent
        return VStack(alignment: .leading, spacing: theme.spacing.m) {
            ProgressView(value: Double(run.step), total: Double(e.steps.count)).tint(s.accent)
                .accessibilityIdentifier("session-progress")
            HStack {
                Text(resting ? "Rest" : step.kind == .fail ? "To failure" : "Work")
                    .font(theme.font(theme.type.caption, .heavy)).textCase(.uppercase)
                    .foregroundStyle(resting ? s.ink : s.userInk)
                    .padding(.horizontal, theme.spacing.s).padding(.vertical, 3)
                    .background(accent, in: Capsule())
                    .accessibilityIdentifier("session-phase")
                    .accessibilityLabel(resting ? "Rest" : step.kind == .fail ? "To failure" : "Work")
                Spacer()
                Text("Move \(step.move + 1) of \(runner.moves.count) · Set \(step.set) of \(m.labels.count)")
                    .font(theme.font(theme.type.caption, .heavy)).foregroundStyle(s.inkSoft)
                    .accessibilityIdentifier("session-where")
            }
            Text(m.name).font(theme.font(theme.type.display, .heavy)).foregroundStyle(s.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("session-move")
            if step.kind == .fail { failSet(m, s) } else { clockRing(run, step, accent, s) }
            coach(e, run, step, m, s)
            controls(e, run, step, s)
        }
        .sensoryFeedback(.impact, trigger: run.step)
        .onChange(of: run.step) { _, _ in
            // Changes of step ring: the gap between work and rest is heard, not watched.
            AudioServicesPlaySystemSound(1005)
            failReps = Int(runner.moves[min(step.move, runner.moves.count - 1)].nudges.first { $0.ylID.hasSuffix("-reps") }?.number("value") ?? 8)
        }
    }

    private func clockRing(_ run: SessionRun, _ step: SessionStep, _ accent: Color, _ s: Swatch) -> some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            let left = run.left(at: ctx.date)
            ZStack {
                Circle().stroke(s.outline, lineWidth: 12)
                Circle().trim(from: 0, to: step.seconds > 0 ? CGFloat(step.seconds - left) / CGFloat(step.seconds) : 0)
                    .stroke(accent, style: StrokeStyle(lineWidth: 12, lineCap: .round)).rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text(SessionEngine.clock(left))
                        .font(theme.font(64, .black).monospacedDigit()).foregroundStyle(s.ink)
                        .contentTransition(.numericText(countsDown: true))
                        .accessibilityIdentifier("session-clock")
                    if run.isPaused {
                        Text("Paused").font(theme.font(theme.type.caption, .heavy)).foregroundStyle(s.inkSoft)
                            .accessibilityIdentifier("session-paused")
                    }
                }
            }
            .frame(width: 220, height: 220)
            .frame(maxWidth: .infinity)
        }
    }

    /// The to-failure set: no clock, the reps, and a big Stop.
    private func failSet(_ m: RunnerMove, _ s: Swatch) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.m) {
            Text("To failure. Stop when form breaks.")
                .font(theme.font(theme.type.title, .heavy)).foregroundStyle(s.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("session-fail-note")
            HStack(spacing: theme.spacing.m) {
                Text("Reps").font(theme.font(theme.type.body, .bold)).foregroundStyle(s.inkSoft)
                Spacer()
                nudgeButton("minus", label: "Fewer reps", id: "session-fail-minus", s) { failReps = max(1, failReps - 1) }
                Text("\(failReps)").font(theme.font(theme.type.display, .black).monospacedDigit()).foregroundStyle(s.ink)
                    .frame(minWidth: 70).accessibilityIdentifier("session-fail-value")
                nudgeButton("plus", label: "More reps", id: "session-fail-plus", s) { failReps = min(60, failReps + 1) }
            }
            Button {
                var p = progress
                engine.stop(&p, reps: failReps)
                withAnimation(theme.spring) { progress = p }
            } label: {
                Text("Stop").font(theme.font(theme.type.display, .black)).foregroundStyle(s.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 96)
                    .background(s.accent, in: .rect(cornerRadius: theme.radius.bubble))
            }
            .buttonStyle(BounceButtonStyle())
            .accessibilityIdentifier("session-stop")
        }
    }

    private func coach(_ e: SessionEngine, _ run: SessionRun, _ step: SessionStep, _ m: RunnerMove, _ s: Swatch) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.xs) {
            if step.kind == .rest {
                Text(e.nextLine(after: run.step, progress))
                    .font(theme.font(theme.type.title, .heavy)).foregroundStyle(s.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("session-next")
            }
            // On a rest the cue is for the move coming up.
            let cueFor = step.kind == .rest ? (e.nextWork(after: run.step).map { runner.moves[$0.move] } ?? m) : m
            Text(SessionEngine.cue(cueFor))
                .font(theme.font(theme.type.body, .bold)).foregroundStyle(s.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("session-cue")
            if let why = e.why(at: run.step) {
                Text(why)
                    .font(theme.font(theme.type.body, .medium)).foregroundStyle(s.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("session-why")
            }
            if step.kind == .work {
                Text(e.target(m, progress))
                    .font(theme.font(theme.type.caption, .heavy)).foregroundStyle(s.inkSoft)
                    .accessibilityIdentifier("session-target")
            }
        }
    }

    private func controls(_ e: SessionEngine, _ run: SessionRun, _ step: SessionStep, _ s: Swatch) -> some View {
        HStack(spacing: theme.spacing.s) {
            if step.kind == .fail {
                EmptyView()
            } else if run.isPaused {
                OptionPill(text: "Resume", fill: s.accent, ink: s.onAccent, grow: true) { change { e.resume(&$0) } }
                    .accessibilityIdentifier("session-resume")
            } else {
                OptionPill(text: "Pause", fill: s.lavender, grow: true) { change { e.pause(&$0) } }
                    .accessibilityIdentifier("session-pause")
            }
            if step.kind == .rest {
                OptionPill(text: "+15s", fill: s.lavender, grow: true) { change { e.addTime(&$0) } }
                    .accessibilityIdentifier("session-more")
                OptionPill(text: "Skip rest", fill: s.lavender, grow: true) { change { e.doneEarly(&$0) } }
                    .accessibilityIdentifier("session-done")
            } else if step.kind == .work {
                OptionPill(text: "Done early", fill: s.lavender, grow: true) { change { e.doneEarly(&$0) } }
                    .accessibilityIdentifier("session-done")
            }
            OptionPill(text: "Skip move", fill: s.lavender, grow: true) { change { e.skipMove(&$0) } }
                .accessibilityIdentifier("session-skip")
        }
    }

    private func change(_ f: (inout RunnerProgress) -> Void) {
        var p = progress
        f(&p)
        withAnimation(theme.spring) { progress = p }
    }

    private func nudgeButton(_ icon: String, label: String, id: String, _ s: Swatch, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(theme.font(theme.type.body, .black)).foregroundStyle(s.ink)
                .frame(width: 52, height: 52).background(s.lavender, in: Circle())
        }
        .buttonStyle(BounceButtonStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    // MARK: finished

    private func finished(_ run: SessionRun, _ s: Swatch) -> some View {
        let e = engine
        let sets = e.setsDone(progress)
        let time = Int((run.finished ?? .now).timeIntervalSince(run.started))
        return VStack(alignment: .leading, spacing: theme.spacing.m) {
            Text("Workout done").font(theme.font(theme.type.display, .heavy)).foregroundStyle(s.ink)
                .accessibilityIdentifier("session-finish")
            HStack(spacing: theme.spacing.m) {
                stat("\(sets.done) of \(sets.of)", "Sets done", id: "session-sets", s)
                stat(SessionEngine.clock(time), "Time", id: "session-time", s)
            }
            if logged {
                Label("Logged. Nice work.", systemImage: "checkmark.circle.fill")
                    .font(theme.font(theme.type.title, .heavy)).foregroundStyle(ChartPalette.good(scheme))
                    .accessibilityIdentifier("session-logged")
            } else {
                Text("How did it feel?").font(theme.font(theme.type.body, .bold)).foregroundStyle(s.inkSoft)
                HStack(spacing: theme.spacing.s) {
                    ForEach(["Easy", "Just right", "Hard"], id: \.self) { f in
                        OptionPill(text: f, fill: s.lavender, on: feel == f, grow: true) { feel = feel == f ? nil : f }
                            .accessibilityIdentifier("session-feel-\(f.lowercased().replacingOccurrences(of: " ", with: "-"))")
                    }
                }
                OptionPill(text: "Log workout", fill: s.accent, ink: s.onAccent, grow: true) { log(feel) }
                    .accessibilityIdentifier("session-log")
            }
        }
    }

    private func stat(_ value: String, _ label: String, id: String, _ s: Swatch) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(theme.font(theme.type.display, .black).monospacedDigit()).foregroundStyle(s.ink)
                .accessibilityIdentifier(id)
            Text(label).font(theme.font(theme.type.caption, .heavy)).foregroundStyle(s.inkSoft).textCase(.uppercase)
        }
        .padding(theme.spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(s.surface, in: .rect(cornerRadius: theme.radius.bubble))
        .overlay(RoundedRectangle(cornerRadius: theme.radius.bubble).stroke(s.outline, lineWidth: 1.5))
    }
}
