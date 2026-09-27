import SwiftUI
import YuiLines

// Stage motion (YUI-120 step 2, spec yuigui/spec/YL.md section 5, Stage motion;
// mock www.yuigui.com/playground?demo=stage-motion). Chris, TestFlight
// AJq7CcQS8fyM: "How can this have dynamic animations based on the context of
// the agent?" What the agent is doing sets the move (the mood), who it is sets
// the character (the look). Nothing changes on the wire. The reference is
// yuigui site/lib/yl/motion.mjs; YuiTests/StageMotionTests replays its cases.

/// What the agent is doing right now, read from the turn.
enum StageMood: String, CaseIterable, Sendable {
    case idle, listen, think, work, found, done, ask, error
}

/// What kind of work a `doing` line is: looking sweeps, making builds up, the rest morphs.
enum StageFlavor: String, Sendable {
    case scan, make, work, found
}

/// The turn as the stage sees it, newest facts first (motion.mjs stageMood).
struct StageFacts: Equatable, Sendable {
    /// The turn ended with an error (a reply of nothing but error lines, or the host failed).
    var failed = false
    /// The mic is open.
    var listening = false
    /// The questions screen is up.
    var asking = false
    /// The chunk on the stage, nil before the reply plays.
    var chunk: Int?
    /// The reply just came in: one beat of found before the first chunk.
    var arrived = false
    /// The newest `doing` words, nil when there is none.
    var doing: String?
    /// The person's words went out.
    var sent = false
}

