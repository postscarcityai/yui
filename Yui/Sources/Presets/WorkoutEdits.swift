import AVFoundation
import MediaPlayer
import SwiftUI
import YuiLines

// The workout runner, step 2 (feedback AMEDGjyb, Oct 5): music and edits on the fly.
//
// Chris: "I should be able to control the music from here. I should be able to make
// edits on the Fly." A move can be swapped, its sets, reps and weight changed, a move
// added after it or skipped, all from the runner without leaving it. The edits sit on
// the phone with the runner's place, the session's schedule is rebuilt from them, and
// the plan's answer carries one `edits` line per change, so the agent hears what changed.
// The music strip plays, pauses and skips what the Music app is playing; it is gone when
// nothing plays.

/// A move added in the runner: no step of its own in the plan, so the app writes its lines.
struct AddedMove: Codable, Equatable {
    /// `add1`, `add2`: its ids are `add1-sets`, `add1-reps`, `add1-lb`.
    var tag: String
    var name: String
    var sets: Int
    var reps: Double
    var lb: Double?
    /// The move it comes after, by tag.
    var after: String
}

/// What was changed in the runner, kept per plan with its place.
struct RunnerEdits: Codable, Equatable {
    /// Move tag -> the move it was swapped for.
    var swaps: [String: String] = [:]
    /// Move tag -> its set count now.
    var sets: [String: Int] = [:]
    /// Move tag -> reps (or seconds) per set, as edited.
    var reps: [String: Double] = [:]
    /// Move tag -> weight in lb, as edited.
    var lb: [String: Double] = [:]
    var added: [AddedMove] = []

    var isEmpty: Bool { swaps.isEmpty && sets.isEmpty && reps.isEmpty && lb.isEmpty && added.isEmpty }

    /// The next free tag for a move added here.
    var nextTag: String { "add\((added.compactMap { Int($0.tag.dropFirst(3)) }.max() ?? 0) + 1)" }

    /// Moves to swap to, by what the move is: the first three are offered as chips.
    static func alternates(_ name: String) -> [String] {
        let n = name.lowercased()
        let table: [(String, [String])] = [
            ("squat", ["Leg press", "Split squat", "Box squat"]),
            ("lunge", ["Split squat", "Step-up", "Goblet squat"]),
            ("deadlift", ["Romanian deadlift", "Hip thrust", "Kettlebell swing"]),
            ("push-up", ["Incline push-up", "Bench press", "Knee push-up"]),
            ("push up", ["Incline push-up", "Bench press", "Knee push-up"]),
            ("bench", ["Dumbbell press", "Push-up", "Incline press"]),
            ("overhead", ["Arnold press", "Landmine press", "Pike push-up"]),
            ("press", ["Dumbbell press", "Push-up", "Landmine press"]),
            ("row", ["Cable row", "Band row", "Inverted row"]),
            ("pull", ["Lat pulldown", "Band pull-down", "Inverted row"]),
            ("plank", ["Dead bug", "Side plank", "Hollow hold"]),
            ("curl", ["Hammer curl", "Band curl", "Chin-up"]),
            ("bridge", ["Hip thrust", "Single-leg bridge", "Kettlebell swing"]),
        ]
        return table.first { n.contains($0.0) }?.1 ?? ["Push-up", "Goblet squat", "Plank"]
    }

    /// Moves to add, the usual fillers.
    static let extras = ["Lunge", "Plank", "Burpee", "Curl"]
}

extension RunnerMove {
    /// A move added in the runner, as if the plan had sent it: a sets pick and a reps (and weight) slide.
    static func added(_ a: AddedMove) -> RunnerMove? {
        let name = a.name.replacingOccurrences(of: "\"", with: "")
        let labels = (1...max(1, a.sets)).map { "\"Set \($0)\"" }.joined(separator: "|")
        var yl = "pick@\(a.tag)-sets \"\(name): sets done\" \(labels)|Skip title=\"\(name)\"\n"
        yl += "slide@\(a.tag)-reps \"\(name): reps per set\" 1-60 value=\(YLComponent.format(a.reps))\n"
        if let lb = a.lb { yl += "slide@\(a.tag)-lb \"\(name): weight in lb\" 0-500 value=\(YLComponent.format(lb)) step=5 unit=lb\n" }
        let all = YLScreen(yl).components
        guard let sets = all.first(where: { $0.preset == "pick" }) else { return nil }
        return RunnerMove(sets: sets, labels: (1...max(1, a.sets)).map { "Set \($0)" }, skip: "Skip",
                          nudges: all.filter { $0.preset == "slide" })
    }
}

