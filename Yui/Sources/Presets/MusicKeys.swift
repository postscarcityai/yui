import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import YuiLines
import YuiSound

// `keys` and `chords` (YUI-116 step 3, yuigui spec/MUSIC.md section 2): an easy
// keyboard with the scale lock, octave arrows, more than one finger and glide,
// and one big button per chord that strums on touch down. Both play through
// YuiSound, so they sound like the looper and the pads.

extension YLComponent {
    fileprivate var musicTitle: String? { string("title").flatMap { $0.isEmpty ? nil : $0 } }
}

/// The last 32 things played, oldest first.
private func last32(_ list: [String], _ item: String) -> [String] { Array((list + [item]).suffix(32)) }

/// The six pitched voices as chips (keys, pluck, bell, pad, bass, lead).
private struct SoundPicker: View {
    @Binding var sound: String
    let preview: (String) -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: theme.spacing.xs) {
                ForEach(YuiSound.pitched, id: \.self) { word in
                    let on = word == sound
                    Button {
                        sound = word
                        preview(word)
                    } label: {
                        Text(word)
                            .font(theme.font(theme.type.caption, .bold))
                            .foregroundStyle(on ? s.onAccent : s.ink)
                            .padding(.horizontal, theme.spacing.m)
                            .padding(.vertical, theme.spacing.xs + 2)
                            .background(on ? s.accent : s.background, in: Capsule())
                            .overlay(Capsule().stroke(on ? .clear : s.outline, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(word) sound")
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityIdentifier("music-sound-\(word)")
                }
            }
        }
        .scrollClipDisabled()
    }
}

// MARK: - keyboard layout

/// Ten white keys (C to the E above) and seven black ones, as fractions of the
/// keyboard's size. Pure, so the hit test is testable.
enum KeyboardLayout {
    static let white = [0, 2, 4, 5, 7, 9, 11, 12, 14, 16]
    /// A black key's semitone and the white key it sits left of.
    static let black: [(semitone: Int, white: Int)] = [(1, 1), (3, 2), (6, 4), (8, 5), (10, 6), (13, 8), (15, 9)]
    static let blackWidth = 0.064
    static let blackHeight = 0.6

    static func whiteRect(_ i: Int, in size: CGSize) -> CGRect {
        let w = size.width / CGFloat(white.count)
        return CGRect(x: CGFloat(i) * w, y: 0, width: w, height: size.height)
    }

    static func blackRect(_ at: Int, in size: CGSize) -> CGRect {
        let w = size.width * blackWidth
        let x = size.width * CGFloat(at) / CGFloat(white.count) - w / 2
        return CGRect(x: x, y: 0, width: w, height: size.height * blackHeight)
    }

    /// The semitone above the keyboard's C under a point, or nil off the keys.
    /// Black keys sit on top, so they win where they overlap.
    static func semitone(at p: CGPoint, in size: CGSize) -> Int? {
        guard p.x >= 0, p.y >= 0, p.x < size.width, p.y < size.height, size.width > 0 else { return nil }
        for b in black where blackRect(b.white, in: size).contains(p) { return b.semitone }
        let i = min(white.count - 1, Int(p.x / (size.width / CGFloat(white.count))))
        return white[i]
    }
}

// MARK: - touches

/// Every finger on the keyboard, reported the moment it lands, moves or lifts.
/// A gesture recognizer, not a view's own touch handling, so a scroll view
/// around it cannot hold the touch back; once a finger is down it owns the
/// touch, so the stage does not scroll or close under a glide.
final class KeyTouches: UIGestureRecognizer {
    /// (finger, where it is now, or nil when it lifted)
    var report: ((ObjectIdentifier, CGPoint?) -> Void)?
    private var live = Set<ObjectIdentifier>()

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for t in touches {
            live.insert(ObjectIdentifier(t))
            report?(ObjectIdentifier(t), t.location(in: view))
        }
        state = state == .possible ? .began : .changed
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        for t in touches { report?(ObjectIdentifier(t), t.location(in: view)) }
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches, cancelled: true) }

    private func lift(_ touches: Set<UITouch>, cancelled: Bool) {
        for t in touches {
            live.remove(ObjectIdentifier(t))
            report?(ObjectIdentifier(t), nil)
        }
        if live.isEmpty { state = cancelled ? .cancelled : .ended } else { state = .changed }
    }

    override func reset() {
        for id in live { report?(id, nil) }
        live = []
    }

    override func canPrevent(_ other: UIGestureRecognizer) -> Bool { true }
    override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
}

