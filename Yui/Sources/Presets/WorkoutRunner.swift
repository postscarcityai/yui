import AudioToolbox
import SwiftUI
import YuiLines

// Arnold's workout runner, the app half (YUI-182).
//
// Chris (Sep 28): "getting the crew more tools up with detailed flows." The runtime
// sends today's session as one `plan`: a page, then per move a `pick` of its sets
// ("Set 1".."Set N" and Skip) with `slide`s for reps (or seconds) and weight, then
// how it felt. Any plan shaped like that runs here as a workout: one move per page,
// big set rows to tick, reps and weight nudged with - and +, a rest timer that starts
// on its own after each set, and "done" said out loud ticks the next set. Progress
// is kept on the phone (UserDefaults), so a kill, a relaunch or a trip to another
// agent comes back to the same set. The answers still go as the plan's one `{plan}`.

/// One move of a runner plan: its sets pick and the slides nudged on the same page.
struct RunnerMove: Equatable {
    let sets: YLComponent
    /// The set rows, "Set 1".."Set N", without Skip. Edited in the runner: as many as it has now.
    var labels: [String]
    let skip: String?
    /// reps (or secs) first, then lb, when the plan has them.
    let nudges: [YLComponent]
    /// Arnold's one line for the move (YUI-220). Nil: the app says its own.
    var cue: String? = nil
    /// How long a work set runs, in seconds, from the runtime. Nil: worked out from the reps or seconds.
    var work: Int? = nil
    /// The last set goes to failure with a safe stop: only when the first plan chose it.
    var fail = false
    /// Arnold's call on the load and why, from the log (feedback NOTE-35460). Nil: none yet.
    var why: String? = nil
    /// The move it was swapped for in the runner. Nil: the plan's own.
    var title: String? = nil

    /// The move's own name in ids: "e1" for `e1-sets`.
    var tag: String { sets.ylID.hasSuffix("-sets") ? String(sets.ylID.dropLast(5)) : sets.ylID }
    var name: String { title ?? sets.string("title") ?? sets.prompt }
}

/// A plan read as a workout, or nil when it is some other plan.
struct RunnerPlan: Equatable {
    let moves: [RunnerMove]
    /// Rest between sets, in seconds: "Rest about 90 seconds" on its first page, else 90.
    let rest: Int
    /// The slides a move page draws itself: they are not steps of their own.
    var absorbed: Set<String> { Set(moves.flatMap { $0.nudges.map(\.ylID) }) }

    static func isSet(_ o: String) -> Bool { o.wholeMatch(of: /Set \d{1,2}/) != nil }

    static func of(_ steps: [YLComponent]) -> RunnerPlan? {
        var moves: [RunnerMove] = []
        for (i, step) in steps.enumerated() where step.preset == "pick" {
            let opts = step.strings("options") ?? []
            let labels = opts.filter(isSet)
            // Every option a set, bar at most one way out (Skip).
            guard !labels.isEmpty, opts.count - labels.count <= 1 else { continue }
            let skip = opts.first { !isSet($0) }
            // Its nudges: the slides right after it that share its id's move ("e1-sets" -> "e1-").
            let head = step.ylID.hasSuffix("-sets") ? String(step.ylID.dropLast(4)) : nil
            var nudges: [YLComponent] = []
            for next in steps.dropFirst(i + 1) {
                guard next.preset == "slide", let head, next.ylID.hasPrefix(head) else { break }
                nudges.append(next)
            }
            moves.append(RunnerMove(sets: step, labels: labels, skip: skip, nudges: nudges, cue: step.string("cue"),
                                    work: step.number("work").map { max(5, min(Int($0), 600)) }, fail: step.flag("fail"),
                                    why: step.string("why")))
        }
        guard !moves.isEmpty else { return nil }
        let words = steps.filter { $0.preset == "page" }.compactMap { $0.string("body") }.joined(separator: " ")
        let rest = words.firstMatch(of: /[Rr]est (?:about |for )?(\d{1,3}) ?(?:seconds|sec|s)\b/).flatMap { Int($0.1) } ?? 90
        return RunnerPlan(moves: moves, rest: max(10, min(rest, 600)))
    }

    func move(_ id: String) -> RunnerMove? { moves.first { $0.sets.ylID == id } }
}

/// The rest between sets: when it ends, and what is left.
struct RestClock: Codable, Equatable {
    var ends: Date
    var total: Int