enum StageMotion {
    private static func re(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }
    private static let found = re(#"^(found|got|there(?:'s| is| are)|spotted|ready|done|all set|nailed)\b"#)
    private static let scan = re(#"\b(check|read|look|search|scan|find|fetch|pull|load|listen|watch|compar|ask|query|open|brows|review|count)\w*"#)
    private static let make = re(#"\b(writ|draft|build|draw|mak|plan|compos|sketch|render|cook|mix|design|shap|lay|put|sav|send)\w*"#)

    /// A doing line's words: a find is the found beat, else the first verb picks looking or making.
    static func doingMood(_ text: String) -> (mood: StageMood, flavor: StageFlavor) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = NSRange(t.startIndex..., in: t)
        if found.firstMatch(in: t, range: r) != nil { return (.found, .found) }
        let s = scan.firstMatch(in: t, range: r)?.range.location
        let m = make.firstMatch(in: t, range: r)?.range.location
        switch (s, m) {
        case let (s?, m?): return (.work, s <= m ? .scan : .make)
        case (.some, nil): return (.work, .scan)
        case (nil, .some): return (.work, .make)
        default: return (.work, .work)
        }
    }

    /// The first true fact wins: error, listen, ask, done, found, work, think, idle.
    static func mood(_ f: StageFacts) -> (mood: StageMood, flavor: StageFlavor?) {
        if f.failed { return (.error, nil) }
        if f.listening { return (.listen, nil) }
        if f.asking { return (.ask, nil) }
        if f.chunk != nil { return (.done, nil) }
        if f.arrived { return (.found, .found) }
        if let d = f.doing {
            if d.trimmingCharacters(in: .whitespaces).isEmpty { return (.work, .work) }
            let x = doingMood(d)
            return (x.mood, x.flavor)
        }
        if f.sent { return (.think, nil) }
        return (.idle, nil)
    }

    /// A reply of nothing but error lines failed the turn.
    static func failed(_ yl: YLScreen?) -> Bool {
        guard let yl else { return false }
        return !yl.errors.isEmpty && yl.components.isEmpty
    }
}

// MARK: - The look

/// How one agent moves: its pace, its easing, how things come on and how it breathes.
struct MotionLook: Equatable, Sendable {
    enum Pace: String, CaseIterable, Sendable { case slow, even, quick }
    enum Ease: String, CaseIterable, Sendable { case float, spring, sharp, heavy }
    enum Enter: String, CaseIterable, Sendable { case rise, pop, slide, drop, fade }
    enum Pulse: String, CaseIterable, Sendable { case soft, beat, tick, still }

    var pace: Pace
    var ease: Ease
    var enter: Enter
    var pulse: Pulse
    /// bouncy, calm, snappy, custom (the person's words on top), or still (Reduce Motion).
    var character: String
    var reduced = false

    static let characters: [String: MotionLook] = [
        "bouncy": MotionLook(pace: .even, ease: .spring, enter: .pop, pulse: .beat, character: "bouncy"),
        "calm": MotionLook(pace: .slow, ease: .float, enter: .rise, pulse: .soft, character: "calm"),
        "snappy": MotionLook(pace: .quick, ease: .sharp, enter: .slide, pulse: .tick, character: "snappy"),
    ]
    static let still = MotionLook(pace: .even, ease: .float, enter: .fade, pulse: .still, character: "still", reduced: true)

    /// The saved look (its character from `motion=` or the agent's set, then the four keys
    /// said in words), with a look being tried on top. Unknown values are dropped; Reduce Motion wins.
    init(character: String, look: AgentLook? = nil, custom: [String: String]? = nil, reduced: Bool) {
        if reduced { self = .still; return }
        let name = Self.characters[character] == nil ? "bouncy" : character
        self = Self.characters[name]!
        var own = false
        for src in [look.map(Self.keys) ?? [:], custom ?? [:]] {
            if let v = src["pace"].flatMap(Pace.init) { pace = v; own = true }
            if let v = src["ease"].flatMap(Ease.init) { ease = v; own = true }
            if let v = src["enter"].flatMap(Enter.init) { enter = v; own = true }
            if let v = src["pulse"].flatMap(Pulse.init) { pulse = v; own = true }
        }
        if own { self.character = "custom" }
    }

    private init(pace: Pace, ease: Ease, enter: Enter, pulse: Pulse, character: String, reduced: Bool = false) {
        self.pace = pace; self.ease = ease; self.enter = enter; self.pulse = pulse
        self.character = character; self.reduced = reduced
    }

    private static func keys(_ l: AgentLook) -> [String: String] {
        var o: [String: String] = [:]
        o["pace"] = l.pace; o["ease"] = l.ease; o["enter"] = l.enter; o["pulse"] = l.pulse
        return o
    }

    // MARK: Timings (motion.mjs motionTimings)

    static let paces: [Pace: Double] = [.slow: 1.4, .even: 1, .quick: 0.68]
    static let pulses: [Pulse: Double] = [.soft: 3.6, .beat: 1.7, .tick: 1.1, .still: 0]

    /// Seconds at the look's pace. Reduce Motion: everything is 0 but a short fade.
    struct Timings: Equatable, Sendable {
        var enter, handoff, stagger, beat, open, breath: Double
        static let fade = 0.16
    }

    var timings: Timings {
        if reduced { return Timings(enter: 0, handoff: 0, stagger: 0, beat: 0, open: 0, breath: 0) }
        let k = Self.paces[pace] ?? 1
        func ms(_ v: Double) -> Double { (v * k).rounded() / 1000 }
        let breath = ((Self.pulses[pulse] ?? 0) * 1000 * (k > 1 ? 1.1 : k < 1 ? 0.9 : 1)).rounded() / 1000
        return Timings(enter: ms(440), handoff: ms(360), stagger: ms(80), beat: ms(600), open: ms(520), breath: breath)
    }

    /// The look's curve (motion.mjs EASES) over `duration` seconds.
    func curve(_ duration: Double) -> Animation {
        if reduced { return .easeInOut(duration: Timings.fade) }
        return switch ease {
        case .float: .timingCurve(0.45, 0, 0.2, 1, duration: duration)
        case .spring: .timingCurve(0.2, 0.9, 0.3, 1.3, duration: duration)
        case .sharp: .timingCurve(0.3, 0, 0, 1, duration: duration)
        case .heavy: .timingCurve(0.7, 0, 0.2, 1, duration: duration)
        }
    }

    /// A chunk coming on, or the stage handing over.
    var enterAnimation: Animation { curve(timings.enter) }
    var handoffAnimation: Animation { curve(timings.handoff) }

    /// How a chunk or a question comes on; going back comes on from the other side.
    func transition(back: Bool = false) -> AnyTransition {
        if reduced { return .opacity }
        let insert: AnyTransition = switch enter {
        case .rise: .offset(y: back ? -48 : 48).combined(with: .opacity)
        case .pop: .scale(scale: 0.82).combined(with: .opacity)
        case .slide: .move(edge: back ? .leading : .trailing).combined(with: .opacity)
        case .drop: .offset(y: back ? 64 : -64).combined(with: .opacity)
        case .fade: .opacity
        }
        return .asymmetric(insertion: insert, removal: .opacity)
    }

    /// A look in a few plain words (motion.mjs lookWords): "quick, heavy, drops in, beats".
    var words: String {
        if reduced { return "Reduce Motion: no movement" }
        let pace = self.pace.rawValue
        let ease = ["float": "floats", "spring": "springs", "sharp": "sharp", "heavy": "heavy"][self.ease.rawValue]!
        let enter = self.enter.rawValue == "slide" ? "slides in" : self.enter.rawValue + "s in"
        let pulse = ["soft": "breathes long", "beat": "beats", "tick": "ticks", "still": "holds still"][self.pulse.rawValue]!
        return [pace, ease, enter, pulse].joined(separator: ", ")
    }
}

extension AgentLook {
    /// The agent's character: `motion=`, else its set's, else the one seeded from its name.
    static func character(_ look: AgentLook?, name: String, isYui: Bool = false) -> String {
        if let m = look?.motion, motions.contains(m) { return m }
        if let p = look?.preset, let r = recipe(p) { return r.motion }
        return (isYui ? recipe("yui")! : recipe(name) ?? seeded(name)).motion
    }
}

extension YuiAgent {
    /// How this agent's stage moves (YUI-120, YUI-123). Reduce Motion wins.
    func motionLook(reduced: Bool) -> MotionLook {
        MotionLook(character: AgentLook.character(theme, name: handle.isEmpty ? name : handle, isYui: isYui),
                   look: theme, custom: Self.demoLook, reduced: reduced)
    }

    /// DEBUG `-yuiDemoLook "pace=quick ease=heavy enter=drop pulse=beat"`: screenshots of a look said in words.
    static var demoLook: [String: String]? {
        #if DEBUG
        guard let s = UserDefaults.standard.string(forKey: "yuiDemoLook") else { return nil }
        return Dictionary(s.split(separator: " ").compactMap { kv -> (String, String)? in
            let p = kv.split(separator: "=", maxSplits: 1).map(String.init)
            return p.count == 2 ? (p[0], p[1]) : nil
        }, uniquingKeysWith: { _, b in b })
        #else
        return nil
        #endif
    }
}

// MARK: - The mark

/// The one thing that moves: three layers of the agent's color, drawn per frame.
/// idle breathes, think turns its layers over each other, work sweeps (looking),
/// stacks up (making) or morphs, found bursts once and settles, error shakes and
/// goes grey. Reduce Motion draws it still.
struct StageMark: View {
    let color: Color
    let mood: StageMood
    let flavor: StageFlavor?
    let look: MotionLook
    /// When this mood began: one-shot moves (the burst, the shake) count from here.
    let since: Date
    /// Room past each edge of the frame: the found ring grows to 1.6 times the mark.
    static let headroom = 0.32

    var body: some View {
        let t = look.timings
        // The canvas runs past the frame so the breath, the pop and the found ring
        // are never clipped; the layout keeps the frame the caller gave.
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: nil, paused: look.reduced)) { ctx in
                Canvas { g, size in
                    let now = look.reduced ? since : ctx.date
                    draw(&g, size: size, t: now.timeIntervalSinceReferenceDate, tau: max(0, now.timeIntervalSince(since)), timings: t)
                }
            }
            .padding(-min(geo.size.width, geo.size.height) * Self.headroom)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(_ g: inout GraphicsContext, size: CGSize, t: Double, tau: Double, timings: MotionLook.Timings) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        // The mark's own radius: the canvas is (1 + 2 * headroom) times the frame.
        let r = min(size.width, size.height) / 2 / (1 + 2 * Self.headroom)
        let tint = mood == .error ? Color.gray : color
        let layers: [(size: Double, opacity: Double)] = [(1.0, 0.30), (0.78, 0.45), (0.5, 1.0)]
        let still = look.reduced
        // One period for the breathing and the loops; pulse=still still needs one for a sweep.
        let period = timings.breath > 0 ? timings.breath : 2.4
        let beat = max(0.2, timings.beat)

        var shake = 0.0
        if mood == .error, !still { shake = 9 * exp(-tau * 5) * sin(tau * 42) }

        // found: one burst and a settle.
        var pop = 1.0
        if mood == .found, !still {
            let x = tau / (beat * 1.2)
            if x < 1 {
                let ring = Path(ellipseIn: CGRect(x: c.x - r * (1 + 0.6 * x), y: c.y - r * (1 + 0.6 * x),
                                                  width: 2 * r * (1 + 0.6 * x), height: 2 * r * (1 + 0.6 * x)))
                g.stroke(ring, with: .color(tint.opacity(0.5 * (1 - x))), lineWidth: 6 * (1 - x) + 1)
            }
            pop = 1 + 0.18 * exp(-tau * 5) * cos(tau * 14)
        }

        for (i, l) in layers.enumerated() {
            var s = l.size * pop
            var dx = shake, dy = 0.0
            if !still {
                switch (mood, flavor) {
                case (.think, _):
                    // The layers turn slowly over each other.
                    let a = t * 2 * .pi / (period * 1.6) + Double(i) * 2 * .pi / 3
                    dx += cos(a) * r * 0.07 * (1 - l.size + 0.3)
                    dy += sin(a) * r * 0.07 * (1 - l.size + 0.3)
                    s *= breath(t, period: period * 1.3, phase: Double(i) * 0.2, amp: 0.03)
                case (.work, .make?):
                    // The layers stack up, one after another, then again.
                    let cycle = beat * 4
                    let x = (t.truncatingRemainder(dividingBy: cycle)) / beat - Double(2 - i)
                    s *= x < 0 ? 0.001 : min(1, easeOut(min(1, x)))
                case (.idle, _), (.work, _), (.listen, _):
                    s *= breath(t, period: period, phase: Double(i) * 0.18, amp: 0.05)
                default: break
                }
            }
            if mood == .work, flavor == .work, i == 0, !still {
                // Other work: the outer layer morphs.
                g.fill(blob(center: CGPoint(x: c.x + dx, y: c.y + dy), r: r * s, t: t, period: period),
                       with: .color(tint.opacity(l.opacity)))
                continue
            }
            let rr = r * s
            g.fill(Path(ellipseIn: CGRect(x: c.x + dx - rr, y: c.y + dy - rr, width: 2 * rr, height: 2 * rr)),
                   with: .color(tint.opacity(l.opacity)))
        }

        if mood == .work, flavor == .scan, !still {
            // Looking: a light sweeps round the mark.
            let a = Angle.radians(t * 2 * .pi / (beat * 2.4))
            var sweep = g
            sweep.translateBy(x: c.x, y: c.y)
            sweep.rotate(by: a)
            let arc = Path { p in
                p.addArc(center: .zero, radius: r * 0.9, startAngle: .degrees(-50), endAngle: .degrees(0), clockwise: false)
            }
            sweep.stroke(arc, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: r * 0.09, lineCap: .round))
        }
    }

    /// One breath: soft is a slow sine, beat a double thump, tick a short step; still does not breathe.
    private func breath(_ t: Double, period: Double, phase: Double, amp: Double) -> Double {
        guard look.pulse != .still, period > 0 else { return 1 }
        let x = (t / period + phase).truncatingRemainder(dividingBy: 1)
        switch look.pulse {
        case .soft: return 1 + amp * sin(x * 2 * .pi)
        case .beat:
            // lub-dub
            let a = exp(-pow((x - 0.1) * 14, 2)), b = exp(-pow((x - 0.32) * 14, 2)) * 0.6
            return 1 - amp * 0.5 + amp * 1.6 * (a + b)
        case .tick: return x < 0.12 ? 1 + amp * 1.2 : 1 - amp * 0.2
        case .still: return 1
        }
    }

    private func easeOut(_ x: Double) -> Double {
        switch look.ease {
        case .spring: let y = 1 - pow(1 - x, 3); return y + 0.12 * sin(x * .pi)
        case .heavy: return 1 - pow(1 - x, 4)
        case .sharp: return 1 - pow(1 - x, 5)
        case .float: return 0.5 - 0.5 * cos(x * .pi)
        }
    }

    private func blob(center: CGPoint, r: Double, t: Double, period: Double) -> Path {
        Path { p in
            let n = 72
            for k in 0...n {
                let a = Double(k) / Double(n) * 2 * .pi
                let w = 1 + 0.07 * sin(3 * a + t * 2 * .pi / period) + 0.04 * sin(5 * a - t * 2 * .pi / (period * 1.7))
                let pt = CGPoint(x: center.x + cos(a) * r * w, y: center.y + sin(a) * r * w)
                if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
        }
    }
}