extension RunnerPlan {
    /// The plan as edited: swaps renamed, set counts changed, added moves in after the move they follow.
    func applying(_ e: RunnerEdits?) -> RunnerPlan {
        guard let e, !e.isEmpty else { return self }
        var out = moves
        for a in e.added {
            guard let m = RunnerMove.added(a) else { continue }
            // After its anchor and after any move added there before it.
            var i = (out.firstIndex { $0.tag == a.after } ?? out.count - 1) + 1
            while i < out.count, e.added.contains(where: { $0.tag == out[i].tag && $0.after == a.after }) { i += 1 }
            out.insert(m, at: min(i, out.count))
        }
        out = out.map { m in
            var m = m
            if let name = e.swaps[m.tag] {
                m.title = name
                // The cue and the load call were for the old move.
                m.cue = nil
                m.why = nil
            }
            if let n = e.sets[m.tag], n != m.labels.count { m.labels = (1...max(1, min(n, 12))).map { "Set \($0)" } }
            return m
        }
        return RunnerPlan(moves: out, rest: rest)
    }

    /// One line per change, in move order: what the plan's `edits` answer says.
    func changes(_ e: RunnerEdits?, _ p: RunnerProgress) -> [String] {
        let live = applying(e)
        var out: [String] = []
        for m in live.moves {
            let base = moves.first { $0.tag == m.tag }
            let skipped = m.skip != nil && p.ticked[m.sets.ylID] == [m.skip!]
            if let a = e?.added.first(where: { $0.tag == m.tag }) {
                if skipped { continue }
                let reps = p.values["\(a.tag)-reps"] ?? a.reps
                let lb = (p.values["\(a.tag)-lb"] ?? a.lb).map { " at \(YLComponent.format($0)) lb" } ?? ""
                out.append("Added \(m.name) \(m.labels.count)x\(YLComponent.format(reps))\(lb)")
                continue
            }
            guard let base else { continue }
            if let to = e?.swaps[m.tag] { out.append("Swapped \(base.name) for \(to)") }
            // A skip is in the move's own answer (its sets pick says Skip).
            if skipped { continue }
            if m.labels.count != base.labels.count { out.append("\(m.name): \(m.labels.count) sets (was \(base.labels.count))") }
            if let r = e?.reps[m.tag], let n = base.nudges.first(where: { !$0.ylID.hasSuffix("-lb") }) {
                let secs = n.ylID.hasSuffix("-secs")
                let was = n.number("value").map { YLComponent.format($0) } ?? "?"
                out.append(secs ? "\(m.name): \(YLComponent.format(r))s (was \(was)s)" : "\(m.name): \(YLComponent.format(r)) reps (was \(was))")
            }
            if let w = e?.lb[m.tag], let n = base.nudges.first(where: { $0.ylID.hasSuffix("-lb") }) {
                let was = n.number("value").map { YLComponent.format($0) } ?? "?"
                out.append("\(m.name): \(YLComponent.format(w)) lb (was \(was) lb)")
            }
        }
        return out
    }
}

