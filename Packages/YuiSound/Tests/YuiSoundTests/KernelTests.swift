import AVFoundation
import Darwin
import Foundation
import Testing
@testable import YuiSound

// Kernel tests render SynthKernel directly, no AVAudioEngine. Serialized so
// the allocation count sees no other test's work.

let rate = 48000.0

/// Renders `seconds` of audio into one array (tests only; allocation is fine here).
func renderAll(_ k: SynthKernel, seconds: Double, block: Int = 256) -> [Float] {
    let total = Int(seconds * rate)
    var out = [Float](repeating: 0, count: total)
    out.withUnsafeMutableBufferPointer { b in
        var i = 0
        while i < total {
            let n = min(block, total - i)
            k.render(frames: n, into: b.baseAddress! + i)
            i += n
        }
    }
    return out
}

/// Onsets: the first sample over `threshold` after at least `quiet` quiet samples.
func onsets(_ x: [Float], threshold: Float = 0.002, quiet: Int = 480) -> [Int] {
    var found: [Int] = []
    var run = quiet
    for (i, s) in x.enumerated() {
        if abs(s) > threshold {
            if run >= quiet { found.append(i) }
            run = 0
        } else {
            run += 1
        }
    }
    return found
}

// Counts heap allocations made on one thread through libmalloc's
// `malloc_logger` hook (the one stack logging uses). Every malloc, calloc,
// realloc and Swift object allocation reports through it with the allocate
// bit (2) set, so the count is gross, not net: an alloc followed by a free
// still counts. Only the watched thread counts, so test runner threads do not
// add noise. A positive control proves the hook fires.
typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
nonisolated(unsafe) var allocations = 0
nonisolated(unsafe) var watched: pthread_t?
let countingLogger: MallocLogger = { type, _, _, _, _, _ in
    if type & 2 != 0, let w = watched, pthread_equal(pthread_self(), w) != 0 { allocations += 1 }
}

func withAllocationCount(_ body: () -> Void) -> Int? {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
    let slot = sym.assumingMemoryBound(to: Optional<MallocLogger>.self)
    let saved = slot.pointee
    allocations = 0
    watched = pthread_self()
    slot.pointee = countingLogger
    body()
    slot.pointee = saved
    watched = nil
    return allocations
}

final class Probe { var x = 0 }
nonisolated(unsafe) var sink: AnyObject?

@Suite(.serialized)
struct KernelTests {
    func drift(bpm: Double, swing: Double) -> (maxMs: Double, firstMs: Double, lastMs: Double, count: Int) {
        let k = SynthKernel(sampleRate: rate)
        k.setLoop(rows: [(.tick, -1)], masks: [0xFFFF], steps: 16, bpm: bpm, swing: swing)
        k.startLoop()
        let audio = renderAll(k, seconds: 300)
        let found = onsets(audio)
        // theory.mjs stepTime: a sixteenth per step past 8 steps, swing pushes odd steps late.
        let d = 60 / bpm * 0.25
        var errs: [Double] = []
        for (i, s) in found.enumerated() {
            let ideal = (Double(i) * d + (i % 2 == 1 ? swing / 100 * d * 0.5 : 0)) * rate
            errs.append((Double(s) - ideal) / rate * 1000)
        }
        let expected = Int(300 / d)
        #expect(abs(found.count - expected) <= 1, "onsets \(found.count), expected \(expected)")
        let maxMs = errs.map(abs).max() ?? .infinity
        let first = errs.prefix(16).reduce(0, +) / 16
        let last = errs.suffix(16).reduce(0, +) / 16
        print("drift \(bpm) bpm swing \(swing): \(found.count) onsets over 300 s, max |error| \(String(format: "%.4f", maxMs)) ms, first bar mean \(String(format: "%.4f", first)) ms, last onset error \(String(format: "%.4f", errs.last ?? 0)) ms, last bar mean \(String(format: "%.4f", last)) ms")
        return (maxMs, first, last, found.count)
    }

    @Test("the looper does not drift: 5 minutes at 120 bpm and at 97 bpm swing 30")
    func noDrift() {
        for (bpm, swing) in [(120.0, 0.0), (97.0, 30.0)] {
            let r = drift(bpm: bpm, swing: swing)
            #expect(r.maxMs < 1)
            // No drift: the error at the end is the error at the start, within a sample.
            #expect(abs(r.lastMs) <= abs(r.firstMs) + 1000 / rate)
        }
    }

