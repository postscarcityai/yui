import SwiftUI
import YuiLines
import YuiSound

// Music presets (YUI-116, yuigui spec/MUSIC.md). Every sound comes from the
// one engine in YuiSound: one clock, one voice bank, one limiter. Step 2 drew
// `loop` and `drums`; step 3 adds `keys` and `chords` (MusicKeys.swift).

/// Patterns as the agent writes them: one string per row, `x` a hit, `.` a rest.
enum LoopPattern {
    /// Rows of on/off cells, padded or cut to `steps`.
    static func grid(_ p: [String], rows: Int, steps: Int) -> [[Bool]] {
        (0..<rows).map { r in
            let s = r < p.count ? Array(p[r]) : []
            return (0..<steps).map { i in i < s.count && "xX1o*".contains(s[i]) }
        }
    }

    /// And back: an empty string for a row with no hits.
    static func strings(_ grid: [[Bool]]) -> [String] {
        grid.map { row in row.contains(true) ? String(row.map { $0 ? "x" : "." }) : "" }
    }

    /// Pad hits (seconds from the first downbeat) snapped to 16ths over
    /// `steps`. Rows are the pads that were hit, in pad order.
    static func take(_ hits: [(pad: String, t: Double)], pads: [String], bpm: Int, steps: Int = 32) -> (rows: [String], p: [String]) {
        let d = 60 / Double(bpm) / 4
        var hit: [String: [Bool]] = [:]
        for h in hits {
            let i = Int((h.t / d).rounded())
            guard i >= 0, i <= steps else { continue }
            hit[h.pad, default: Array(repeating: false, count: steps)][i % steps] = true
        }
        let rows = pads.filter { hit[$0] != nil }
        return (rows, strings(rows.map { hit[$0]! }))
    }
}

extension YLComponent {
    fileprivate func clamp(_ key: String, _ range: ClosedRange<Int>, _ d: Int) -> Int {
        guard let n = number(key), n.isFinite else { return d }
        return min(range.upperBound, max(range.lowerBound, Int(n.rounded())))
    }
}

/// One loop plays at a time: the last one started owns the engine's looper.
@MainActor @Observable
final class MusicHost {
    static let shared = MusicHost()
    var loopOwner: Int?
    /// The metronome that is clicking, if any (one at a time, like the loop).
    var metroOwner: Int?
    /// The instrument recording a take, if any (one at a time).
    var takeOwner: Int?
    /// Stops the clicking metronome and sends its practice (YUI-184).
    @ObservationIgnored var metroStop: (() -> Void)?

    /// The thread is about to show another agent: the click stops now, while its practice
    /// still goes to the agent it clicked for. One store serves every agent, so a click
    /// stopped by its view going away would log Gouda's minutes on the next agent.
    func leavingAgent() {
        let stop = metroStop
        metroStop = nil
        stop?()
    }
}

/// Row colors from the agent's theme, so a beat looks like its agent.
func rowColor(_ i: Int, _ s: Swatch) -> Color {
    [s.accent, s.mint, s.lavender, s.butter, s.brand, s.inkSoft][i % 6]
}

/// Holds the engine open while an instrument is on screen.
struct SoundHold: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear {
                #if DEBUG
                MIDIFeed.startIfAsked()
                #endif
                YuiSound.shared.acquire()
            }
            .onDisappear { YuiSound.shared.release() }
    }
}

/// The one line shown when the sound goes out over Bluetooth (MUSIC.md section 5).
struct BluetoothHint: View {
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if YuiSound.shared.isBluetooth {
            Label("Bluetooth adds a delay. Wired or the speaker feels tighter.", systemImage: "airpods")
                .font(theme.font(theme.type.caption, .semibold))
                .foregroundStyle(theme.swatch(scheme).inkSoft)
                .accessibilityIdentifier("music-bluetooth")
        }
    }
}

/// The title and a small line under it.
struct MusicHead: View {
    let title: String
    let sub: String
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            PresetTitle(text: title)
            Spacer(minLength: 0)
            Text(sub)
                .font(theme.font(theme.type.caption, .bold))
                .foregroundStyle(theme.swatch(scheme).inkSoft)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }
}

