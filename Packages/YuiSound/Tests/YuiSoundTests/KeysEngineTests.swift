import Foundation
import Testing
@testable import YuiSound

// Keys and chords on the engine (YUI-116 step 3): a key sounds while the
// finger is down and fades when it lifts; a strum lands its notes 25 ms apart
// on the engine's clock, low first, high first or together.

private func rms(_ x: ArraySlice<Float>) -> Float {
    guard !x.isEmpty else { return 0 }
    return (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
}

@Suite(.serialized)
struct KeysEngineTests {
    @Test("a held key sounds until noteOff, then fades within its release", arguments: ["pad", "bass", "lead", "keys", "pluck", "bell"])
    func heldUntilLetGo(_ sound: String) {
        let k = SynthKernel(sampleRate: rate)
        k.noteOn(Words.sound(sound, pitched: true), midi: 60, velocity: 1, tag: 7)
        let held = renderAll(k, seconds: 1.2)
        let recipe = Words.sound(sound, pitched: true)
        if recipe.isHeld {
            // Still sounding after 1.2 s: nothing lets go but the finger (step 2 cut these at 0.5 s).
            #expect(rms(held[Int(1.1 * rate)...]) > 0.01, "\(sound) stopped while held")
        }
        k.noteOff(tag: 7)
        let after = renderAll(k, seconds: 1.2)
        let fade = Double(recipe.releaseSeconds) * 2 + 0.06
        #expect(rms(after[Int(fade * rate)...]) < 1e-4, "\(sound) rang on after the finger lifted")
        #expect((0..<DSP.voiceCount).allSatisfy { !k.dsp.pointee.voices[$0].active })
    }

    @Test("noteOff lets go of its own note only")
    func onlyItsOwnNote() {
        let k = SynthKernel(sampleRate: rate)
        k.noteOn(.pad, midi: 60, velocity: 1, tag: 1)
        k.noteOn(.pad, midi: 67, velocity: 1, tag: 2)
        _ = renderAll(k, seconds: 0.5)
        k.noteOff(tag: 1)
        _ = renderAll(k, seconds: 1.5)
        let live = (0..<DSP.voiceCount).map { k.dsp.pointee.voices[$0] }.filter(\.active)
        #expect(live.map(\.tag) == [2])
    }

    @Test("a strum lands 25 ms apart: down is low first, up high first, off together", arguments: ["down", "up", "off"])
    func strum(_ way: String) {
        let k = SynthKernel(sampleRate: rate)
        _ = renderAll(k, seconds: 0.1)
        let t0 = k.dsp.pointee.now
        let notes = Theory.chordNotes("G")!
        let order = way == "up" ? Array(notes.reversed()) : notes
        for (i, m) in order.enumerated() {
            k.noteOn(.pluck, midi: m, velocity: 0.75, delay: way == "off" ? 0 : Float(i) * 0.025)
        }
        _ = renderAll(k, seconds: 0.2)
        let voices = (0..<DSP.voiceCount).map { k.dsp.pointee.voices[$0] }.filter(\.active).sorted { $0.start < $1.start }
        #expect(voices.count == notes.count)
        for (i, v) in voices.enumerated() {
            let want = way == "off" ? 0 : Int64((Double(i) * 0.025 * rate).rounded(.down))
            #expect(abs(v.start - t0 - want) <= 1, "\(way): note \(i) at \(v.start - t0)")
            #expect(v.f == Note.hz(order[i]), "\(way): note \(i) out of order")
        }
    }

    @Test("ten fingers on a pad chord stay under 1.0")
    func tenFingers() {
        let k = SynthKernel(sampleRate: rate)
        for (i, m) in [48, 52, 55, 60, 64, 67, 72, 76, 79, 84].enumerated() {
            k.noteOn(.lead, midi: m, velocity: 1, tag: UInt32(i + 1))
        }
        let x = renderAll(k, seconds: 1)
        #expect(x.allSatisfy { abs($0) < 1 })
        #expect(rms(x[...]) > 0.05)
    }
}