/// A clear view over the keys that hands every finger to `report`.
private struct TouchSurface: UIViewRepresentable {
    let report: (ObjectIdentifier, CGPoint?) -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isMultipleTouchEnabled = true
        v.isAccessibilityElement = false
        let g = KeyTouches(target: nil, action: nil)
        g.report = report
        v.addGestureRecognizer(g)
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {
        (v.gestureRecognizers?.first as? KeyTouches)?.report = report
    }
}

/// Fires once per finger the moment it lands, through the same recognizer
/// as the keyboard: a quick tap never slips past it.
private struct FingerDown: View {
    let action: () -> Void
    @State private var down = Set<ObjectIdentifier>()

    var body: some View {
        TouchSurface { id, p in
            if p == nil { down.remove(id) } else if down.insert(id).inserted { action() }
        }
    }
}

// MARK: - keys

/// `keys [KEY] [SCALE] [title]`: one octave and a bit, octave arrows, the scale
/// lock (keys outside the scale are dimmed and silent), a sound picker. Each
/// finger plays its own note; sliding plays every key it crosses.
struct KeysPreset: View {
    let c: YLComponent
    @State private var octave = 4
    @State private var sound = "keys"
    /// Each finger's note and the engine tag that lets it go.
    @State private var fingers: [ObjectIdentifier: (midi: Int, tag: UInt32)] = [:]
    @State private var played: [String] = []
    @State private var sent = false
    /// MIDI notes already taken (MIDIKeyboard.hits when we last looked).
    @State private var midiSeen = 0
    @Environment(\.ylEmit) private var emit
    @Environment(\.ylScope) private var scope
    @Environment(\.ylAnswers) private var answers
    @Environment(\.ylOnStage) private var onStage
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private var key: Theory.Key { Theory.Key(c.string("key")) }
    private var scale: String {
        let s = c.string("scale")?.lowercased() ?? ""
        return Theory.scales.contains(s) ? s : (key.minor ? "minor" : "major")
    }
    private var base: Int { 12 * (octave + 1) }
    private func playable(_ m: Int) -> Bool { !c.locked && Theory.inScale(m, key: key, scale: scale) }
    private var down: Set<Int> { Set(fingers.values.map(\.midi)).union(MIDIKeyboard.shared.held) }

    var body: some View {
        let s = theme.swatch(scheme)
        PresetCard {
            MusicHead(title: c.musicTitle ?? "Keys", sub: "\(key.name) \(scale)")
            SoundPicker(sound: $sound) { word in
                YuiSound.shared.strum([base + key.root], sound: word, direction: .off, hold: 0.4)
            }
            keyboard(s)
                .frame(height: onStage ? 230 : 170)
            HStack(spacing: theme.spacing.s) {
                MusicButton(text: "", icon: "chevron.left") { octave = max(1, octave - 1) }
                    .disabled(octave <= 1)
                    .accessibilityLabel("Octave down")
                    .accessibilityIdentifier("keys-octave-down")
                Text("C\(octave)")
                    .font(theme.font(theme.type.body, .heavy))
                    .foregroundStyle(s.ink)
                    .monospacedDigit()
                    .accessibilityIdentifier("keys-octave")
                MusicButton(text: "", icon: "chevron.right") { octave = min(7, octave + 1) }
                    .disabled(octave >= 7)
                    .accessibilityLabel("Octave up")
                    .accessibilityIdentifier("keys-octave-up")
                MIDIButton()
                Spacer(minLength: 0)
                Text(played.suffix(6).joined(separator: " "))
                    .font(theme.font(theme.type.caption, .bold))
                    .foregroundStyle(s.inkSoft)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .accessibilityIdentifier("keys-played")
            }
            BluetoothHint()
            TakeControl(c: c)
            if c.flag("send") {
                OptionPill(text: sent ? "Sent" : "Send", fill: s.accent, ink: s.onAccent, check: sent, grow: true) { send() }
                    .disabled(played.isEmpty || c.locked)
                    .accessibilityIdentifier("keys-send")
            }
        }
        .modifier(SoundHold())
        .onChange(of: c.props["octave"], initial: true) {
            if let n = c.number("octave"), n.isFinite { octave = min(7, max(1, Int(n.rounded()))) }
        }
        .onChange(of: c.props["sound"], initial: true) { sound = soundWord(c.string("sound"), fallback: "keys") }
        .onChange(of: answers(scope, c.ylID), initial: true) { _, v in
            guard played.isEmpty, let p = v?["played"]?.array?.compactMap(\.string), !p.isEmpty else { return }
            played = p
            sent = true
        }
        .onAppear {
            MIDIKeyboard.shared.attach(sound: sound)
            midiSeen = MIDIKeyboard.shared.hits
        }
        .onChange(of: sound) { MIDIKeyboard.shared.use(sound: sound) }
        .onChange(of: MIDIKeyboard.shared.hits) { midiNote() }
        .onDisappear {
            letGoAll()
            MIDIKeyboard.shared.detach()
        }
    }

