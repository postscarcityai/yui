import SwiftUI
import YuiLines
import YuiSound

// Music presets, step 4 (YUI-116, yuigui spec/MUSIC.md sections 2 and 6):
// `tuner` listens through the mic and lights the nearest string; `metronome`
// clicks on the engine's clock beside the looper.

extension YLComponent {
    fileprivate var toolTitle: String? { string("title").flatMap { $0.isEmpty ? nil : $0 } }

    fileprivate func whole(_ key: String, _ range: ClosedRange<Int>, _ d: Int) -> Int {
        guard let n = number(key), n.isFinite else { return d }
        return min(range.upperBound, max(range.lowerBound, Int(n.rounded())))
    }
}

/// The needle's green, the same in every theme: "in tune" should read the same everywhere.
private let inTuneGreen = Color(red: 0.16, green: 0.70, blue: 0.42)

// MARK: - tuner

/// `tuner [INSTRUMENT] [title]`: Start asks for the mic once, then the needle
/// shows how far the nearest string is, -50 to +50 cents, green within 3.
/// Each string is a button that plays its note. When every string has held
/// in tune for a second, one tuned event goes back (not for chromatic).
struct TunerPreset: View {
    let c: YLComponent
    @State private var listener = PitchListener()
    @State private var phase = PitchListener.State.idle
    @State private var read: Read?
    @State private var misses = 0
    @State private var recent: [Double] = []
    @State private var tracker = TunedTracker(strings: 0)
    @State private var tunedNow = 0
    @Environment(\.ylEmit) private var emit
    @Environment(\.ylOnStage) private var onStage
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    struct Read: Equatable {
        var index: Int
        var note: String
        var cents: Double
        var hz: Double
    }

    private var tuning: Tuning {
        Tuning(instrument: c.string("instrument"), tuning: c.string("tuning"), strings: c.strings("strings") ?? [], a4: c.number("a4"))
    }
    /// What a patch can change: the strings start over.
    private var tuningKey: [YLValue?] { [c.props["instrument"], c.props["tuning"], c.props["strings"], c.props["a4"]] }

