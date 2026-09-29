import Foundation
import YuiLines

// The visual's plan (YUI-124 step 2, spec yuigui/spec/VISUAL.md; mock
// www.yuigui.com/playground?demo=visualizer). Chris, TestFlight AJq7CcQS8fyM:
// "The ability to have a visualizer would be very important. Think shaders."
// Which look, which colors, how the level follows the sound, how far it sinks
// behind words and the frame budget. The reference is yuigui
// site/lib/yl/visual.mjs; YuiTests/VisualPlanTests replays its numbers. The
// shaders are Visual.metal, the view StageVisual.swift.

struct VisualPlan: Equatable, Sendable {
    /// The five looks, in picker order, with what the pill and VoiceOver call them.
    static let names = ["orb": "Orb", "aurora": "Aurora", "waves": "Waves", "grain": "Grain", "bloom": "Bloom"]
    static let hears = ["voice": "listening to your voice", "music": "moving with the music",
                        "mic": "listening to the room", "off": "moving on its own"]
    /// What each look does with the sound's lows, mids and highs (YUI-125; Visual.metal does it).
    static let listens: [String: (low: String, mid: String?, high: String)] = [
        "orb": ("pulses", "ripples", "glows"), "aurora": ("widens", "shimmers", "glows"),
        "waves": ("swell", "ripple", "glow"), "grain": ("spreads", nil, "sparkles"),
        "bloom": ("opens", "flutters", "glows"),
    ]

    /// The frame budget (VISUAL.md section 5). fps 0 is one still frame.
    enum Budget {
        static let aloneFps = 60, behindFps = 30
        /// A quiet default (YUI-180) draws at 30 fps and at 15 while nothing is heard.
        static let quietIdleFps = 15
        static let scale = 0.5, grainScale = 0.75
        static let meterHz = 30.0
        /// Behind words: the picture at this strength, the scrim over the words' zone
        /// (fractions of the height from the bottom: full below the first, none above the second).
        static let behindDim = 0.7
        static let zone = (0.34, 0.58)
    }

    struct Colors: Equatable, Sendable {
        var a, b, c, ground, ink: String
    }

    /// How the level follows the sound: times in ms at the look's pace.
    struct Envelope: Equatable, Sendable {
        var attack, release: Double
        var steps: Int
        var gain: Double

        static let soft = Envelope(attack: 180, release: 900, steps: 0, gain: 0.75)
        static let beat = Envelope(attack: 25, release: 260, steps: 0, gain: 1)
        static let tick = Envelope(attack: 10, release: 160, steps: 4, gain: 0.9)
        static let still = Envelope(attack: 0, release: 0, steps: 0, gain: 0)

        /// The look's pulse at its pace (motion.mjs PACES).
        init(_ motion: MotionLook) {
            let e: Envelope = switch motion.pulse {
            case .soft: .soft
            case .beat: .beat
            case .tick: .tick
            case .still: .still
            }
            let k = MotionLook.paces[motion.pace] ?? 1
            self = Envelope(attack: (e.attack * k).rounded(), release: (e.release * k).rounded(), steps: e.steps, gain: e.gain)
        }

        init(attack: Double, release: Double, steps: Int, gain: Double) {
            self.attack = attack; self.release = release; self.steps = steps; self.gain = gain
        }

        /// One step of the follower: `input` the raw level 0...1, `prev` the last output,
        /// `dt` ms since. Up at the attack, down at the release. It stays smooth: tick's
        /// quarters are `shown`, never fed back (rounded, it stuck at 0.25 once the sound stopped).
        func follow(_ prev: Double, _ input: Double, dt: Double) -> Double {
            guard gain > 0 else { return 0 }
            let x = min(1, max(0, input.isFinite ? input : 0)) * gain
            let t = x > prev ? attack : release
            let k = t <= 0 ? 1 : 1 - exp(-max(0, dt) / t)
            return prev + (x - prev) * k
        }

        /// What the shader gets: tick moves in quarters, the rest as is.
        func shown(_ level: Double) -> Double {
            steps > 0 ? (level * Double(steps)).rounded() / Double(steps) : level
        }
    }

    enum Why: String, Sendable { case reduceMotion = "reduce-motion", lowPower = "low-power", hot, hidden }

    var look: String
    var react: String
    var tone: String
    var colors: Colors
    var env: Envelope
    /// The clock's speed: 1 / pace, 0 when still.
    var speed: Double
    var dim: Double
    var scrim: Double
    /// The words' zone, fractions of the height from the bottom: full scrim below `zone.low`,
    /// none above `zone.high`. The spec's is the web mock's layout (words low on the stage);
    /// the app passes where its words really sit, so the scrim always lies under them.
    var zone: Zone
    struct Zone: Equatable, Sendable {
        var low, high: Double
        static let spec = Zone(low: Budget.zone.0, high: Budget.zone.1)
        /// Words whose top edge is `top` of the height up from the bottom: full scrim to just above them.
        static func under(top: Double) -> Zone {
            let t = min(0.97, max(Budget.zone.0, top + 0.03))
            return Zone(low: t, high: min(1, t + 0.14))
        }
    }
    var fps: Int
    /// The rate while nothing is heard: below `fps` only for a quiet default.
    var idleFps: Int
    var quiet: Bool
    var scale: Double
    var why: Why?
    var still: Bool { why != nil }
    var label: String { "\(Self.names[look] ?? "Orb"), \(Self.hears[react] ?? Self.hears["voice"]!)" }
    /// What it does with the sound, for VoiceOver: "Orb pulses with the lows, ripples with the mids and glows with the highs."
    var hint: String? {
        guard react != "off", !still, let l = Self.listens[look] else { return nil }
        let parts = ["\(l.low) with the lows", l.mid.map { "\($0) with the mids" }, "\(l.high) with the highs"].compactMap { $0 }
        return "\(Self.names[look] ?? "Orb") " + parts.dropLast().joined(separator: ", ") + " and " + parts.last! + "."
    }