/// A small round control under the grid.
struct MusicButton: View {
    let text: String
    var icon: String? = nil
    var on = false
    let action: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        Button(action: action) {
            HStack(spacing: theme.spacing.xs) {
                if let icon { Image(systemName: icon).accessibilityHidden(true) }
                if !text.isEmpty { Text(text).monospacedDigit().lineLimit(1) }
            }
            .font(theme.font(theme.type.body, .bold))
            .foregroundStyle(on ? s.onAccent : s.ink)
            .padding(.horizontal, theme.spacing.m)
            .padding(.vertical, theme.spacing.s)
            .background(on ? s.accent : s.background, in: Capsule())
            .overlay(Capsule().stroke(on ? .clear : s.outline, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - loop

/// `loop [BPM] [title]`: a step grid. Rows are sounds or notes, columns are
/// steps. Tap a cell to turn it on; every change plays at once. Send hands the
/// pattern back in the words the agent writes.
struct LoopPreset: View {
    let c: YLComponent
    /// The person's grid, until a patch from the agent replaces it.
    @State private var edited: [[Bool]]?
    @State private var bpm = 96
    @State private var swing = 0
    @State private var sent = false
    @State private var tapped = 0
    private var host: MusicHost { .shared }
    @Environment(\.ylEmit) private var emit
    @Environment(\.ylScope) private var scope
    @Environment(\.ylAnswers) private var answers
    @Environment(\.ylAgent) private var agent
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private var steps: Int { c.clamp("steps", 4...16, 8) }
    private var rows: [String] {
        let r = c.strings("rows") ?? []
        return Array((r.isEmpty ? Array(YuiSound.kit.prefix(8)) : r).prefix(16))
    }
    private var sound: String { c.string("sound") ?? "pluck" }
    private var grid: [[Bool]] { edited ?? LoopPattern.grid(c.strings("p") ?? [], rows: rows.count, steps: steps) }
    private var playing: Bool { host.loopOwner == c.serial }
    /// What a patch can change: the grid resets to the agent's version.
    private var patternKey: [YLValue?] { [c.props["p"], c.props["rows"], c.props["steps"]] }
    /// The loop as the agent drew it, which a beat kept on the phone sits on (YUI-184).
    private var base: String {
        LoopDrafts.base(p: c.strings("p") ?? [], rows: rows, steps: steps,
                        bpm: c.clamp("bpm", 40...240, 96), swing: c.clamp("swing", 0...75, 0))
    }
    /// The person's unsent beat on this loop, kept on the phone (a looper the agent named).
    private var draft: LoopDrafts.Draft? { LoopDrafts.shared.draft(agent, c.ylID, base: base) }

    var body: some View {
        let s = theme.swatch(scheme)
        let g = grid
        PresetCard {
            MusicHead(title: c.string("title").flatMap { $0.isEmpty ? nil : $0 } ?? "Loop",
                      sub: swing > 0 ? "\(bpm) BPM · swing \(swing)%" : "\(bpm) BPM")
            TimelineView(.animation(paused: !playing)) { _ in
                let head = playing ? YuiSound.shared.audibleStep : nil
                VStack(spacing: theme.spacing.s) {
                    // More than 8 steps wrap into a second bank, so cells stay thumb sized.
                    ForEach(banks, id: \.lowerBound) { bank in
                        bankView(bank, g, head: head, s)
                    }
                }
            }
            // Narrow (inline in the chat): Play loses its word, swing its label.
            ViewThatFits(in: .horizontal) {
                controls(compact: false)
                controls(compact: true)
            }
            BluetoothHint()
            TakeControl(c: c, bpm: Double(bpm)) { ["bpm": .number(Double(bpm))] }
            OptionPill(text: sent ? "Sent" : "Send", fill: s.accent, ink: s.onAccent, check: sent, grow: true) { send() }
                .disabled(c.locked)
                .accessibilityIdentifier("loop-send")
        }
        .modifier(SoundHold())
        .sensoryFeedback(.selection, trigger: tapped)
        .onChange(of: patternKey) { edited = nil; sync() }
        .onChange(of: c.props["bpm"], initial: true) { bpm = draft?.bpm ?? c.clamp("bpm", 40...240, 96) }
        .onChange(of: c.props["swing"], initial: true) { swing = draft?.swing ?? c.clamp("swing", 0...75, 0) }
        .onChange(of: base, initial: true) { old, new in
            // A beat kept on the phone comes back on a relaunch or another agent and back.
            if let d = draft {
                edited = LoopPattern.grid(d.p, rows: rows.count, steps: steps)
                bpm = d.bpm
                swing = d.swing
                sent = false
                sync()
                return
            }
            // The agent drew a different loop: its draft goes. A tempo change alone keeps the grid.
            LoopDrafts.shared.prune(agent, c.ylID, base: new)
            if old != new, edited != nil, old.split(separator: ";").prefix(3) == new.split(separator: ";").prefix(3) { keep() }
        }
        .onChange(of: bpm) { sync() }
        .onChange(of: swing) { sync() }
        .onChange(of: answers(scope, c.ylID), initial: true) { _, v in
            // A reopened thread: the pattern the person sent last.
            guard edited == nil, let v, let p = v["p"]?.array?.compactMap(\.string) else { return }
            edited = LoopPattern.grid(p, rows: rows.count, steps: steps)
            if let b = v["bpm"]?.number { bpm = Int(b) }
            if let w = v["swing"]?.number { swing = Int(w) }
            sent = true
        }
        .onAppear { if c.flag("play") && host.loopOwner == nil { start() } }
        .onDisappear { if playing { stop() } }
    }

    private func controls(compact: Bool) -> some View {
        HStack(spacing: theme.spacing.s) {
            MusicButton(text: compact ? "" : playing ? "Stop" : "Play", icon: playing ? "stop.fill" : "play.fill", on: playing) {
                playing ? stop() : start()
            }
            .accessibilityLabel(playing ? "Stop" : "Play")
            .accessibilityIdentifier("loop-play")
            Spacer(minLength: 0)
            MusicButton(text: "−") { bpm = max(40, bpm - 2); keep() }.accessibilityLabel("Slower")
                .accessibilityIdentifier("loop-slower")
            MusicButton(text: "+") { bpm = min(240, bpm + 2); keep() }.accessibilityLabel("Faster")
                .accessibilityIdentifier("loop-faster")
            MusicButton(text: compact ? "\(swing)%" : "Swing \(swing)%") { swing = swing >= 75 ? 0 : swing + 25; keep() }
                .accessibilityLabel("Swing \(swing) percent")
                .accessibilityIdentifier("loop-swing")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var banks: [Range<Int>] { steps > 8 ? [0..<8, 8..<steps] : [0..<steps] }

    private func bankView(_ bank: Range<Int>, _ g: [[Bool]], head: Int?, _ s: Swatch) -> some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(rows.indices, id: \.self) { r in
                GridRow {
                    Button { YuiSound.shared.play(rows[r], sound: sound) } label: {
                        Text(rows[r])
                            .font(theme.font(theme.type.caption, .bold))
                            .foregroundStyle(s.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(width: 50, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hear \(rows[r])")
                    ForEach(bank, id: \.self) { k in
                        cell(r, k, on: g[r][k], head: head == k, s)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(banks.count > 1 ? "Steps \(bank.lowerBound + 1) to \(bank.upperBound)" : "Pattern")
    }

    private func cell(_ r: Int, _ k: Int, on: Bool, head: Bool, _ s: Swatch) -> some View {
        let color = rowColor(r, s)
        return Button { toggle(r, k) } label: {
            RoundedRectangle(cornerRadius: 7)
                .fill(on ? color : (k % 4 == 0 ? s.outline.opacity(0.45) : s.background))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(head ? s.ink : s.outline, lineWidth: head ? 2.5 : 1))
                .brightness(head && on ? 0.12 : 0)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(c.locked)
        .accessibilityLabel("\(rows[r]), step \(k + 1)")
        .accessibilityValue(on ? "on" : "off")
        .accessibilityIdentifier("loop-cell-\(r)-\(k)")
    }

    private func toggle(_ r: Int, _ k: Int) {
        var g = grid
        g[r][k].toggle()
        if g[r][k], !playing { YuiSound.shared.play(rows[r], sound: sound) }
        edited = g
        sent = false
        tapped += 1
        sync()
        keep()
    }

    /// The beat as it is now, kept on the phone until it is sent or the agent changes the loop.
    /// Back to the agent's own loop, nothing is kept.
    private func keep() {
        let p = LoopPattern.strings(grid)
        let theirs = LoopPattern.strings(LoopPattern.grid(c.strings("p") ?? [], rows: rows.count, steps: steps))
        if p == theirs, bpm == c.clamp("bpm", 40...240, 96), swing == c.clamp("swing", 0...75, 0) {
            LoopDrafts.shared.clear(agent, c.ylID)
        } else {
            LoopDrafts.shared.set(agent, c.ylID, .init(base: base, p: p, bpm: bpm, swing: swing))
        }
    }

    /// Hands the current loop to the engine; it lands on the next step.
    private func sync() {
        guard playing else { return }
        YuiSound.shared.setLoop(rows: rows, sound: sound, steps: steps, bpm: Double(bpm), swing: Double(swing), pattern: grid)
    }

    private func start() {
        host.loopOwner = c.serial
        sync()
        YuiSound.shared.startLoop()
    }

    private func stop() {
        guard playing else { return }
        YuiSound.shared.stopLoop()
        host.loopOwner = nil
    }

    private func send() {
        emit(c.event([
            "bpm": .number(Double(bpm)), "swing": .number(Double(swing)), "steps": .number(Double(steps)),
            "rows": .array(rows.map(YLValue.string)), "p": .array(LoopPattern.strings(grid).map(YLValue.string)),
        ], echo: "Sent my beat, \(bpm) BPM"))
        sent = true
    }
}

// MARK: - drums

/// `drums [RxC] [title]`: big pads that play on touch down. With `+record`,
/// one bar of count-in, two bars recorded and snapped to 16ths, sent as a take
/// in the loop's shape.
struct DrumsPreset: View {
    let c: YLComponent
    @State private var lit: [Int: Int] = [:]
    @State private var phase = Phase.idle
    @State private var hits: [(pad: String, t: Double)] = []
    @State private var tapped = 0
    private var host: MusicHost { .shared }
    @Environment(\.ylEmit) private var emit
    @Environment(\.yuiMedia) private var media
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    enum Phase { case idle, recording, sending, done, empty }

    private var grid: (rows: Int, cols: Int) {
        let n = (c.string("grid") ?? "2x2").lowercased().split(separator: "x").compactMap { Int($0) }
        guard n.count == 2 else { return (2, 2) }
        return (min(4, max(1, n[0])), min(4, max(1, n[1])))
    }
    private var pads: [String] {
        let (r, cols) = grid
        let given = Array((c.strings("pads") ?? []).prefix(r * cols))
        return Array((given + YuiSound.kit.filter { !given.contains($0) }).prefix(r * cols))
    }
    private var bpm: Int { c.clamp("bpm", 40...240, 96) }
    /// A 16th at this tempo, and the count-in bar in seconds.
    private var sixteenth: Double { 60 / Double(bpm) / 4 }

    var body: some View {
        let s = theme.swatch(scheme)
        let (rs, cs) = grid
        let p = pads
        PresetCard {
            MusicHead(title: c.string("title").flatMap { $0.isEmpty ? nil : $0 } ?? "Drums",
                      sub: c.flag("record") ? "\(bpm) BPM" : "")
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                ForEach(0..<rs, id: \.self) { r in
                    GridRow {
                        ForEach(0..<cs, id: \.self) { col in
                            let i = r * cs + col
                            pad(i, p[i], s)
                        }
                    }
                }
            }
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
            BluetoothHint()
            if c.flag("record") { recorder(s) } else { TakeControl(c: c, bpm: Double(bpm)) }
        }
        .modifier(SoundHold())
        .sensoryFeedback(.impact(weight: .light), trigger: tapped)
        .onDisappear { if phase == .recording { finish() } }
    }

    private func pad(_ i: Int, _ word: String, _ s: Swatch) -> some View {
        let color = rowColor(i, s)
        let hot = (lit[i] ?? 0) > 0
        return RoundedRectangle(cornerRadius: theme.radius.card * 0.8)
            .fill(hot ? color : color.opacity(0.28))
            .overlay(RoundedRectangle(cornerRadius: theme.radius.card * 0.8).stroke(s.outline, lineWidth: 1.5))
            .overlay(alignment: .bottomLeading) {
                Text(word)
                    .font(theme.font(grid.cols >= 4 ? theme.type.caption : theme.type.body, .heavy))
                    .foregroundStyle(hot ? s.onAccent : s.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(grid.cols >= 4 ? theme.spacing.s : theme.spacing.m)
            }
            .scaleEffect(hot ? 0.96 : 1)
            .animation(.easeOut(duration: 0.08), value: hot)
            .aspectRatio(grid.cols <= 2 ? 1 : 0.95, contentMode: .fit)
            .contentShape(Rectangle())
            // Touch down plays, not the lift: a tap gesture waits for the finger to leave.
            .modifier(TouchDown { hit(i, word) })
            .accessibilityElement()
            .accessibilityLabel("\(word) pad")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { hit(i, word) }
            .accessibilityIdentifier("drum-pad-\(i)")
    }

    private func hit(_ i: Int, _ word: String) {
        YuiSound.shared.play(word, velocity: 1)
        tapped += 1
        lit[i, default: 0] += 1
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            lit[i] = max(0, (lit[i] ?? 1) - 1)
        }
        guard phase == .recording, let start = YuiSound.shared.loopStartTime else { return }
        // Seconds from the first recorded downbeat: after one bar of count-in.
        let t = YuiSound.shared.audibleTime - start - 16 * sixteenth
        if t > -sixteenth / 2 { hits.append((word, t)) }
    }

    @ViewBuilder private func recorder(_ s: Swatch) -> some View {
        TimelineView(.animation(paused: phase != .recording)) { _ in
            let step = phase == .recording ? recordStep : nil
            VStack(alignment: .leading, spacing: theme.spacing.s) {
                if let step {
                    ProgressView(value: step < 16 ? Double(step) / 16 : Double(step - 16) / 32)
                        .tint(step < 16 ? s.inkSoft : s.accent)
                    Text(step < 16 ? "Count in \(step / 4 + 1)" : "Recording, bar \(step < 32 ? 1 : 2) of 2")
                        .font(theme.font(theme.type.body, .bold))
                        .foregroundStyle(step < 16 ? s.ink : s.accent)
                        .accessibilityIdentifier("drums-status")
                        .onChange(of: step >= 48) { _, over in if over { finish() } }
                } else if phase == .done || phase == .empty || phase == .sending {
                    Text(phase == .done ? "Take sent." : phase == .sending ? "Sending the take" : "No hits. Try again.")
                        .font(theme.font(theme.type.body, .bold))
                        .foregroundStyle(s.inkSoft)
                        .accessibilityIdentifier("drums-status")
                }
            }
        }
        OptionPill(text: phase == .recording ? "Recording" : phase == .done ? "Record again" : "Record",
                   fill: s.accent, ink: s.onAccent, dim: phase == .recording, grow: true, icon: "record.circle") { record() }
            .disabled(phase == .recording || phase == .sending || c.locked || (host.takeOwner != nil && host.takeOwner != c.serial))
            .accessibilityIdentifier("drums-record")
    }

    /// Steps since the count-in began: 0-15 count in, 16-47 recording.
    private var recordStep: Int {
        guard let start = YuiSound.shared.loopStartTime else { return 0 }
        return max(0, Int((YuiSound.shared.audibleTime - start) / sixteenth))
    }

    /// The count-in and the click come from the looper: a tick on every beat.
    private func record() {
        hits = []
        if host.loopOwner != nil { YuiSound.shared.stopLoop() }
        host.loopOwner = c.serial
        let beats = (0..<16).map { $0 % 4 == 0 }
        YuiSound.shared.setLoop(rows: ["tick"], sound: "pluck", steps: 16, bpm: Double(bpm), swing: 0, pattern: [beats])
        YuiSound.shared.startLoop()
        // The sound of the take too (step 5), from the count-in on; the file starts at the first bar.
        if host.takeOwner == nil, (try? YuiSound.shared.startTake()) != nil { host.takeOwner = c.serial }
        phase = .recording
    }

    private func finish() {
        guard phase == .recording else { return }
        if host.loopOwner == c.serial {
            YuiSound.shared.stopLoop()
            host.loopOwner = nil
        }
        let sound = host.takeOwner == c.serial ? YuiSound.shared.stopTake(bpm: Double(bpm)) : nil
        if host.takeOwner == c.serial { host.takeOwner = nil }
        let take = LoopPattern.take(hits, pads: pads, bpm: bpm)
        guard !take.rows.isEmpty else {
            if let sound { try? FileManager.default.removeItem(at: sound.audio); try? FileManager.default.removeItem(at: sound.midi) }
            phase = .empty
            return
        }
        var fields: [String: YLValue] = [
            "take": .bool(true), "bpm": .number(Double(bpm)), "steps": .number(32),
            "rows": .array(take.rows.map(YLValue.string)), "p": .array(take.p.map(YLValue.string)),
        ]
        phase = .sending
        Task { @MainActor in
            // The recording rides along when it can; the pattern goes either way.
            if let sound, let audio = try? await TakeUpload.fields(sound, media: media) {
                fields.merge(audio) { a, _ in a }
            }
            phase = .done
            emit(c.event(fields, echo: "Sent a take, \(bpm) BPM"))
        }
    }
}

/// Fires once when a finger lands, not when it lifts.
struct TouchDown: ViewModifier {
    let action: () -> Void
    @State private var down = false

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !down else { return }
                    down = true
                    action()
                }
                .onEnded { _ in down = false }
        )
    }
}