    /// A note from a MIDI keyboard: counted as played, and the keys follow it
    /// to its octave so it lights. Every note plays; the lock is for fingers.
    private func midiNote() {
        let midi = MIDIKeyboard.shared
        let fresh = midi.notes.suffix(min(midi.notes.count, max(0, midi.hits - midiSeen)))
        midiSeen = midi.hits
        guard let last = fresh.last else { return }
        for m in fresh { played = last32(played, Theory.name(m, flats: key.flats)) }
        if last < base || last > base + 16 { octave = min(7, max(1, last / 12 - 1)) }
        sent = false
    }

    private func keyboard(_ s: Swatch) -> some View {
        GeometryReader { geo in
            let sz = geo.size
            ZStack(alignment: .topLeading) {
                ForEach(KeyboardLayout.white.indices, id: \.self) { i in
                    let m = base + KeyboardLayout.white[i]
                    whiteKey(m, s)
                        .frame(width: KeyboardLayout.whiteRect(i, in: sz).width - 3, height: sz.height)
                        .offset(x: KeyboardLayout.whiteRect(i, in: sz).minX + 1.5)
                }
                ForEach(KeyboardLayout.black.indices, id: \.self) { j in
                    let b = KeyboardLayout.black[j]
                    let r = KeyboardLayout.blackRect(b.white, in: sz)
                    blackKey(base + b.semitone, s)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX)
                }
                TouchSurface { id, p in touch(id, p.flatMap { KeyboardLayout.semitone(at: $0, in: sz) }) }
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard, \(key.name) \(scale)")
    }

    private func whiteKey(_ m: Int, _ s: Swatch) -> some View {
        let ok = playable(m)
        let on = down.contains(m)
        let root = (m - key.root) % 12 == 0
        return RoundedRectangle(cornerRadius: 10)
            .fill(on ? s.accent : ok ? ivory(s) : ivory(s).opacity(0.35))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(s.outline, lineWidth: 1.5))
            .overlay(alignment: .bottom) {
                VStack(spacing: 4) {
                    if root { Circle().fill(on ? s.onAccent : s.accent).frame(width: 7, height: 7) }
                    if m % 12 == 0 {
                        Text(Theory.name(m))
                            .font(theme.font(theme.type.caption, .bold))
                            .foregroundStyle(on ? s.onAccent : ebony(s).opacity(0.6))
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                    }
                }
                .padding(.bottom, 8)
            }
            .keyAccessibility(Theory.name(m, flats: key.flats), ok: ok, on: on) { tapKey(m) }
            .accessibilityIdentifier("key-\(m)")
    }

