import Foundation
import Testing
@testable import YuiSound

// The tuner without a microphone (MUSIC.md sections 6 and 8, step 4): the
// pitch detector against tones at known offsets, the tunings table, the
// "held in tune for a second" rule and tap tempo.

/// A tone at `hz`: a sine, or a plucked string (harmonics at 1/n, decaying)
/// with noise `noise` below full scale. Random start phase.
func tone(_ hz: Double, count: Int, sampleRate: Double = 48000, pluck: Bool = false, noise: Float = 0, seed: UInt64 = 1) -> [Float] {
    var rng = SeededRandom(seed)
    let phase = Double.random(in: 0..<(2 * .pi), using: &rng)
    return (0..<count).map { i in
        let t = Double(i) / sampleRate
        var x = 0.0
        if pluck {
            for h in 1...8 { x += sin(2 * .pi * hz * Double(h) * t + phase * Double(h)) / Double(h) * exp(-t * Double(h) * 1.5) }
            x *= 0.4
        } else {
            x = 0.5 * sin(2 * .pi * hz * t + phase)
        }
        return Float(x) + (noise > 0 ? Float.random(in: -noise...noise, using: &rng) : 0)
    }
}

struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

@Suite struct TunerTests {
    static let offsets: [Double] = [-45, -30, -17, -9, -4, -2, -1, 0, 1, 2.5, 3, 6, 12, 25, 40]
    static let tunings: [(String, String)] = [("guitar", "standard"), ("guitar", "dropd"), ("guitar", "dadgad"),
                                              ("ukulele", "standard"), ("ukulele", "lowg"), ("bass", "standard"), ("bass", "five")]

    /// Every string of every tuning, at every offset: the reading lands on the
    /// right string and within 2 cents of the offset (the step 4 bar).
    func sweep(pluck: Bool, noise: Float) -> Double {
        var worst = 0.0
        for (inst, name) in Self.tunings {
            let t = Tuning(instrument: inst, tuning: name)
            let r = t.range
            for (i, _) in t.strings.enumerated() {
                for c in Self.offsets {
                    let hz = t.hz(i) * pow(2, c / 1200)
                    let x = tone(hz, count: t.window, pluck: pluck, noise: noise, seed: UInt64(i * 100) + UInt64(c + 100))
                    guard let got = Pitch.detect(x, sampleRate: 48000, minHz: r.minHz, maxHz: r.maxHz) else {
                        Issue.record("\(inst) \(name) \(t.strings[i]) \(c): nothing"); continue
                    }
                    let near = t.nearest(got.hz)
                    #expect(near.index == i || t.midis[near.index] == t.midis[i], "\(inst) \(name) \(t.strings[i]) \(c): heard \(near.note)")
                    let err = abs(Pitch.cents(got.hz, t.hz(i)) - c)
                    #expect(err <= 2, "\(inst) \(name) \(t.strings[i]) at \(c) cents: off by \(err)")
                    if err > 1 { print("  over 1 cent: \(inst) \(name) \(t.strings[i]) at \(c): \(String(format: "%.2f", err))") }
                    worst = max(worst, err)
                }
            }
        }
        return worst
    }

    @Test("sine tones at known offsets read within 2 cents on every string")
    func sines() {
        let worst = sweep(pluck: false, noise: 0)
        print("tuner sine sweep: worst error \(String(format: "%.3f", worst)) cents")
        #expect(worst <= 2)
    }

    @Test("plucked strings with noise read within 2 cents on every string")
    func plucks() {
        let worst = sweep(pluck: true, noise: 0.02)
        print("tuner pluck sweep (noise -34 dB): worst error \(String(format: "%.3f", worst)) cents")
        #expect(worst <= 2)
    }

    @Test("the engine's own reference tones, detuned by known amounts, read within 2 cents")
    func referenceTones() {
        var worst = 0.0
        for a4 in [440.0, 442.0] {
            for (inst, name) in [("guitar", "standard"), ("ukulele", "standard"), ("bass", "standard")] {
                let t = Tuning(instrument: inst, tuning: name, a4: a4)
                for i in t.strings.indices {
                    for c in [-20.0, -3, 0, 2, 11] {
                        let k = SynthKernel(sampleRate: rate)
                        let hz = t.hz(i) * pow(2, c / 1200)
                        k.noteOn(.keys, midi: t.midis[i], velocity: 0.9, hold: 2.5, hz: Float(hz))
                        let audio = renderAll(k, seconds: 0.3)
                        // A window from 50 ms in, after the attack.
                        let x = Array(audio[2400..<(2400 + t.window)])
                        let r = t.range
                        guard let got = Pitch.detect(x, sampleRate: rate, minHz: r.minHz, maxHz: r.maxHz) else {
                            Issue.record("\(inst) \(t.strings[i]) \(c) a4 \(a4): nothing"); continue
                        }
                        let err = abs(Pitch.cents(got.hz, t.hz(i)) - c)
                        #expect(err <= 2, "\(inst) \(t.strings[i]) at \(c) cents, a4 \(a4): off by \(err)")
                        worst = max(worst, err)
                    }
                }
            }
        }
        print("tuner engine reference tones: worst error \(String(format: "%.3f", worst)) cents")
    }