    var body: some View {
        let s = theme.swatch(scheme)
        let t = tuning
        PresetCard {
            MusicHead(title: c.toolTitle ?? "Tuner", sub: subline(t))
            if t.fellBack, let asked = c.string("tuning") {
                note("No tuning called \(asked), so this is standard.", s.inkSoft)
            }
            dial(s)
                .frame(height: onStage ? 210 : 150)
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity)
            readout(s)
            if t.strings.isEmpty {
                stringButton(-1, "A4", midi: 69, t, s)
            } else {
                HStack(spacing: 8) {
                    ForEach(t.strings.indices, id: \.self) { i in
                        stringButton(i, t.strings[i], midi: t.midis[i], t, s)
                    }
                }
            }
            if phase == .denied {
                note("The mic is off. Tap a string to tune by ear.", s.inkSoft)
                    .accessibilityIdentifier("tuner-denied")
            } else if !t.chromatic, t.midis.indices.allSatisfy(tracker.isTuned), !t.midis.isEmpty {
                note("All strings in tune.", inTuneGreen)
                    .accessibilityIdentifier("tuner-done")
            }
            OptionPill(text: pillText, fill: s.accent, ink: s.onAccent, dim: phase == .asking, grow: true,
                       icon: phase == .on ? "stop.fill" : "mic.fill") {
                phase == .on ? stop() : start()
            }
            .disabled(phase == .asking || c.locked)
            .accessibilityIdentifier("tuner-start")
        }
        .modifier(SoundHold())
        .sensoryFeedback(.success, trigger: tunedNow)
        .onChange(of: tuningKey, initial: true) { restart() }
        .onChange(of: scenePhase) { _, now in if now != .active, phase == .on { stop() } }
        .onDisappear { stop() }
    }

    private var pillText: String {
        switch phase {
        case .on: "Stop listening"
        case .asking: "Asking for the mic"
        case .denied: "Try the mic again"
        case .idle: "Start"
        }
    }

    private func subline(_ t: Tuning) -> String {
        let name = t.custom ? "custom" : t.chromatic ? "chromatic" : "\(t.instrument), \(t.tuning == "dropd" ? "drop D" : t.tuning == "lowg" ? "low G" : t.tuning)"
        return t.a4 != 440 ? "\(name) · A4 \(Int(t.a4))" : name
    }

    private func note(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(theme.font(theme.type.body, .bold))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The arc from -50 to +50 cents, a green band within 3, the needle.
    private func dial(_ s: Swatch) -> some View {
        let cents = read.map { max(-50, min(50, $0.cents)) } ?? 0
        let good = read.map { abs($0.cents) <= Tuning.inTune } ?? false
        return GeometryReader { geo in
            let r = min(geo.size.width / 2, geo.size.height) - 8
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height - 4)
            ZStack {
                Canvas { ctx, _ in
                    func angle(_ c: Double) -> Angle { .degrees(c / 50 * 60 - 90) }
                    var arc = Path()
                    arc.addArc(center: center, radius: r, startAngle: angle(-50), endAngle: angle(50), clockwise: false)
                    ctx.stroke(arc, with: .color(s.outline), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    var band = Path()
                    band.addArc(center: center, radius: r, startAngle: angle(-Tuning.inTune), endAngle: angle(Tuning.inTune), clockwise: false)
                    ctx.stroke(band, with: .color(inTuneGreen), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    for c in stride(from: -50.0, through: 50, by: 10) {
                        let a = angle(c).radians
                        let long = c.truncatingRemainder(dividingBy: 25) == 0
                        var tick = Path()
                        tick.move(to: CGPoint(x: center.x + (r - (long ? 22 : 16)) * cos(a), y: center.y + (r - (long ? 22 : 16)) * sin(a)))
                        tick.addLine(to: CGPoint(x: center.x + (r - 10) * cos(a), y: center.y + (r - 10) * sin(a)))
                        ctx.stroke(tick, with: .color(s.inkSoft.opacity(long ? 0.9 : 0.5)), lineWidth: long ? 2.5 : 1.5)
                    }
                }
                Capsule()
                    .fill(good ? inTuneGreen : s.ink)
                    .frame(width: 5, height: r - 18)
                    .offset(y: -(r - 18) / 2)
                    .rotationEffect(.degrees(cents / 50 * 60), anchor: .center)
                    .position(center)
                    .opacity(read == nil ? 0.25 : 1)
                    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: cents)
                Circle().fill(good ? inTuneGreen : s.ink).frame(width: 14, height: 14).position(center)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Tuner needle")
        .accessibilityValue(read.map { "\($0.note), \(signed($0.cents)) cents\(abs($0.cents) <= Tuning.inTune ? ", in tune" : "")" } ?? "nothing heard")
        .accessibilityIdentifier("tuner-needle")
    }

    private func signed(_ c: Double) -> String {
        let n = Int(c.rounded())
        return n > 0 ? "+\(n)" : "\(n)"
    }

    private func readout(_ s: Swatch) -> some View {
        let good = read.map { abs($0.cents) <= Tuning.inTune } ?? false
        return VStack(spacing: 2) {
            if let read {
                let letter = read.note.prefix { !$0.isNumber && $0 != "-" }
                let octave = read.note.dropFirst(letter.count)
                HStack(alignment: .lastTextBaseline, spacing: 1) {
                    Text(letter).font(theme.font(onStage ? 64 : 48, .heavy))
                    Text(octave).font(theme.font(theme.type.body, .bold)).foregroundStyle(s.inkSoft)
                }
                .foregroundStyle(good ? inTuneGreen : s.ink)
                Text("\(signed(read.cents)) \(abs(Int(read.cents.rounded())) == 1 ? "cent" : "cents") · \(String(format: "%.1f", read.hz)) Hz")
                    .font(theme.font(theme.type.body, .bold))
                    .foregroundStyle(s.inkSoft)
                    .monospacedDigit()
            } else {
                Text("–").font(theme.font(onStage ? 64 : 48, .heavy)).foregroundStyle(s.outline)
                Text(phase == .on ? "Play a string" : "Tap Start, then play a string.")
                    .font(theme.font(theme.type.body, .bold))
                    .foregroundStyle(s.inkSoft)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tuner-read")
    }

    private func stringButton(_ i: Int, _ name: String, midi: Int, _ t: Tuning, _ s: Swatch) -> some View {
        let near = read?.index == i && i >= 0
        let done = i >= 0 && tracker.isTuned(i)
        return Button { YuiSound.shared.tone(midi, a4: t.a4) } label: {
            VStack(spacing: 2) {
                Text(i < 0 ? "Hear A4" : name)
                    .font(theme.font(theme.type.body, .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Image(systemName: done ? "checkmark" : "speaker.wave.1.fill")
                    .font(.system(size: 11, weight: .bold))
                    .opacity(done ? 1 : 0.5)
            }
            .foregroundStyle(near ? s.onAccent : done ? inTuneGreen : s.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, theme.spacing.s)
            .background(near ? s.accent : s.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(done ? inTuneGreen : s.outline, lineWidth: done ? 2 : 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(i < 0 ? "Hear A4" : "Hear \(name)")
        .accessibilityValue(done ? "in tune" : near ? "sounding" : "")
        .accessibilityIdentifier("tuner-string-\(max(i, 0))")
    }

    // MARK: Listening

    private func restart() {
        let wasOn = phase == .on
        if wasOn { stop() }
        tracker = TunedTracker(strings: tuning.midis.count)
        read = nil
        recent = []
        if wasOn { start() }
    }

    private func start() {
        let t = tuning
        listener.onReading = { heard($0) }
        #if DEBUG
        // -yuiTunerFake "1.3": UI tests and demo shots play each string in turn
        // this many seconds, a little off, instead of the mic.
        let fake = UserDefaults.standard.double(forKey: "yuiTunerFake")
        if fake > 0 {
            let offsets = [-2.0, 1.4, 0.6, 2.2, -1.2, 0.8]
            let steps = t.midis.isEmpty ? [(hz: 440 * pow(2, 12.0 / 1200), seconds: fake)]
                : t.midis.indices.map { i in (hz: t.hz(i) * pow(2, offsets[i % 6] / 1200), seconds: fake) }
            listener.startFake(steps, tuning: t)
            phase = .on
            return
        }
        #endif
        phase = .asking
        Task { phase = await listener.start(t) }
    }

    private func stop() {
        listener.stop()
        if phase != .denied { phase = .idle }
        read = nil
        tracker.silence()
    }

    private func heard(_ r: Pitch.Reading?) {
        let t = tuning
        guard let r else {
            tracker.silence()
            misses += 1
            // A decaying string drops out for a moment: hold the needle 0.3 s.
            if misses > 9 { read = nil; recent = [] }
            return
        }
        misses = 0
        let n = t.nearest(r.hz)
        if n.index != read?.index || n.note != read?.note { recent = [] }
        recent = Array((recent + [n.cents]).suffix(5))
        // The needle shows the median of the last few readings, so it does not jitter.
        let shown = recent.sorted()[recent.count / 2]
        read = Read(index: n.index, note: n.note, cents: shown, hz: r.hz)
        guard !t.chromatic, n.index >= 0 else { return }
        let before = t.midis.indices.filter(tracker.isTuned).count
        let all = tracker.feed(index: n.index, cents: n.cents, time: Date.timeIntervalSinceReferenceDate)
        if t.midis.indices.filter(tracker.isTuned).count > before { tunedNow += 1 }
        if all { send(t) }
    }

    private func send(_ t: Tuning) {
        let cents = t.midis.indices.map { Int((tracker.cents[$0] ?? 0).rounded()) }
        emit(c.event([
            "tuned": .bool(true), "instrument": .string(t.instrument), "tuning": .string(t.tuning),
            "strings": .array(t.strings.map(YLValue.string)), "cents": .array(cents.map { .number(Double($0)) }),
        ], echo: "My \(t.instrument) is in tune"))
    }
}

// MARK: - metronome

/// `metronome [BPM] [title]`: a big tempo, minus and plus, Tap tempo, a dot
/// per beat with the first accented, clicks per beat, Start and Stop. Stop
/// after at least 10 s sends the practice. It keeps time with a playing loop
/// and keeps going with the phone locked.
struct MetronomePreset: View {
    let c: YLComponent
    @State private var bpm = 100
    @State private var sub = 1
    @State private var taps = TapTempo()
    @State private var startedAt: Date?
    @State private var said: String?
    @State private var tapped = 0
    private var host: MusicHost { .shared }
    @Environment(\.ylEmit) private var emit
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private var beats: Int { c.whole("beats", 1...12, 4) }
    private var playing: Bool { host.metroOwner == c.serial }
    private static let subNames = ["", "Beats", "Eighths", "Triplets", "Sixteenths"]

    var body: some View {
        let s = theme.swatch(scheme)
        PresetCard {
            MusicHead(title: c.toolTitle ?? "Metronome", sub: sub > 1 ? "\(beats)/4 · \(Self.subNames[sub].lowercased())" : "\(beats)/4")
            HStack(spacing: theme.spacing.m) {
                MusicButton(text: "−") { bpm = max(30, bpm - 1) }
                    .accessibilityLabel("Slower")
                    .accessibilityIdentifier("metronome-slower")
                VStack(spacing: 0) {
                    Text("\(bpm)")
                        .font(theme.font(56, .heavy))
                        .foregroundStyle(s.ink)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: bpm)
                    Text("BPM")
                        .font(theme.font(theme.type.caption, .bold))
                        .foregroundStyle(s.inkSoft)
                }
                .frame(minWidth: 110)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(bpm) beats per minute")
                .accessibilityIdentifier("metronome-bpm")
                MusicButton(text: "+") { bpm = min(300, bpm + 1) }
                    .accessibilityLabel("Faster")
                    .accessibilityIdentifier("metronome-faster")
            }
            .frame(maxWidth: .infinity)
            TimelineView(.animation(paused: !playing)) { _ in
                let tick = playing ? YuiSound.shared.audibleTick : nil
                let beat = tick.map { $0 / max(sub, 1) }
                HStack(spacing: 10) {
                    ForEach(0..<beats, id: \.self) { i in
                        Circle()
                            .fill(beat == i ? (i == 0 ? s.accent : s.ink) : s.outline.opacity(0.5))
                            .overlay(Circle().stroke(i == 0 ? s.accent : .clear, lineWidth: 2))
                            .frame(width: i == 0 ? 18 : 14, height: i == 0 ? 18 : 14)
                            .scaleEffect(beat == i ? 1.25 : 1)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .accessibilityHidden(true)
            }
            ViewThatFits(in: .horizontal) {
                controls(compact: false)
                controls(compact: true)
            }
            BluetoothHint()
            if let said {
                Text(said)
                    .font(theme.font(theme.type.body, .bold))
                    .foregroundStyle(s.inkSoft)
                    .accessibilityIdentifier("metronome-said")
            }
        }
        .modifier(SoundHold())
        .sensoryFeedback(.selection, trigger: tapped)
        .onChange(of: c.props["bpm"], initial: true) { bpm = c.whole("bpm", 30...300, 100) }
        .onChange(of: c.props["sub"], initial: true) { sub = c.whole("sub", 1...4, 1) }
        .onChange(of: bpm) { sync() }
        .onChange(of: sub) { sync() }
        .onChange(of: c.props["beats"]) { sync() }
        .onAppear { if c.flag("play") && host.metroOwner == nil { start() } }
        .onDisappear { if playing { stop() } }
    }

    private func controls(compact: Bool) -> some View {
        HStack(spacing: theme.spacing.s) {
            MusicButton(text: compact ? "" : playing ? "Stop" : "Start", icon: playing ? "stop.fill" : "play.fill", on: playing) {
                playing ? stop() : start()
            }
            .accessibilityLabel(playing ? "Stop" : "Start")
            .accessibilityIdentifier("metronome-play")
            MusicButton(text: compact ? "Tap" : "Tap tempo") { tap() }
                .accessibilityLabel("Tap tempo")
                .accessibilityIdentifier("metronome-tap")
            Spacer(minLength: 0)
            MusicButton(text: Self.subNames[sub]) { sub = sub % 4 + 1 }
                .accessibilityLabel("Clicks per beat: \(Self.subNames[sub])")
                .accessibilityIdentifier("metronome-sub")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func sync() {
        guard playing else { return }
        YuiSound.shared.setMetronome(bpm: bpm, beats: beats, sub: sub)
    }

    private func start() {
        if let other = host.metroOwner, other != c.serial { YuiSound.shared.stopMetronome() }
        host.metroOwner = c.serial
        YuiSound.shared.setMetronome(bpm: bpm, beats: beats, sub: sub)
        YuiSound.shared.startMetronome()
        startedAt = Date()
        said = nil
    }

    private func stop() {
        guard playing else { return }
        YuiSound.shared.stopMetronome()
        host.metroOwner = nil
        let seconds = Int(Date().timeIntervalSince(startedAt ?? Date()).rounded())
        startedAt = nil
        guard seconds >= 10 else { return }
        let time = seconds >= 60 ? "\(seconds / 60) min \(seconds % 60) s" : "\(seconds) s"
        said = "Practice sent: \(time) at \(bpm) BPM."
        emit(c.event([
            "bpm": .number(Double(bpm)), "beats": .number(Double(beats)), "sub": .number(Double(sub)),
            "seconds": .number(Double(seconds)),
        ], echo: "Practiced \(time) at \(bpm) BPM"))
    }

    private func tap() {
        tapped += 1
        if let b = taps.tap(Date.timeIntervalSinceReferenceDate) { bpm = b }
        if !playing { YuiSound.shared.play("tick", velocity: 0.6) }
    }
}