    static func start(_ seconds: Int, at now: Date = .now) -> RestClock { RestClock(ends: now.addingTimeInterval(TimeInterval(seconds)), total: seconds) }
    func left(at now: Date = .now) -> Int { max(0, Int(ends.timeIntervalSince(now).rounded(.up))) }
    func over(at now: Date = .now) -> Bool { now >= ends }
    func progress(at now: Date = .now) -> Double { total > 0 ? Double(total - left(at: now)) / Double(total) : 1 }
    /// +15s: a longer rest, and the ring grows with it.
    func adding(_ s: Int, at now: Date = .now) -> RestClock { RestClock(ends: max(ends, now).addingTimeInterval(TimeInterval(s)), total: total + s) }
    static func label(_ s: Int) -> String { "\(s / 60):" + String(format: "%02d", s % 60) }
}

/// "Done" said out loud: every new "done" (or "next set") in the words heard ticks a set.
enum VoiceDone {
    static func count(_ words: String) -> Int {
        words.lowercased().matches(of: /\b(?:done|next set|set done)\b/).count
    }
}

/// A runner's place, kept on the phone per plan id, so a relaunch comes back to it.
struct RunnerProgress: Codable, Equatable {
    var at = 0
    var ticked: [String: [String]] = [:]
    var values: [String: Double] = [:]
    var rest: RestClock?
    /// The timed session (YUI-220): where its clock is. Nil until Start.
    var run: SessionRun?
    /// Changes made in the runner: swaps, sets, reps, weight, added moves. Nil: the plan as sent.
    var edits: RunnerEdits?

    static func key(_ plan: String) -> String { "yui.runner.\(plan)" }

    @MainActor static func load(_ plan: String, in d: UserDefaults = .standard) -> RunnerProgress? {
        resetIfAsked()
        return d.data(forKey: key(plan)).flatMap { try? JSONDecoder().decode(RunnerProgress.self, from: $0) }
    }

    func save(_ plan: String, in d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key(plan)) }
    }

    static func clear(_ plan: String, in d: UserDefaults = .standard) { d.removeObject(forKey: key(plan)) }

    /// `-yuiRunnerReset` (UI tests): every runner starts from its first page, once per launch.
    @MainActor private static var wasReset = false

    @MainActor static func resetIfAsked() {
        #if DEBUG
        guard !wasReset, ProcessInfo.processInfo.arguments.contains("-yuiRunnerReset") else { return }
        wasReset = true
        let d = UserDefaults.standard
        for k in d.dictionaryRepresentation().keys where k.hasPrefix("yui.runner.") { d.removeObject(forKey: k) }
        #endif
    }

    /// The plan answers it stands for: ticked sets as picks, every nudge as its number.
    /// Edited, the moves are the plan as edited (an added move answers by its own ids) and `edits` says what changed.
    func answers(_ runner: RunnerPlan) -> [String: YLValue] {
        var out: [String: YLValue] = [:]
        let changes = runner.changes(edits, self)
        if !changes.isEmpty { out["edits"] = .array(changes.map(YLValue.string)) }
        for m in runner.applying(edits).moves {
            if let t = ticked[m.sets.ylID], !t.isEmpty { out[m.sets.ylID] = .array(t.map(YLValue.string)) }
            for n in m.nudges { if let v = values[n.ylID] ?? n.number("value") { out[n.ylID] = .number(v) } }
            // The reps of the set that went to failure (the session's Stop).
            if m.fail, let v = values["\(m.tag)-fail"] { out["\(m.tag)-fail"] = .number(v) }
        }
        return out
    }

    /// Ticks the next set not yet ticked (a "done" out loud). False when all are.
    mutating func tickNext(_ m: RunnerMove) -> Bool {
        var t = (ticked[m.sets.ylID] ?? []).filter { $0 != m.skip }
        guard let next = m.labels.first(where: { !t.contains($0) }) else { return false }
        t.append(next)
        ticked[m.sets.ylID] = m.labels.filter { t.contains($0) }
        return true
    }

    /// A set row tapped: on, or back off. True when it went on.
    mutating func toggle(_ label: String, _ m: RunnerMove) -> Bool {
        var t = ticked[m.sets.ylID] ?? []
        let on = !t.contains(label)
        if on { t.removeAll { $0 == m.skip }; t.append(label) } else { t.removeAll { $0 == label } }
        ticked[m.sets.ylID] = label == m.skip && on ? [label] : m.labels.filter { t.contains($0) }
        return on
    }
}

// MARK: - a move page

