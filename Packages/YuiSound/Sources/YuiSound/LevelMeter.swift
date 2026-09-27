import Foundation
import Synchronization

// How loud a sound is, and where its energy sits (YUI-125, spec yuigui
// spec/VISUAL.md section 4): the one level feed the visual listens to. The
// mic tap, the music engine's render block and the agent's voice each own
// one. One writer thread measures blocks of samples; any thread reads the
// newest numbers. No locks and no allocation, so the render thread can call
// it. Nothing is kept: four numbers, overwritten each block. Audio never
// leaves the phone.

private let ticksToSeconds: Double = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(info.numer) / Double(info.denom) / 1_000_000_000
}()

public final class LevelMeter: @unchecked Sendable {
    /// Each 0...1: the whole sound, then the lows, the mids and the highs.
    public struct Reading: Equatable, Sendable {
        public var level, low, mid, high: Double
        public init(level: Double, low: Double, mid: Double, high: Double) {
            self.level = level; self.low = low; self.mid = mid; self.high = high
        }
        public static let zero = Reading(level: 0, low: 0, mid: 0, high: 0)
        /// Every number the same: a source that only knows its loudness.
        public static func flat(_ v: Double) -> Reading { Reading(level: v, low: v, mid: v, high: v) }
        /// The louder of two sources.
        public static func louder(_ a: Reading, _ b: Reading) -> Reading { a.level >= b.level ? a : b }
    }

    /// The crossovers: lows under 250 Hz (a kick, a bass, a voice's body), highs over
    /// 2.5 kHz (hats, s and t), mids between. Two one-pole filters, no FFT.
    public static let lowHz = 250.0, highHz = 2500.0
    /// A reading older than this reads as silence: its source stopped.
    public static let stale = 0.25

    /// Filter state, touched only by the writer: lp1, lp2, k1, k2, sample rate.
    private let state: UnsafeMutablePointer<Double>
    /// The four numbers, 16 bits each.
    private let packed = Atomic<UInt64>(0)
    /// mach_absolute_time of the last reading, 0 for never.
    private let stamp = Atomic<UInt64>(0)

    public init() {
        state = .allocate(capacity: 5)
        state.initialize(repeating: 0, count: 5)
    }

    deinit { state.deallocate() }

    /// dB to 0...1, -60...-10 dBFS: a speaking voice sits near the middle (visual.mjs levelOf).
    @inline(__always)
    public static func level(meanSquare: Double) -> Double {
        guard meanSquare.isFinite, meanSquare > 0 else { return 0 }
        let db = 20 * log10(meanSquare.squareRoot() + 1e-9)
        return min(1, max(0, (db + 60) / 50))
    }

    /// Measures one block (the writer's thread only) and makes it the newest reading.
    /// `stride` steps over interleaved channels; the first channel is enough.
    @discardableResult
    public func measure(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Double, stride: Int = 1) -> Reading {
        guard count > 0, sampleRate > 0 else { return .zero }
        if state[4] != sampleRate {
            state[2] = 1 - exp(-2 * Double.pi * Self.lowHz / sampleRate)
            state[3] = 1 - exp(-2 * Double.pi * Self.highHz / sampleRate)
            state[4] = sampleRate
        }
        var lp1 = state[0], lp2 = state[1]
        let k1 = state[2], k2 = state[3]
        var all = 0.0, low = 0.0, mid = 0.0, high = 0.0
        var i = 0
        while i < count {
            let x = Double(samples[i * stride])
            lp1 += k1 * (x - lp1)
            lp2 += k2 * (x - lp2)
            let m = lp2 - lp1, h = x - lp2
            all += x * x; low += lp1 * lp1; mid += m * m; high += h * h
            i += 1
        }
        // A NaN in, or a filter run off to denormals: start clean next block.
        state[0] = lp1.isFinite && abs(lp1) > 1e-20 ? lp1 : 0
        state[1] = lp2.isFinite && abs(lp2) > 1e-20 ? lp2 : 0
        let n = Double(count)
        let r = Reading(level: Self.level(meanSquare: all / n), low: Self.level(meanSquare: low / n),
                        mid: Self.level(meanSquare: mid / n), high: Self.level(meanSquare: high / n))
        publish(r)
        return r
    }

    /// Sets the newest reading directly (a source that has its own numbers).
    public func publish(_ r: Reading) {
        func q(_ v: Double) -> UInt64 { v.isFinite ? UInt64((min(1, max(0, v)) * 65535).rounded()) : 0 }
        packed.store(q(r.level) | q(r.low) << 16 | q(r.mid) << 32 | q(r.high) << 48, ordering: .relaxed)
        stamp.store(mach_absolute_time(), ordering: .releasing)
    }

    /// Forgets the last reading: reads as silence until the next block.
    public func clear() { stamp.store(0, ordering: .releasing) }

    /// The newest reading, or zero when nothing was measured in the last `stale` seconds.
    public func reading(now: UInt64 = mach_absolute_time()) -> Reading {
        let t = stamp.load(ordering: .acquiring)
        guard t != 0, now >= t, Double(now - t) * ticksToSeconds <= Self.stale else { return .zero }
        let p = packed.load(ordering: .relaxed)
        func v(_ shift: UInt64) -> Double { Double((p >> shift) & 0xFFFF) / 65535 }
        return Reading(level: v(0), low: v(16), mid: v(32), high: v(48))
    }
}
