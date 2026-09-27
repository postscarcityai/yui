import Foundation
import Testing
@testable import YuiSound

/// The level feed the visual listens to (YUI-125): one meter, three bands.
@Suite(.serialized)
struct MeterTests {
    static let sr = 48_000.0

    func sine(_ hz: Double, amp: Double = 0.3, seconds: Double = 0.2) -> [Float] {
        (0..<Int(seconds * Self.sr)).map { Float(amp * sin(2 * .pi * hz * Double($0) / Self.sr)) }
    }

    func read(_ x: [Float], blocks: Int = 1024) -> LevelMeter.Reading {
        let m = LevelMeter()
        var r = LevelMeter.Reading.zero
        x.withUnsafeBufferPointer { p in
            var i = 0
            while i < p.count {
                let n = min(blocks, p.count - i)
                r = m.measure(p.baseAddress! + i, count: n, sampleRate: Self.sr)
                i += n
            }
        }
        return r
    }

    @Test("a low hum lands in the lows, a voice's middle in the mids, a hiss in the highs")
    func bands() {
        let lo = read(sine(80)), mid = read(sine(900)), hi = read(sine(8000))
        print("80 Hz \(lo)\n900 Hz \(mid)\n8 kHz \(hi)")
        #expect(lo.low > lo.mid && lo.low > lo.high)
        #expect(mid.mid > mid.low && mid.mid > mid.high)
        #expect(hi.high > hi.low && hi.high > hi.mid)
        // The whole level only depends on loudness, not pitch.
        #expect(abs(lo.level - hi.level) < 0.02)
    }

    @Test("the level is visual.mjs levelOf: -60...-10 dBFS to 0...1")
    func level() {
        // A sine's RMS is amp / sqrt 2. amp 0.3 -> -13.5 dBFS -> 0.93.
        let r = read(sine(440, amp: 0.3))
        #expect(abs(r.level - (20 * log10(0.3 / 2.0.squareRoot()) + 60) / 50) < 0.01)
        #expect(read([Float](repeating: 0, count: 4096)).level == 0)
        #expect(read(sine(440, amp: 1)).level == 1)
        #expect(LevelMeter.level(meanSquare: .nan) == 0)
    }

    @Test("a source that stopped reads as silence")
    func stale() throws {
        let m = LevelMeter()
        let x = sine(440)
        x.withUnsafeBufferPointer { _ = m.measure($0.baseAddress!, count: 1024, sampleRate: Self.sr) }
        #expect(m.reading().level > 0.5)
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let later = mach_absolute_time() + UInt64(0.3 * 1e9 * Double(info.denom) / Double(info.numer))
        #expect(m.reading(now: later) == .zero)
        m.clear()
        #expect(m.reading() == .zero)
        m.publish(.flat(0.5))
        #expect(abs(m.reading().mid - 0.5) < 0.001)
    }

    @Test("a NaN block does not stick")
    func nan() {
        let m = LevelMeter()
        var x = sine(440)
        x[10] = .nan
        x.withUnsafeBufferPointer { _ = m.measure($0.baseAddress!, count: 1024, sampleRate: Self.sr) }
        let r = sine(440).withUnsafeBufferPointer { m.measure($0.baseAddress!, count: 1024, sampleRate: Self.sr) }
        #expect(r.low.isFinite && r.mid.isFinite && r.high.isFinite)
    }

    @Test("measuring allocates nothing (it runs on the render thread)")
    func noAllocation() throws {
        let m = LevelMeter()
        let x = sine(440, seconds: 1)
        let control = withAllocationCount { sink = Probe() }
        #expect(try #require(control) >= 1)
        var total = 0
        x.withUnsafeBufferPointer { p in
            for i in 0..<2_000 {
                total += withAllocationCount {
                    m.measure(p.baseAddress! + (i * 256) % 40_000, count: 256, sampleRate: Self.sr)
                    _ = m.reading()
                } ?? 0
            }
        }
        print("meter: 2000 blocks x 256 frames, \(total) allocations")
        #expect(total == 0)
    }

    @Test("the engine's render block feeds the meter")
    func renderFeedsMeter() {
        let k = SynthKernel(sampleRate: Self.sr)
        let m = LevelMeter()
        k.setLoop(rows: [(.kick, -1)], masks: [0xFFFF], steps: 16, bpm: 120, swing: 0)
        k.startLoop()
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        defer { buf.deallocate() }
        var peakLow = 0.0, peakHigh = 0.0
        for _ in 0..<200 {
            k.render(frames: 512, into: buf)
            let r = m.measure(buf, count: 512, sampleRate: Self.sr)
            peakLow = max(peakLow, r.low); peakHigh = max(peakHigh, r.high)
        }
        print("kick loop: peak low \(peakLow), peak high \(peakHigh)")
        #expect(peakLow > 0.5)
        #expect(peakLow > peakHigh)
    }
}
