import Foundation
import Testing
@testable import YuiSound

// The metronome on the shared clock (MUSIC.md section 8, step 4): against an
// ideal click track for 5 minutes, beside the looper, and through changes.

@Suite(.serialized)
struct MetronomeTests {
    /// Onsets of a click-only render against the ideal click times.
    func errors(_ found: [Int], gap: Double, from start: Double = 0) -> [Double] {
        found.enumerated().map { i, s in (Double(s) - (start + Double(i) * gap)) / rate * 1000 }
    }

    @Test("5 minutes against a click track: every click within 0.1 ms, no drift", arguments: [(120, 1), (72, 3), (97, 2), (180, 4)])
    func clickTrack(bpm: Int, sub: Int) {
        let k = SynthKernel(sampleRate: rate)
        k.setMetronome(bpm: Double(bpm), beats: 4, sub: sub)
        k.startMetronome()
        let audio = renderAll(k, seconds: 300)
        let gap = rate * 60 / Double(bpm) / Double(sub)
        let found = onsets(audio, quiet: min(480, Int(gap * 0.6)))
        let expected = Int(300 * rate / gap) + 1
        #expect(abs(found.count - expected) <= 1, "clicks \(found.count), expected \(expected)")
        let errs = errors(found, gap: gap)
        let maxMs = errs.map(abs).max() ?? .infinity
        print("metronome \(bpm) bpm sub \(sub): \(found.count) clicks over 300 s against the click track, max |error| \(String(format: "%.4f", maxMs)) ms, last \(String(format: "%.4f", errs.last ?? 0)) ms")
        // The detector finds a click 1 to 3 samples into its attack; that
        // offset is fixed, so the bar is 0.1 ms, and the end matches the start.
        #expect(maxMs < 0.1)
        let first = errs.prefix(8).reduce(0, +) / 8, last = errs.suffix(8).reduce(0, +) / 8
        #expect(abs(last - first) <= 1000 / rate)
    }

    @Test("the accent is the bar's first click, beats are louder than subdivisions")
    func accents() {
        let k = SynthKernel(sampleRate: rate)
        k.setMetronome(bpm: 120, beats: 3, sub: 2)
        k.startMetronome()
        let audio = renderAll(k, seconds: 3)
        let found = onsets(audio, quiet: 480)
        let peaks = found.prefix(12).map { s in audio[s..<(s + 240)].map(abs).max()! }
        // Clicks: accent, sub, beat, sub, beat, sub | accent...
        #expect(peaks[0] > peaks[2] && peaks[2] > peaks[1])
        #expect(peaks[6] > peaks[4] && peaks[4] > peaks[5])
    }

    @Test("started over a loop, the first click lands on the loop's next beat")
    func underLoop() {
        let k = SynthKernel(sampleRate: rate)
        k.setLoop(rows: [(.kick, -1)], masks: [0], steps: 16, bpm: 100, swing: 0)
        k.startLoop()
        _ = renderAll(k, seconds: 1.13)
        k.setMetronome(bpm: 100, beats: 4, sub: 1)
        k.startMetronome()
        let audio = renderAll(k, seconds: 4)
        let beat = rate * 60 / 100
        let first = onsets(audio).first!
        let at = Double(first) + 1.13 * rate
        let off = at.truncatingRemainder(dividingBy: beat)
        // Within the detector's 1 to 3 samples of attack.
        #expect(min(off, beat - off) <= 3, "first click \(off) samples off the loop's beat")
    }

    @Test("a loop started under the metronome waits for its next beat")
    func loopUnder() {
        let k = SynthKernel(sampleRate: rate)
        k.setMetronome(bpm: 90, beats: 4, sub: 1)
        k.startMetronome()
        _ = renderAll(k, seconds: 0.5)
        k.setLoop(rows: [(.kick, -1)], masks: [0xFFFF], steps: 16, bpm: 90, swing: 0)
        k.startLoop()
        _ = renderAll(k, seconds: 0.01)
        let start = k.loopStartSample!
        let beat = rate * 60 / 90
        #expect(abs(Double(start) - beat) <= 1)
    }

    @Test("a tempo change keeps the next click and follows the new tempo after it")
    func tempoChange() {
        let k = SynthKernel(sampleRate: rate)
        k.setMetronome(bpm: 120, beats: 4, sub: 1)
        k.startMetronome()
        let a = renderAll(k, seconds: 1.25)
        k.setMetronome(bpm: 60, beats: 4, sub: 1)
        let b = renderAll(k, seconds: 3)
        let found = onsets(a + b)
        // 0, 0.5, 1.0, then 1.5 (already due), then a second apart.
        let times = found.map { Double($0) / rate }
        #expect(times.count >= 5)
        #expect(abs(times[3] - 1.5) < 0.001 && abs(times[4] - 2.5) < 0.001)
    }

    @Test("the UI reads the heard click's place in the bar")
    func tickHistory() {
        let k = SynthKernel(sampleRate: rate)
        k.setMetronome(bpm: 120, beats: 4, sub: 2)
        k.startMetronome()
        _ = renderAll(k, seconds: 1.1)
        // Clicks every 0.25 s: 0 .. 4 fired by 1.1 s; at 1.0 s the fifth (index 4).
        #expect(k.tick(at: Int64(1.0 * rate)) == 4)
        #expect(k.tick(at: Int64(0.3 * rate)) == 1)
        k.stopMetronome()
        _ = renderAll(k, seconds: 0.01)
        #expect(k.metroStartSample == nil)
    }
}