extension RunnerProgress {
    /// Changes the plan mid-session: the edit lands, the schedule is rebuilt from it, and the run stays on the
    /// same move and set (or goes on to the next move when its set was cut). Sets ticked past a cut are dropped.
    mutating func edit(_ base: RunnerPlan, at now: Date = .now, fast: Bool = SessionEngine.fast, _ f: (inout RunnerEdits) -> Void) {
        let old = SessionEngine(base.applying(edits), fast: fast)
        let here = run.flatMap { old.current($0) }.map { (tag: old.runner.moves[$0.move].tag, set: $0.set, kind: $0.kind) }
        let before = edits ?? RunnerEdits()
        var e = before
        f(&e)
        edits = e.isEmpty ? nil : e
        let live = base.applying(edits)
        func reps(_ e: RunnerEdits, _ tag: String) -> Double? { e.added.first { $0.tag == tag }?.reps ?? e.reps[tag] }
        func lb(_ e: RunnerEdits, _ tag: String) -> Double? { e.added.first { $0.tag == tag }?.lb ?? e.lb[tag] }
        for m in live.moves {
            if let t = ticked[m.sets.ylID] { ticked[m.sets.ylID] = t.filter { m.labels.contains($0) || $0 == m.skip } }
            // An edited number is the move's number from here on; undone, it is the plan's again.
            if let n = m.nudges.first(where: { !$0.ylID.hasSuffix("-lb") }), reps(before, m.tag) != reps(e, m.tag) {
                values[n.ylID] = reps(e, m.tag) ?? n.number("value")
            }
            if let n = m.nudges.first(where: { $0.ylID.hasSuffix("-lb") }), lb(before, m.tag) != lb(e, m.tag) {
                values[n.ylID] = lb(e, m.tag) ?? n.number("value")
            }
        }
        guard var r = run, r.finished == nil, let here else { return }
        let new = SessionEngine(live, fast: fast)
        func same(_ a: SessionStep.Kind, _ b: SessionStep.Kind) -> Bool { a == b || ([a, b].allSatisfy { $0 == .work || $0 == .fail }) }
        let idx = new.steps.firstIndex { new.runner.moves[$0.move].tag == here.tag && $0.set == here.set && same($0.kind, here.kind) }
            // The set was cut: on to the next move's first set (or the end).
            ?? new.runner.moves.firstIndex { $0.tag == here.tag }.flatMap { mi in new.steps.firstIndex { $0.move > mi } }
        guard let i = idx else {
            r.step = new.steps.count
            r.finished = now
            r.ends = now
            run = r
            return
        }
        // Moved means another move or set, not another index: a cut set can leave the next move on the same index.
        let landed = new.steps[i]
        let moved = new.runner.moves[landed.move].tag != here.tag || landed.set != here.set || landed.kind != here.kind
        r.step = i
        if moved || new.steps[i].seconds == 0 {
            // A new step, or one that now waits: its clock starts now.
            r.ends = new.steps[i].seconds == 0 ? .distantFuture : now.addingTimeInterval(TimeInterval(new.steps[i].seconds))
            if r.paused != nil { r.paused = new.steps[i].seconds }
        }
        run = r
    }
}

// MARK: - the edit sheet

/// Edit the move in focus, without leaving the runner: swap it, its sets, reps and weight, add a move after it.
struct RunnerEditSheet: View {
    let base: RunnerPlan
    /// The move being edited, by tag.
    let tag: String
    @Binding var progress: RunnerProgress
    @State private var other = ""
    @State private var adding = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private var live: RunnerPlan { base.applying(progress.edits) }
    private var move: RunnerMove? { live.moves.first { $0.tag == tag } }