    /// Everything the stage draws for one visual, or nil for none.
    ///   accent, ground, ink  the agent's color and the stage's paper and ink in this appearance
    ///   words                a chunk with words is on the stage (dim and scrim)
    ///   hidden               the stage is closed or the app is in the background
    ///   quiet                the agent's default (YUI-180): its strength, at the slower of its pace and the
    ///                        agent's, at 30 fps and 15 while nothing is heard
    init?(_ v: YLVisual?, accent: String, ground: String, ink: String, motion: MotionLook,
          words: Bool = false, zone: Zone = .spec, lowPower: Bool = false, thermal: ProcessInfo.ThermalState = .nominal, hidden: Bool = false,
          quiet def: VisualDefault? = nil) {
        guard let v else { return nil }
        var motion = motion
        if let def, let k = MotionLook.paces[def.motionPace], k > (MotionLook.paces[motion.pace] ?? 1) { motion.pace = def.motionPace }
        look = v.look.flatMap { YuiLines.visualLooks.contains($0) ? $0 : nil } ?? "orb"
        react = v.react.flatMap { YuiLines.visualReact.contains($0) ? $0 : nil } ?? "voice"
        tone = Self.tone(v.tone, accent: accent)
        colors = Self.colors(tone, ground: ground, ink: ink)
        dim = (def?.level ?? 1) * (words ? Budget.behindDim : 1)
        quiet = def != nil
        why = motion.reduced ? .reduceMotion : lowPower ? .lowPower
            : thermal == .serious || thermal == .critical ? .hot : hidden ? .hidden : nil
        env = why != nil || react == "off" ? .still : Envelope(motion)
        speed = why != nil ? 0 : 1 / (MotionLook.paces[motion.pace] ?? 1)
        scrim = words ? Self.scrim(colors, dim: dim) : 0
        self.zone = zone
        fps = why != nil ? 0 : def != nil || words || thermal == .fair ? Budget.behindFps : Budget.aloneFps
        idleFps = why != nil ? 0 : def != nil ? Budget.quietIdleFps : fps
        scale = look == "grain" ? Budget.grainScale : Budget.scale
    }

    // MARK: Color (visual.mjs visualTone, visualColors, scrimFor)

    /// tone= over the agent's own color: a hex, a set's accent, else the agent's.
    static func tone(_ tone: String?, accent: String) -> String {
        if let t = tone, let hex = AgentLook.hex(t) { return hex }
        if let t = tone, let r = AgentLook.recipe(t), t == t.lowercased() { return r.accent }
        return AgentLook.hex(accent) ?? "#FF7E8A"
    }

    /// Three colors from one: the tone, a lighter neighbor warmer on the wheel and a
    /// deeper one cooler, over the stage's ground. Clamped so each shows on it.
    static func colors(_ tone: String, ground: String, ink: String) -> Colors {
        let c = (RGB(hex: tone) ?? RGB(hex: "#FF7E8A")!).hsl
        let dark = (RGB(hex: ground)?.luminance ?? 1) < 0.18
        let s = max(0.35, min(0.9, c.s))
        let l = dark ? max(0.5, min(0.66, c.l)) : max(0.46, min(0.62, c.l))
        return Colors(
            a: RGB(h: c.h, s: s, l: l).hex,
            b: RGB(h: c.h + 28, s: min(1, s * 0.9), l: min(0.82, l + 0.14)).hex,
            c: RGB(h: c.h - 40, s: min(1, s * 1.05), l: max(0.3, l - 0.14)).hex,
            ground: ground, ink: ink)
    }

    /// The least scrim (0...0.92, in steps of .02) that keeps the ink at 4.6:1 over the
    /// worst pixel the shader can make: any of its colors at `dim` over the ground.
    static func scrim(_ colors: Colors, dim: Double, min: Double = AgentLook.Guard.text) -> Double {
        let ground = RGB(hex: colors.ground)!, ink = RGB(hex: colors.ink)!
        func mix(_ x: RGB, _ y: RGB, _ t: Double) -> RGB {
            RGB(r: x.r + (y.r - x.r) * t, g: x.g + (y.g - x.g) * t, b: x.b + (y.b - x.b) * t)
        }
        let worst = [colors.a, colors.b, colors.c].map { mix(ground, RGB(hex: $0)!, dim) }
        var a = 0.0
        while a <= 0.92 + 1e-9 {
            if worst.allSatisfy({ RGB.contrast(mix($0, ground, a), ink) >= min }) { return (a * 100).rounded() / 100 }
            a += 0.02
        }
        return 0.92
    }

    // MARK: Sound (visual.mjs levelOf)

    /// RMS of a block of samples in dB, -60...-10 dBFS mapped to 0...1: a speaking voice sits near the middle.
    static func level(_ samples: some Collection<Float>) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        let db = 20 * log10((sum / Double(samples.count)).squareRoot() + 1e-9)
        return min(1, max(0, (db + 60) / 50))
    }
}