    private func blackKey(_ m: Int, _ s: Swatch) -> some View {
        let ok = playable(m)
        let on = down.contains(m)
        let root = (m - key.root) % 12 == 0
        return UnevenRoundedRectangle(bottomLeadingRadius: 7, bottomTrailingRadius: 7)
            .fill(on ? s.accent : ok ? ebony(s) : ebony(s).opacity(0.3))
            .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 7, bottomTrailingRadius: 7).stroke(s.outline, lineWidth: ok ? 0 : 1))
            .overlay(alignment: .bottom) {
                if root { Circle().fill(on ? s.onAccent : s.accent).frame(width: 6, height: 6).padding(.bottom, 8) }
            }
            .keyAccessibility(Theory.name(m, flats: key.flats), ok: ok, on: on) { tapKey(m) }
            .accessibilityIdentifier("key-\(m)")
    }

    // A keyboard reads as a piano in both modes: light naturals, dark sharps.
    private func ivory(_ s: Swatch) -> Color { scheme == .dark ? s.ink : s.background }
    private func ebony(_ s: Swatch) -> Color { scheme == .dark ? s.background : s.ink }

    /// A finger landed, moved or lifted (semitone nil). Moving onto a new key
    /// lets the old one go and plays the new one; a dimmed key stays silent.
    private func touch(_ id: ObjectIdentifier, _ semitone: Int?) {
        let m = semitone.map { base + $0 }
        let old = fingers[id]
        if let old, old.midi == m { return }
        if let old {
            YuiSound.shared.noteOff(old.tag)
            fingers[id] = nil
        }
        guard let m, playable(m) else { return }
        let tag = YuiSound.shared.noteOn(m, sound: sound)
        fingers[id] = (m, tag)
        played = last32(played, Theory.name(m, flats: key.flats))
        sent = false
    }

    /// VoiceOver and UI tests: a short note.
    private func tapKey(_ m: Int) {
        guard playable(m) else { return }
        YuiSound.shared.strum([m], sound: sound, direction: .off, hold: 0.4)
        played = last32(played, Theory.name(m, flats: key.flats))
        sent = false
    }

    private func letGoAll() {
        for f in fingers.values { YuiSound.shared.noteOff(f.tag) }
        fingers = [:]
    }

    private func send() {
        emit(c.event([
            "played": .array(played.map(YLValue.string)), "key": .string(key.name), "scale": .string(scale),
        ], echo: "Sent what I played"))
        sent = true
    }
}