    var body: some View {
        let s = theme.swatch(scheme)
        ScrollView {
            VStack(alignment: .leading, spacing: theme.spacing.l) {
                if let m = move {
                    HStack {
                        Text("Edit \(m.name)").font(theme.font(theme.type.display, .heavy)).foregroundStyle(s.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("runner-edit-title")
                        Spacer()
                        OptionPill(text: "Back to it", fill: s.accent, ink: s.onAccent) { dismiss() }
                            .accessibilityIdentifier("runner-edit-close")
                    }
                    numbers(m, s)
                    swap(m, s)
                    add(m, s)
                    changed(s)
                }
            }
            .padding(theme.spacing.l)
        }
        .background(s.background.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func change(_ f: (inout RunnerEdits) -> Void) {
        var p = progress
        p.edit(base, f)
        withAnimation(theme.spring) { progress = p }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    // Sets, reps (or seconds), weight: one stepper each.
    private func numbers(_ m: RunnerMove, _ s: Swatch) -> some View {
        let repsNudge = m.nudges.first { !$0.ylID.hasSuffix("-lb") }
        let lbNudge = m.nudges.first { $0.ylID.hasSuffix("-lb") }
        let timed = repsNudge?.ylID.hasSuffix("-secs") ?? false
        let reps = repsNudge.flatMap { progress.values[$0.ylID] ?? $0.number("value") }
        let lb = lbNudge.flatMap { progress.values[$0.ylID] ?? $0.number("value") }
        let added = progress.edits?.added.contains { $0.tag == m.tag } ?? false
        return VStack(spacing: theme.spacing.s) {
            stepper("Sets", value: "\(m.labels.count)", id: "runner-edit-sets", s,
                    less: m.labels.count > 1 ? { change { $0.sets[m.tag] = m.labels.count - 1; settle(&$0, m) } } : nil,
                    more: m.labels.count < 12 ? { change { $0.sets[m.tag] = m.labels.count + 1; settle(&$0, m) } } : nil)
            if let reps, let n = repsNudge {
                let step = max(n.number("step") ?? (timed ? 5 : 1), 1)
                stepper(timed ? "Seconds" : "Reps", value: YLComponent.format(reps) + (timed ? "s" : ""), id: "runner-edit-reps", s,
                        less: reps - step >= 1 ? { change { $0.reps[m.tag] = reps - step; settle(&$0, m) } } : nil,
                        more: { change { $0.reps[m.tag] = reps + step; settle(&$0, m) } })
            }
            if let lb, let n = lbNudge {
                let step = max(n.number("step") ?? 5, 0.5)
                stepper("Weight", value: YLComponent.format(lb) + " lb", id: "runner-edit-lb", s,
                        less: lb - step >= 0 ? { change { $0.lb[m.tag] = lb - step; settle(&$0, m) } } : nil,
                        more: { change { $0.lb[m.tag] = lb + step; settle(&$0, m) } })
            }
            if added {
                Text("Added in this session.").font(theme.font(theme.type.caption, .bold)).foregroundStyle(s.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// An added move keeps its own numbers, so the change list says "Added Lunge 4x12", not a change on top.
    private func settle(_ e: inout RunnerEdits, _ m: RunnerMove) {
        guard let i = e.added.firstIndex(where: { $0.tag == m.tag }) else {
            // Back to the plan's own number: no change left to report.
            let base = self.base.moves.first { $0.tag == m.tag }
            if let b = base, e.sets[m.tag] == b.labels.count { e.sets[m.tag] = nil }
            if let r = e.reps[m.tag], base?.nudges.first(where: { !$0.ylID.hasSuffix("-lb") })?.number("value") == r { e.reps[m.tag] = nil }
            if let w = e.lb[m.tag], base?.nudges.first(where: { $0.ylID.hasSuffix("-lb") })?.number("value") == w { e.lb[m.tag] = nil }
            return
        }
        if let n = e.sets.removeValue(forKey: m.tag) { e.added[i].sets = n }
        if let r = e.reps.removeValue(forKey: m.tag) { e.added[i].reps = r }
        if let w = e.lb.removeValue(forKey: m.tag) { e.added[i].lb = w }
    }

    private func stepper(_ what: String, value: String, id: String, _ s: Swatch, less: (() -> Void)?, more: (() -> Void)?) -> some View {
        HStack(spacing: theme.spacing.m) {
            Text(what).font(theme.font(theme.type.body, .bold)).foregroundStyle(s.inkSoft)
            Spacer()
            round("minus", "Less \(what.lowercased())", id: "\(id)-minus", s, less)
            Text(value).font(theme.font(theme.type.title, .black).monospacedDigit()).foregroundStyle(s.ink)
                .frame(minWidth: 84).accessibilityIdentifier("\(id)-value")
                .contentTransition(.numericText())
            round("plus", "More \(what.lowercased())", id: "\(id)-plus", s, more)
        }
        .padding(theme.spacing.m)
        .background(s.surface, in: .rect(cornerRadius: theme.radius.bubble))
    }

    private func round(_ icon: String, _ label: String, id: String, _ s: Swatch, _ action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            Image(systemName: icon).font(theme.font(theme.type.body, .black)).foregroundStyle(s.ink)
                .frame(width: 48, height: 48).background(s.lavender, in: Circle())
                .opacity(action == nil ? 0.35 : 1)
        }
        .buttonStyle(BounceButtonStyle())
        .disabled(action == nil)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private func swap(_ m: RunnerMove, _ s: Swatch) -> some View {
        let original = base.moves.first { $0.tag == m.tag }?.name
        let options = RunnerEdits.alternates(original ?? m.name).filter { $0 != m.name }
        return VStack(alignment: .leading, spacing: theme.spacing.s) {
            Text("Swap it for").font(theme.font(theme.type.body, .heavy)).foregroundStyle(s.ink)
            FlowLayout(spacing: theme.spacing.xs) {
                if let original, original != m.name, progress.edits?.swaps[m.tag] != nil {
                    OptionPill(text: "Back to \(original)", fill: s.butter) { change { $0.swaps[m.tag] = nil } }
                        .accessibilityIdentifier("runner-edit-unswap")
                }
                ForEach(options.prefix(3), id: \.self) { o in
                    OptionPill(text: o, fill: s.lavender) { swapTo(o, m) }
                        .accessibilityIdentifier("runner-edit-swap-\(o.lowercased().replacingOccurrences(of: " ", with: "-"))")
                }
            }
            field("Something else", text: $other, id: "runner-edit-swap-other", go: "Swap", s) { swapTo(other, m); other = "" }
        }
    }

    private func swapTo(_ name: String, _ m: RunnerMove) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        change { e in
            if let i = e.added.firstIndex(where: { $0.tag == m.tag }) { e.added[i].name = name; return }
            e.swaps[m.tag] = name == base.moves.first { $0.tag == m.tag }?.name ? nil : name
        }
    }

    private func add(_ m: RunnerMove, _ s: Swatch) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.s) {
            Text("Add a move after it").font(theme.font(theme.type.body, .heavy)).foregroundStyle(s.ink)
            FlowLayout(spacing: theme.spacing.xs) {
                ForEach(RunnerEdits.extras.filter { x in !live.moves.contains { $0.name == x } }, id: \.self) { x in
                    OptionPill(text: "+ \(x)", fill: s.mint) { addMove(x, after: m) }
                        .accessibilityIdentifier("runner-edit-add-\(x.lowercased())")
                }
            }
            field("Another move", text: $adding, id: "runner-edit-add-other", go: "Add", s) { addMove(adding, after: m); adding = "" }
        }
    }

    private func addMove(_ name: String, after m: RunnerMove) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let timed = name.lowercased().contains("plank") || name.lowercased().contains("hold")
        change { e in e.added.append(AddedMove(tag: e.nextTag, name: name, sets: 3, reps: timed ? 30 : 10, lb: nil, after: m.tag)) }
    }

    private func field(_ hint: String, text: Binding<String>, id: String, go: String, _ s: Swatch, action: @escaping () -> Void) -> some View {
        HStack(spacing: theme.spacing.s) {
            TextField(hint, text: text)
                .font(theme.font(theme.type.body, .semibold)).foregroundStyle(s.ink)
                .submitLabel(.done).onSubmit(action)
                .padding(.horizontal, theme.spacing.m).padding(.vertical, theme.spacing.s + 2)
                .background(s.surface, in: Capsule())
                .overlay(Capsule().stroke(s.outline, lineWidth: 1.5))
                .accessibilityIdentifier(id)
            NameMic(text: text, id: "\(id)-mic", label: "Say the move")
            if !text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty {
                OptionPill(text: go, fill: s.accent, ink: s.onAccent, action: action)
                    .accessibilityIdentifier("\(id)-go")
            }
        }
    }

    private func changed(_ s: Swatch) -> some View {
        let lines = base.changes(progress.edits, progress)
        return VStack(alignment: .leading, spacing: theme.spacing.xs) {
            if !lines.isEmpty {
                Text("Changed").font(theme.font(theme.type.caption, .heavy)).textCase(.uppercase).foregroundStyle(s.inkSoft)
                ForEach(lines, id: \.self) { l in
                    Label(l, systemImage: "pencil").font(theme.font(theme.type.body, .semibold)).foregroundStyle(s.ink)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("runner-edit-changes")
    }
}

// MARK: - music

/// What the Music app is playing, and its play, pause and next. Nothing playing: no strip.
@MainActor @Observable
final class NowPlaying {
    private(set) var title: String?
    private(set) var artist: String?
    private(set) var playing = false
    private var watching: [NSObjectProtocol] = []
    /// `-yuiMusicFake` (UI tests, shots): a made-up song, and the buttons act on it.
    private let fake: Bool
    private var fakeAt = 0
    private static let fakes = [("Midnight City", "M83"), ("Harder, Better, Faster, Stronger", "Daft Punk"), ("Run", "Air")]

    var visible: Bool { title != nil }

    init() {
        #if DEBUG
        fake = ProcessInfo.processInfo.arguments.contains("-yuiMusicFake")
        #else
        fake = false
        #endif
    }

    private var player: MPMusicPlayerController { .systemMusicPlayer }

    func start() {
        if fake { (title, artist) = Self.fakes[fakeAt]; playing = true; return }
        guard watching.isEmpty else { return }
        // Asked once, only when something is already playing: the person brought music to the workout.
        if MPMediaLibrary.authorizationStatus() == .notDetermined, AVAudioSession.sharedInstance().isOtherAudioPlaying {
            MPMediaLibrary.requestAuthorization { _ in Task { @MainActor in self.refresh() } }
        }
        player.beginGeneratingPlaybackNotifications()
        let nc = NotificationCenter.default
        for name in [Notification.Name.MPMusicPlayerControllerPlaybackStateDidChange, .MPMusicPlayerControllerNowPlayingItemDidChange] {
            watching.append(nc.addObserver(forName: name, object: player, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    func stop() {
        guard !fake else { return }
        watching.forEach(NotificationCenter.default.removeObserver)
        watching = []
        player.endGeneratingPlaybackNotifications()
    }

    func refresh() {
        guard !fake else { return }
        let state = player.playbackState
        playing = state == .playing
        let item = MPMediaLibrary.authorizationStatus() == .authorized ? player.nowPlayingItem : nil
        // Playing or paused mid-song shows the strip; stopped (or nothing ever played) hides it.
        let live = state == .playing || state == .paused || state == .interrupted
        title = live ? (item?.title ?? "Music") : nil
        artist = live ? item?.artist : nil
    }

    func toggle() {
        if fake { playing.toggle(); return }
        if player.playbackState == .playing { player.pause() } else { player.play() }
        refresh()
    }

    func next() {
        if fake { fakeAt = (fakeAt + 1) % Self.fakes.count; (title, artist) = Self.fakes[fakeAt]; playing = true; return }
        player.skipToNextItem()
        refresh()
    }

    func previous() {
        if fake { fakeAt = (fakeAt + Self.fakes.count - 1) % Self.fakes.count; (title, artist) = Self.fakes[fakeAt]; return }
        player.skipToPreviousItem()
        refresh()
    }
}

/// The now-playing strip in the runner: the song, back, play or pause, next. Gone when nothing plays.
struct MusicStrip: View {
    let music: NowPlaying
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        if music.visible {
            HStack(spacing: theme.spacing.s) {
                Image(systemName: music.playing ? "waveform" : "music.note")
                    .font(theme.font(theme.type.body, .black)).foregroundStyle(s.accent)
                    .symbolEffect(.variableColor.iterative, isActive: music.playing)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(music.title ?? "").font(theme.font(theme.type.caption, .heavy)).foregroundStyle(s.ink).lineLimit(1)
                        .accessibilityIdentifier("session-music-title")
                    if let a = music.artist {
                        Text(a).font(theme.font(theme.type.caption, .medium)).foregroundStyle(s.inkSoft).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                button("backward.fill", "Previous song", id: "session-music-back", s) { music.previous() }
                button(music.playing ? "pause.fill" : "play.fill", music.playing ? "Pause music" : "Play music", id: "session-music-play", s) { music.toggle() }
                button("forward.fill", "Next song", id: "session-music-next", s) { music.next() }
            }
            .padding(.horizontal, theme.spacing.m).padding(.vertical, theme.spacing.s)
            .background(s.surface, in: Capsule())
            .overlay(Capsule().stroke(s.outline, lineWidth: 1.5))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("session-music")
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func button(_ icon: String, _ label: String, id: String, _ s: Swatch, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(theme.font(theme.type.body, .black)).foregroundStyle(s.ink)
                .frame(width: 40, height: 40).contentShape(.rect)
        }
        .buttonStyle(BounceButtonStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}