    @Test("silence and noise read as nothing")
    func quiet() {
        #expect(Pitch.detect([Float](repeating: 0, count: 2048), sampleRate: 48000) == nil)
        var rng = SeededRandom(7)
        let noise = (0..<2048).map { _ in Float.random(in: -0.3...0.3, using: &rng) }
        #expect(Pitch.detect(noise, sampleRate: 48000, minHz: 70, maxHz: 1000) == nil)
    }

    @Test("the chromatic tuner names the nearest of all twelve notes")
    func chromatic() {
        let t = Tuning(instrument: "chromatic")
        #expect(t.chromatic && t.strings.isEmpty && t.window == 4096)
        let n = t.nearest(440 * pow(2, 7.0 / 1200))
        #expect(n.note == "A4" && n.index == -1 && abs(n.cents - 7) < 1e-6)
        #expect(t.nearest(Pitch.hz(midi: 61)).note == "C#4")
        #expect(t.nearest(30.87).note == "B0")
    }

    @Test("the tunings table matches MUSIC.md section 2")
    func table() {
        #expect(Tuning().strings == ["E2", "A2", "D3", "G3", "B3", "E4"])
        #expect(Tuning(instrument: "guitar", tuning: "dropd").strings.first == "D2")
        #expect(Tuning(instrument: "ukulele").strings == ["G4", "C4", "E4", "A4"])
        #expect(Tuning(instrument: "ukulele", tuning: "lowg").strings.first == "G3")
        #expect(Tuning(instrument: "bass", tuning: "five").strings == ["B0", "E1", "A1", "D2", "G2"])
        let odd = Tuning(instrument: "guitar", tuning: "openg")
        #expect(odd.fellBack && odd.tuning == "standard" && odd.strings.count == 6)
        let custom = Tuning(strings: ["D2", "A2", "D3", "G3", "A3", "D4", "nope"])
        #expect(custom.custom && custom.strings.count == 6 && !custom.fellBack)
        #expect(Tuning(instrument: "banjo").instrument == "guitar")
        #expect(Tuning(a4: 442).a4 == 442 && Tuning(a4: 1000).a4 == 440)
        #expect(abs(Tuning().hz(0) - 82.41) < 0.01 && abs(Tuning(instrument: "bass", tuning: "five").hz(0) - 30.87) < 0.01)
        #expect(Tuning().window == 2048 && Tuning(instrument: "bass").window == 4096)
        #expect(Tuning().range.minHz == 70 && Tuning(instrument: "bass", tuning: "five").range.minHz < 28)
    }

    @Test("a string is tuned after a second within 3 cents; the event fires once, when all are")
    func tracker() {
        var t = TunedTracker(strings: 2)
        var fired = 0
        var time = 0.0
        func play(_ i: Int, _ c: Double, for seconds: Double) {
            let end = time + seconds
            while time < end { if t.feed(index: i, cents: c, time: time) { fired += 1 }; time += 0.02 }
        }
        play(0, 5, for: 2)
        #expect(!t.isTuned(0))
        play(0, 2, for: 0.9)
        #expect(!t.isTuned(0))
        play(0, 2, for: 0.2)
        #expect(t.isTuned(0) && fired == 0)
        play(1, -1, for: 0.5)
        t.silence()
        play(1, -1, for: 0.6)
        #expect(!t.isTuned(1))
        play(1, -1, for: 0.5)
        #expect(t.isTuned(1) && fired == 1)
        play(0, 1, for: 2)
        #expect(fired == 1)
        #expect(Int(t.cents[1]!.rounded()) == -1)
    }

    @Test("tap tempo averages the last taps and forgets after 2 s")
    func tapTempo() {
        var tt = TapTempo()
        #expect(tt.tap(0) == nil)
        #expect(tt.tap(0.5) == 120)
        #expect(tt.tap(1.0) == 120)
        #expect(tt.tap(1.6) == 113)
        #expect(tt.tap(5) == nil)
        #expect(tt.tap(5.75) == 80)
        var fast = TapTempo()
        _ = fast.tap(0)
        #expect(fast.tap(0.1) == 300)
    }
}