/// One move full size: what to do, its sets to tick, reps and weight to nudge, the
/// rest timer after a set, and the mic that hears "done".
struct RunnerMoveView: View {
    let move: RunnerMove
    let rest: Int
    @Binding var progress: RunnerProgress
    let active: Bool
    @State private var talk = PushToTalk()
    @State private var heard = 0
    @State private var rang = false
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private var tag: String { move.tag }

    var body: some View {
        let s = theme.swatch(scheme)
        let c = move.sets
        let ticked = progress.ticked[c.ylID] ?? []
        VStack(alignment: .leading, spacing: theme.spacing.m) {
            if let tag = c.string("tag") {
                Text(tag).font(theme.font(theme.type.caption, .heavy)).foregroundStyle(s.userInk)
                    .padding(.horizontal, theme.spacing.s).padding(.vertical, 3).background(s.butter, in: Capsule())
            }
            Text(c.string("title") ?? c.prompt)
                .font(theme.font(theme.type.display, .heavy)).foregroundStyle(s.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let b = c.string("body") {
                Text(b).font(theme.font(theme.type.body)).foregroundStyle(s.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: theme.spacing.s) {
                ForEach(Array(move.labels.enumerated()), id: \.offset) { i, label in
                    setRow(label, n: i, on: ticked.contains(label), s)
                }
            }
            if let r = progress.rest { restBar(r, s) }
            HStack(spacing: theme.spacing.s) {
                voiceButton(s)
                if let skip = move.skip {
                    OptionPill(text: skip, fill: s.lavender, on: ticked.contains(skip), grow: true) {
                        _ = withAnimation(theme.spring) { progress.toggle(skip, move) }
                    }
                    .accessibilityIdentifier("runner-\(tag)-skip")
                }
            }
            ForEach(move.nudges, id: \.serial) { n in nudge(n, s) }
        }
        .sensoryFeedback(.success, trigger: ticked.count)
        .onChange(of: talk.transcript) { _, words in
            let n = VoiceDone.count(words)
            guard n > heard else { return }
            for _ in heard..<n where progress.tickNext(move) { startRest() }
            heard = n
        }
        .onChange(of: active) { _, on in if !on { stopListening() } }
        .onDisappear(perform: stopListening)
    }

    private func setRow(_ label: String, n: Int, on: Bool, _ s: Swatch) -> some View {
        Button {
            let went = withAnimation(theme.spring) { progress.toggle(label, move) }
            if went { startRest() }
        } label: {
            HStack(spacing: theme.spacing.m) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(theme.font(theme.type.title, .bold))
                    .foregroundStyle(on ? s.onAccent : s.inkSoft)
                    .symbolEffect(.bounce, value: on)
                Text(label).font(theme.font(theme.type.title, .heavy))
                Spacer()
                Text(target(n)).font(theme.font(theme.type.body, .bold).monospacedDigit())
            }
            .foregroundStyle(on ? s.onAccent : s.ink)
            .padding(.horizontal, theme.spacing.l)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(on ? s.accent : s.surface, in: .rect(cornerRadius: theme.radius.bubble))
            .overlay(RoundedRectangle(cornerRadius: theme.radius.bubble).stroke(on ? .clear : s.outline, lineWidth: 1.5))
            .contentShape(.rect)
        }
        .buttonStyle(BounceButtonStyle())
        .accessibilityIdentifier("runner-\(tag)-set-\(n + 1)")
        .accessibilityLabel("\(label), \(target(n))")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// "8 reps · 135 lb" from the nudges as they stand now.
    private func target(_ n: Int) -> String {
        move.nudges.compactMap { c -> String? in
            guard let v = progress.values[c.ylID] ?? c.number("value") else { return nil }
            let unit = c.string("unit") ?? (c.ylID.hasSuffix("-secs") ? "s" : c.ylID.hasSuffix("-reps") ? "reps" : nil)
            return YLComponent.format(v) + (unit.map { $0 == "s" ? $0 : " \($0)" } ?? "")
        }.joined(separator: " · ")
    }

    private func nudge(_ c: YLComponent, _ s: Swatch) -> some View {
        let lo = c.number("min") ?? 0
        let hi = max(c.number("max") ?? 100, lo + 1)
        let step = max(c.number("step") ?? 1, 0.5)
        let v = progress.values[c.ylID] ?? c.number("value") ?? lo
        let what = c.ylID.hasSuffix("-lb") ? "Weight" : c.ylID.hasSuffix("-secs") ? "Seconds" : "Reps"
        let key = c.ylID.hasSuffix("-lb") ? "lb" : c.ylID.hasSuffix("-secs") ? "secs" : "reps"
        return HStack(spacing: theme.spacing.m) {
            Text(what).font(theme.font(theme.type.body, .bold)).foregroundStyle(s.inkSoft)
            Spacer()
            round("minus", s, label: "Less \(what.lowercased())", id: "runner-\(tag)-\(key)-minus") { set(c, max(lo, v - step)) }
                .disabled(v <= lo)
            Text(YLComponent.format(v) + (c.string("unit").map { " \($0)" } ?? ""))
                .font(theme.font(theme.type.title, .black).monospacedDigit())
                .foregroundStyle(s.ink)
                .contentTransition(.numericText())
                .frame(minWidth: 84)
                .accessibilityIdentifier("runner-\(tag)-\(key)-value")
            round("plus", s, label: "More \(what.lowercased())", id: "runner-\(tag)-\(key)-plus") { set(c, min(hi, v + step)) }
                .disabled(v >= hi)
        }
        .padding(.vertical, theme.spacing.xs)
    }

    private func set(_ c: YLComponent, _ v: Double) {
        withAnimation(theme.spring) { progress.values[c.ylID] = v }
    }

    private func round(_ icon: String, _ s: Swatch, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(theme.font(theme.type.body, .black)).foregroundStyle(s.ink)
                .frame(width: 44, height: 44).background(s.lavender, in: Circle())
        }
        .buttonStyle(BounceButtonStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private func restBar(_ r: RestClock, _ s: Swatch) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = r.left(at: ctx.date)
            HStack(spacing: theme.spacing.m) {
                ZStack {
                    Circle().stroke(s.outline, lineWidth: 5)
                    Circle().trim(from: 0, to: r.progress(at: ctx.date))
                        .stroke(s.mint, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 0) {
                    Text(left > 0 ? "Rest" : "Rest done").font(theme.font(theme.type.caption, .heavy)).foregroundStyle(s.inkSoft)
                        .textCase(.uppercase)
                    Text(left > 0 ? RestClock.label(left) : "Next set")
                        .font(theme.font(theme.type.title, .black).monospacedDigit()).foregroundStyle(s.ink)
                        .contentTransition(.numericText(countsDown: true))
                }
                Spacer()
                if left > 0 {
                    Button("+15s") { withAnimation(theme.spring) { progress.rest = r.adding(15, at: ctx.date) } }
                        .accessibilityIdentifier("runner-\(tag)-rest-more")
                }
                Button(left > 0 ? "Skip rest" : "Hide") { withAnimation(theme.spring) { progress.rest = nil } }
                    .accessibilityIdentifier("runner-\(tag)-rest-skip")
            }
            .font(theme.font(theme.type.caption, .heavy))
            .foregroundStyle(s.ink)
            .padding(theme.spacing.m)
            .background(s.surface, in: .rect(cornerRadius: theme.radius.bubble))
            .overlay(RoundedRectangle(cornerRadius: theme.radius.bubble).stroke(s.mint, lineWidth: 1.5))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("runner-\(tag)-rest")
            .onChange(of: left == 0) { _, over in
                guard over, !rang else { return }
                rang = true
                AudioServicesPlaySystemSound(1005)
            }
        }
    }

    private func startRest() {
        rang = false
        withAnimation(theme.spring) { progress.rest = .start(rest) }
    }

    private func voiceButton(_ s: Swatch) -> some View {
        let on = talk.listening
        return Button {
            if on { stopListening() } else {
                heard = 0
                #if DEBUG
                talk.fakeWords = UserDefaults.standard.string(forKey: "yuiPTTFake")
                #endif
                Task { await talk.start() }
            }
        } label: {
            Label(on ? "Listening for done" : talk.phase == .denied ? "Mic is off" : "Say done",
                  systemImage: on ? "waveform" : "mic.fill")
                .font(theme.font(theme.type.body, .bold))
                .foregroundStyle(on ? s.onAccent : s.ink)
                .symbolEffect(.variableColor.iterative, isActive: on)
                .padding(.horizontal, theme.spacing.l)
                .padding(.vertical, theme.spacing.m)
                .frame(maxWidth: .infinity)
                .background(on ? s.accent : s.background, in: Capsule())
                .overlay(Capsule().stroke(on ? .clear : s.outline, lineWidth: 1.5))
        }
        .buttonStyle(BounceButtonStyle())
        .accessibilityIdentifier("runner-\(tag)-voice")
        .accessibilityHint("Say done after a set to tick it")
    }

    private func stopListening() {
        guard talk.listening else { return }
        talk.cancel()
    }
}