    @Test("no heap allocation on the render path")
    func noAllocation() throws {
        let k = SynthKernel(sampleRate: rate)
        k.setLoop(rows: [(.kick, -1), (.hat, -1), (.pluck, 60), (.pad, 64)], masks: [0x1111, 0xFFFF, 0x0101, 0x1001], steps: 16, bpm: 128, swing: 20)
        k.startLoop()
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: 256)
        defer { buf.deallocate() }
        for _ in 0..<200 { k.render(frames: 256, into: buf) } // warm up
        // Positive control: the hook sees a Swift allocation on this thread.
        let control = withAllocationCount { sink = Probe() }
        let probeCount = try #require(control, "malloc_logger not found")
        #expect(probeCount >= 1)
        var zone = malloc_statistics_t()
        malloc_zone_statistics(nil, &zone)
        let blocksBefore = zone.blocks_in_use
        var total = 0
        let words: [Recipe] = [.snare, .clap, .keys, .bell, .lead, .bass, .crash, .conga]
        for i in 0..<20_000 {
            if i % 10 == 0 {
                k.noteOn(words[(i / 10) % words.count], midi: 48 + i % 24, velocity: 0.8, hold: 0.3)
            }
            // Keys and chords (step 3): held notes let go by tag, strums scheduled ahead.
            if i % 10 == 5 { k.noteOn(.pad, midi: 60 + i % 12, velocity: 0.7, delay: 0.025, tag: UInt32(i)) }
            if i % 10 == 9 { k.noteOff(tag: UInt32(i - 4)) }
            if i % 2_000 == 0 {
                k.setLoop(rows: [(.kick, -1), (.snare, -1)], masks: [0x1111, UInt32(i / 2_000) | 0x1010], steps: 16, bpm: 100 + Double(i / 2_000), swing: 10)
            }
            total += withAllocationCount { k.render(frames: 256, into: buf) } ?? 0
        }
        malloc_zone_statistics(nil, &zone)
        let blocksDelta = Int(zone.blocks_in_use) - Int(blocksBefore)
        print("allocation: control \(probeCount) allocation(s) seen by the hook; 20000 renders x 256 frames: \(total) allocations on the render thread; zone blocks_in_use delta over the whole loop (includes the producer side) \(blocksDelta)")
        #expect(total == 0)
    }

    @Test("every voice sounds within 50 ms, stays under 1.0 and dies away", arguments: Words.kit + Words.pitched.map { "C4:" + $0 })
    func voices(_ word: String) {
        let k = SynthKernel(sampleRate: rate)
        let (recipe, midi) = word.hasPrefix("C4:") ? Words.resolve("C4", sound: String(word.dropFirst(3))) : Words.resolve(word, sound: "pluck")
        k.noteOn(recipe, midi: midi, velocity: 1)
        let x = renderAll(k, seconds: 10)
        let early = x.prefix(Int(0.05 * rate)).map(abs).max() ?? 0
        let peak = x.map(abs).max() ?? 0
        let tail = x.suffix(Int(0.1 * rate)).map(abs).max() ?? 0
        #expect(early > 0.01, "\(word) early peak \(early)")
        #expect(peak <= 1)
        #expect(tail < 0.001, "\(word) tail \(tail)")
        #expect(!k.dsp.pointee.voices[0].active)
    }

    @Test("sixteen kick, snare and clap hits at once stay under 1.0")
    func sixteenAtOnce() {
        let k = SynthKernel(sampleRate: rate)
        for _ in 0..<16 {
            k.noteOn(.kick, midi: -1, velocity: 1)
            k.noteOn(.snare, midi: -1, velocity: 1)
            k.noteOn(.clap, midi: -1, velocity: 1)
        }
        let x = renderAll(k, seconds: 1)
        let peak = x.map(abs).max() ?? 0
        print("sixteen kick+snare+clap: peak \(peak)")
        #expect(peak <= 1)
        #expect(peak > 0.5)
    }

    @Test("note names and unknown words")
    func notes() {
        #expect(Note.midi("C4") == 60)
        #expect(Note.midi("A4") == 69)
        #expect(Note.midi("F#3") == 54)
        #expect(Note.midi("Bb2") == 46)
        #expect(Note.midi("garbage") == nil)
        #expect(Note.midi("H4") == nil)
        #expect(Note.midi("C") == nil)
        #expect(Words.resolve("theremin", sound: "pluck").0 == .tick)
        #expect(Words.resolve("C4", sound: "theremin") == (.keys, 60))
        #expect(Words.resolve("hihat", sound: "pluck").0 == .hat)
        #expect(Words.resolve("E4", sound: "pad") == (.pad, 64))
        #expect(YuiSound.kit.count == 16)
        #expect(YuiSound.pitched == ["keys", "pluck", "bell", "pad", "bass", "lead"])
        let k = SynthKernel(sampleRate: rate)
        k.noteOn(Words.resolve("nonsense", sound: "nope").0, midi: -1, velocity: 1)
        let x = renderAll(k, seconds: 0.1)
        #expect((x.map(abs).max() ?? 0) > 0.01)
    }

    @Test("world percussion names play real drums, accents or not (YUI-127)")
    func worldPercussion() {
        let want: [String: Recipe] = [
            "surdo": .tom, "Caixa": .snare, "tamborim": .rim, "Ganzá": .shaker, "ganza": .shaker, "Agogô": .cow,
            "repinique": .tom, "Cuíca": .conga, "timbal": .conga, "djembe": .conga, "Cajón": .kick, "Güiro": .shaker,
            "cabasa": .shaker, "triangle": .bell, "woodblock": .rim, "Floor Tom": .tom,
        ]
        for (word, recipe) in want { #expect(Words.sound(word, pitched: false) == recipe, "\(word)") }
    }

    @Test("a samba loop's rows all sound different, and unknown rows never share a voice")
    func sambaRowsSoundApart() {
        let samba = Words.loop(["Surdo", "Caixa", "Tamborim", "Ganzá", "Agogô"], sound: "pluck").map(\.0)
        #expect(samba == [.tom, .snare, .rim, .shaker, .cow])
        let unknown = Words.loop(["kick", "zap", "zing", "C4"], sound: "bell")
        #expect(unknown.map(\.0) == [.kick, .snare, .clap, .bell])
        #expect(unknown[3].1 == 60)
        // Each samba voice, rendered alone, is a different sound.
        let takes = samba.map { r -> [Float] in
            let k = SynthKernel(sampleRate: rate)
            k.noteOn(r, midi: -1, velocity: 1)
            return renderAll(k, seconds: 0.1)
        }
        for i in takes.indices { for j in takes.indices where j > i { #expect(takes[i] != takes[j], "\(samba[i]) and \(samba[j])") } }
        // Past the twelve drums, the rest fall back to tick.
        let full = Words.loop(Words.kit.prefix(12) + ["one", "two"], sound: "pluck").map(\.0)
        #expect(Set(full.prefix(12)).count == 12 && full.suffix(2) == [.tick, .tick])
    }

    @Test("tempo change lands the next step on time and keeps going")
    func tempoChange() {
        let k = SynthKernel(sampleRate: rate)
        k.setLoop(rows: [(.rim, -1)], masks: [0xFFFF], steps: 16, bpm: 120, swing: 0)
        k.startLoop()
        let a = renderAll(k, seconds: 1.01) // 8 steps at 0, 0.125 ... 0.875 s
        k.setLoop(rows: [(.rim, -1)], masks: [0xFFFF], steps: 16, bpm: 60, swing: 0)
        let b = renderAll(k, seconds: 1)
        let found = onsets(a + b)
        #expect(found.count >= 11)
        // Step 8 fired at 1.0 s. Step 9 keeps its old grid time (1.125 s), then 0.25 s steps.
        #expect(abs(found[8] - 48000) <= 3)
        #expect(abs(found[9] - 54000) <= 3)
        #expect(abs(found[10] - 66000) <= 3)
    }
}

@Test("the engine graph renders offline through the source node")
@MainActor
func offlineEngine() throws {
    let graph = SoundGraph(kernel: SynthKernel(sampleRate: rate))
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    do {
        try graph.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
    } catch {
        print("offline rendering unavailable: \(error)")
        return
    }
    graph.build(sampleRate: rate)
    try graph.start()
    graph.kernel.noteOn(.kick, midi: -1, velocity: 1)
    let buffer = AVAudioPCMBuffer(pcmFormat: graph.engine.manualRenderingFormat, frameCapacity: 1024)!
    var peak: Float = 0
    for _ in 0..<10 {
        let status = try graph.engine.renderOffline(1024, to: buffer)
        #expect(status == .success)
        let ch = buffer.floatChannelData![0]
        for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(ch[i])) }
    }
    graph.stop()
    print("offline engine peak \(peak)")
    #expect(peak > 0.05)
}
