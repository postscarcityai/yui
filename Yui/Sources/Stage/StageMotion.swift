import SwiftUI
import YuiLines

// Stage motion (YUI-120 step 2, spec yuigui/spec/YL.md section 5, Stage motion;
// mock www.yuigui.com/playground?demo=stage-motion). Chris, TestFlight
// AJq7CcQS8fyM: "How can this have dynamic animations based on the context of
// the agent?" What the agent is doing sets the shader blob's shape (StageAction,
// YUI-232), who it is sets the character (the look). Nothing changes on the wire.
// The reference is yuigui site/lib/yl/motion.mjs; YuiTests/StageMotionTests replays its cases.

/// The turn as the stage sees it, newest facts first: StageMotion.action reads it for the blob's shape.
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

// MARK: - The blob's shape

/// What the shader blob shows (YUI-232, yuigui site/lib/visual/action.mjs, spec/SHADER.md):
/// one shape per action, drawn by the orb in Visual.metal. Chris, Sep 30: "a perfect circle,
/// a football, and so on". The vector mark that sat over the shader is gone; only the
/// shader draws the agent.
enum StageAction: String, CaseIterable, Sendable {
    /// A perfect circle, a cloud, a football, a rounded square, a drop, a tall pill, the circle with a ring.
    case idle, thinking, reading, running, searching, talking, done

    private static func re(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }
    /// action.mjs RULES: the first hit wins, searching before reading (a "look up" is a search).
    private static let rules: [(StageAction, NSRegularExpression)] = [
        (.searching, re(#"\b(search|searching|find|finding|look(ing)? up|browse|browsing|fetch|fetching|crawl|scour)\b"#)),
        (.reading, re(#"\b(read|reading|open|opening|review|reviewing|check|checking|scan|scanning|look(ing)? (at|through|over)|skim|parse|parsing)\b"#)),
        (.running, re(#"\b(run|running|build|building|deploy|deploying|test|testing|send|sending|install|installing|writ(e|ing)|sav(e|ing)|compil(e|ing)|push|pushing|execut(e|ing)|render|rendering)\b"#)),
    ]

    /// The state a doing line's words name. Nil or no clue: the agent is thinking.
    static func of(doing: String?) -> StageAction {
        guard let t = doing, !t.trimmingCharacters(in: .whitespaces).isEmpty else { return .thinking }
        let r = NSRange(t.startIndex..., in: t)
        return rules.first { $0.1.firstMatch(in: t, range: r) != nil }?.0 ?? .thinking
    }
}

extension StageMotion {
    /// The blob's state for the turn: the mic open is talking, the reply's beat is done, a
    /// doing line names its action, a sent ask with nothing yet is thinking, the rest is idle.
    static func action(_ f: StageFacts) -> StageAction {
        if f.failed { return .idle }
        if f.listening { return .talking }
        if f.asking || f.chunk != nil { return .idle }
        if f.arrived { return .done }
        if let d = f.doing { return .of(doing: d) }
        return f.sent ? .thinking : .idle
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