// MARK: - The moves between

/// The stage opens from the mic: a wash of the agent's color growing out of the bottom right.
struct StageWash: View {
    let color: Color
    let look: MotionLook
    /// Changes each time the stage opens on something the person said.
    let trigger: Int

    var body: some View {
        if look.reduced { Color.clear.allowsHitTesting(false) } else {
            GeometryReader { geo in
                let d = hypot(geo.size.width, geo.size.height) * 2
                Circle()
                    .fill(color)
                    .frame(width: d, height: d)
                    .position(x: geo.size.width, y: geo.size.height)
                    .keyframeAnimator(initialValue: 1.0, trigger: trigger) { v, x in
                        v.scaleEffect(max(0.001, x), anchor: .center).opacity(0.35 * (1 - x))
                    } keyframes: { _ in
                        KeyframeTrack {
                            MoveKeyframe(0.0)
                            CubicKeyframe(1.0, duration: max(0.2, look.timings.open))
                        }
                    }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// A question comes on a stagger after the one before it, in the look's enter.
struct StaggerIn: ViewModifier {
    let index: Int
    let look: MotionLook
    @State private var on = false

    func body(content: Content) -> some View {
        let off = on || look.reduced
        content
            .opacity(off ? 1 : 0)
            .offset(x: off || look.enter != .slide ? 0 : 40, y: off ? 0 : shift)
            .scaleEffect(off || look.enter != .pop ? 1 : 0.9)
            .onAppear {
                guard !look.reduced else { return }
                withAnimation(look.enterAnimation.delay(Double(index) * look.timings.stagger + look.timings.stagger)) { on = true }
            }
    }

    private var shift: CGFloat {
        switch look.enter {
        case .rise: 28
        case .drop: -36
        case .slide, .pop, .fade: 0
        }
    }
}