extension View {
    /// A key as VoiceOver reads it: its note, dimmed when the scale lock holds it.
    fileprivate func keyAccessibility(_ name: String, ok: Bool, on: Bool, action: @escaping () -> Void) -> some View {
        accessibilityElement()
            .accessibilityLabel(name)
            .accessibilityValue(ok ? (on ? "down" : "") : "locked")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

/// A sound word the pickers know, or the fallback (MUSIC.md section 4: an
/// unknown word plays the family default, aliases like piano mean keys).
private func soundWord(_ word: String?, fallback: String) -> String {
    guard let w = word?.lowercased().filter({ !" _-".contains($0) }), !w.isEmpty else { return fallback }
    if YuiSound.pitched.contains(w) { return w }
    let alias = ["piano": "keys", "ep": "keys", "organ": "keys", "rhodes": "keys", "guitar": "pluck", "harp": "pluck",
                 "synth": "lead", "saw": "lead", "strings": "pad", "choir": "pad", "sub": "bass", "808": "bass",
                 "chime": "bell", "glock": "bell", "marimba": "bell"]
    return alias[w] ?? "keys"
}

// MARK: - chords

/// `chords [KEY] [PROGRESSION or CHORDS] [title]`: one big button per chord,
/// the name large and the numeral small under it. Touch down strums it: down
/// (low to high), up, or off (all at once), 25 ms between strings.
struct ChordsPreset: View {
    let c: YLComponent
    @State private var strum = YuiSound.Strum.down
    @State private var sound = "pluck"
    @State private var played: [String] = []
    @State private var lit: [Int: Int] = [:]
    @State private var sent = false
    @State private var tapped = 0
    @Environment(\.ylEmit) private var emit
    @Environment(\.ylScope) private var scope
    @Environment(\.ylAnswers) private var answers
    @Environment(\.ylOnStage) private var onStage
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private var key: Theory.Key { Theory.Key(c.string("key")) }
    private var list: [Theory.Chord] {
        Theory.progression(key: key, prog: c.strings("prog") ?? [], chords: c.strings("chords") ?? [])
    }

    var body: some View {
        let s = theme.swatch(scheme)
        let chords = list
        let named = chords.contains { !$0.numeral.isEmpty }
        PresetCard {
            MusicHead(title: c.musicTitle ?? "Chords", sub: named ? "in \(key.name)" : "")
            SoundPicker(sound: $sound) { word in
                YuiSound.shared.strum(Theory.strumNotes(chords.first?.name ?? "C"), sound: word, direction: strum)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: chords.count > 4 && onStage ? 3 : 2),
                      spacing: 10) {
                ForEach(chords.indices, id: \.self) { i in
                    chordButton(i, chords[i], s)
                }
            }
            HStack(spacing: theme.spacing.s) {
                Text("Strum")
                    .font(theme.font(theme.type.caption, .bold))
                    .foregroundStyle(s.inkSoft)
                ForEach(YuiSound.Strum.allCases, id: \.self) { way in
                    MusicButton(text: way.rawValue.capitalized, icon: icon(way), on: strum == way) { strum = way }
                        .accessibilityLabel("Strum \(way.rawValue)")
                        .accessibilityAddTraits(strum == way ? .isSelected : [])
                        .accessibilityIdentifier("chords-strum-\(way.rawValue)")
                }
                Spacer(minLength: 0)
            }
            if !played.isEmpty {
                Text(played.suffix(8).joined(separator: " · "))
                    .font(theme.font(theme.type.caption, .bold))
                    .foregroundStyle(s.inkSoft)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .accessibilityIdentifier("chords-played")
            }
            BluetoothHint()
            TakeControl(c: c)
            if c.flag("send") {
                OptionPill(text: sent ? "Sent" : "Send", fill: s.accent, ink: s.onAccent, check: sent, grow: true) { send() }
                    .disabled(played.isEmpty || c.locked)
                    .accessibilityIdentifier("chords-send")
            }
        }
        .modifier(SoundHold())
        .sensoryFeedback(.impact(weight: .light), trigger: tapped)
        .onChange(of: c.props["strum"], initial: true) { strum = YuiSound.Strum(rawValue: c.string("strum")?.lowercased() ?? "") ?? .down }
        .onChange(of: c.props["sound"], initial: true) { sound = soundWord(c.string("sound"), fallback: "pluck") }
        .onChange(of: answers(scope, c.ylID), initial: true) { _, v in
            guard played.isEmpty, let p = v?["played"]?.array?.compactMap(\.string), !p.isEmpty else { return }
            played = p
            sent = true
        }
    }

    private func icon(_ way: YuiSound.Strum) -> String {
        switch way {
        case .down: "arrow.down"
        case .up: "arrow.up"
        case .off: "equal"
        }
    }

    private func chordButton(_ i: Int, _ chord: Theory.Chord, _ s: Swatch) -> some View {
        let color = rowColor(i, s)
        let hot = (lit[i] ?? 0) > 0
        return RoundedRectangle(cornerRadius: theme.radius.card * 0.8)
            .fill(hot ? color : color.opacity(0.28))
            .overlay(RoundedRectangle(cornerRadius: theme.radius.card * 0.8).stroke(s.outline, lineWidth: 1.5))
            .overlay {
                VStack(spacing: 2) {
                    Text(chord.name)
                        .font(theme.font(onStage ? theme.type.title : theme.type.body, .heavy))
                        .foregroundStyle(hot ? s.onAccent : s.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    if !chord.numeral.isEmpty {
                        Text(chord.numeral)
                            .font(theme.font(theme.type.caption, .bold))
                            .foregroundStyle(hot ? s.onAccent : s.inkSoft)
                    }
                }
                .padding(theme.spacing.s)
            }
            .scaleEffect(hot ? 0.96 : 1)
            .animation(.easeOut(duration: 0.08), value: hot)
            .frame(height: onStage ? 110 : 76)
            .contentShape(Rectangle())
            .overlay { FingerDown { play(i, chord) }.accessibilityHidden(true) }
            .accessibilityElement()
            .accessibilityLabel(chord.numeral.isEmpty ? chord.name : "\(chord.name), \(chord.numeral)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { play(i, chord) }
            .accessibilityIdentifier("chord-\(i)")
    }

    private func play(_ i: Int, _ chord: Theory.Chord) {
        guard !c.locked else { return }
        YuiSound.shared.strum(Theory.strumNotes(chord.name), sound: sound, direction: strum)
        tapped += 1
        lit[i, default: 0] += 1
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            lit[i] = max(0, (lit[i] ?? 1) - 1)
        }
        played = last32(played, chord.name)
        sent = false
    }

    private func send() {
        emit(c.event(["played": .array(played.map(YLValue.string)), "key": .string(key.name)], echo: "Sent my chords"))
        sent = true
    }
}
