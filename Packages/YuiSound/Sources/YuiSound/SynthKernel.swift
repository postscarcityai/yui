import Foundation
import Synchronization

// The DSP kernel: a voice pool, the looper and a limiter on one sample clock.
// Pure Swift, no AVAudioEngine, so tests render it directly. The render path
// touches only preallocated pointers and POD values: no allocation, no locks,
// no arrays, strings or dictionaries. Loops are `while`, not `for in`: a
// debug (-Onone) build allocates for each turn of a `for in` range loop.

/// A fixed-size command from the main thread to the render thread.
struct Command {
    enum Kind: UInt8 { case none, noteOn, loopRow, loopCommit, loopStart, loopStop }
    var kind: Kind = .none
    var recipe: UInt8 = 0
    var row: UInt8 = 0
    var steps: UInt8 = 0
    var midi: Int32 = -1
    var velocity: Float = 1
    /// Seconds until release, < 0 for none.
    var hold: Float = -1
    var mask: UInt32 = 0
    /// Sample time to play at, < 0 for now.
    var time: Int64 = -1
    var bpm: Double = 120
    var swing: Double = 0
}

/// A lock-free single-producer single-consumer ring of commands.
final class CommandRing: @unchecked Sendable {
    static let capacity = 512
    let buffer: UnsafeMutablePointer<Command>
    let head = Atomic<Int>(0) // the consumer's
    let tail = Atomic<Int>(0) // the producer's

    init() {
        buffer = .allocate(capacity: Self.capacity)
        buffer.initialize(repeating: Command(), count: Self.capacity)
    }
    deinit { buffer.deallocate() }

    @discardableResult func push(_ c: Command) -> Bool {
        let t = tail.load(ordering: .relaxed)
        if t - head.load(ordering: .acquiring) >= Self.capacity { return false }
        buffer[t & (Self.capacity - 1)] = c
        tail.store(t + 1, ordering: .releasing)
        return true
    }

    @inline(__always) func pop(_ c: inout Command) -> Bool {
        let h = head.load(ordering: .relaxed)
        if h == tail.load(ordering: .acquiring) { return false }
        c = buffer[h & (Self.capacity - 1)]
        head.store(h + 1, ordering: .releasing)
        return true
    }
}

struct LoopRow {
    var recipe: Recipe = .tick
    var midi: Int32 = -1
    var mask: UInt32 = 0
}

/// Everything the render thread owns, kept behind one pointer.
struct DSP {
    static let voiceCount = 32
    static let maxRows = 32
    static let maxPending = 128
    static let historyCount = 8

    var sampleRate: Double
    var now: Int64 = 0
    var voices: UnsafeMutablePointer<Voice>
    var pending: UnsafeMutablePointer<Command>
    var pendingCount = 0
    var staged: UnsafeMutablePointer<LoopRow>
    var rows: UnsafeMutablePointer<LoopRow>
    var rowCount = 0
    var steps = 16
    var bpm = 120.0
    var swing = 0.0
    var sps = 0.0 // samples per step
    var looping = false
    var anchor: Int64 = 0 // the unswung time of step `base`
    var base: Int64 = 0
    var nextN: Int64 = 0 // the next step to fire, counted from the loop start
    var pos = 0 // its place in the pattern
    var seed: UInt32 = 0x1234_5678
    var limEnv: Float = 0
    var limRel: Float = 0
    var fired = 0
    /// Packed (step + 1) << 48 | sample time, written for the UI.
    var history: UnsafeMutablePointer<Atomic<UInt64>>
    var loopStart: UnsafeMutablePointer<Atomic<Int64>>

    static func stepSamples(sampleRate: Double, bpm: Double, steps: Int) -> Double {
        sampleRate * 60 / bpm * (steps <= 8 ? 0.5 : 0.25)
    }

    mutating func setRate(_ sr: Double) {
        sampleRate = sr
        limRel = Float(exp(-1 / (0.08 * sr)))
        sps = Self.stepSamples(sampleRate: sr, bpm: bpm, steps: steps)
    }

    /// The sample time of step `nextN` (theory.mjs stepTime, from the anchor).
    @inline(__always) func nextStepTime() -> Int64 {
        let swingOffset = pos % 2 == 1 ? swing / 100 * sps * 0.5 : 0
        return anchor + Int64((Double(nextN - base) * sps + swingOffset).rounded())
    }

    mutating func startVoice(_ recipe: Recipe, midi: Int32, velocity: Float, hold: Float, at time: Int64) {
        var slot = 0
        var oldest = Int64.max
        var i = 0
        while i < Self.voiceCount {
            if !voices[i].active { slot = i; break }
            if voices[i].start < oldest { oldest = voices[i].start; slot = i }
            i += 1
        }
        seed = seed &* 1_664_525 &+ 1_013_904_223
        voices[slot].noteOn(recipe, midi: Int(midi), velocity: velocity, hold: hold, sampleRate: Float(sampleRate), at: time, seed: seed)
    }

    mutating func handle(_ c: Command) {
        switch c.kind {
        case .none: break
        case .noteOn:
            if c.time > now, pendingCount < Self.maxPending {
                pending[pendingCount] = c
                pendingCount += 1
            } else {
                startVoice(Recipe(rawValue: c.recipe) ?? .tick, midi: c.midi, velocity: c.velocity, hold: c.hold, at: now)
            }
        case .loopRow:
            if Int(c.row) < Self.maxRows {
                staged[Int(c.row)] = LoopRow(recipe: Recipe(rawValue: c.recipe) ?? .tick, midi: c.midi, mask: c.mask)
            }
        case .loopCommit:
            rowCount = min(Int(c.row), Self.maxRows)
            var i = 0
            while i < rowCount { rows[i] = staged[i]; i += 1 }
            let newSteps = max(1, min(Int(c.steps), 32))
            let newBpm = max(40, min(c.bpm, 240))
            let newSps = Self.stepSamples(sampleRate: sampleRate, bpm: newBpm, steps: newSteps)
            if looping, newSps != sps {
                // Keep phase: the next step stays on its grid time, later steps follow the new tempo.
                anchor += Int64((Double(nextN - base) * sps).rounded())
                base = nextN
            }
            steps = newSteps
            bpm = newBpm
            swing = max(0, min(c.swing, 75))
            sps = newSps
            pos %= steps
        case .loopStart:
            if !looping {
                looping = true
                anchor = now
                base = 0
                nextN = 0
                pos = 0
                var i = 0
                while i < Self.historyCount { history[i].store(0, ordering: .relaxed); i += 1 }
                loopStart.pointee.store(now, ordering: .relaxed)
            }
        case .loopStop:
            looping = false
            loopStart.pointee.store(-1, ordering: .relaxed)
        }
    }

    mutating func fireStep(at time: Int64) {
        let bit = UInt32(1) << UInt32(pos)
        let hold = Float(0.9 * sps / sampleRate)
        var r = 0
        while r < rowCount {
            let row = rows[r]
            if row.mask & bit != 0 {
                startVoice(row.recipe, midi: row.midi, velocity: 0.9, hold: row.recipe.isPitched ? hold : -1, at: time)
            }
            r += 1
        }
        history[fired % Self.historyCount].store(UInt64(pos + 1) << 48 | UInt64(time), ordering: .relaxed)
        fired += 1
        nextN += 1
        pos = (pos + 1) % steps
    }

    mutating func render(frames: Int, into out: UnsafeMutablePointer<Float>) {
        out.update(repeating: 0, count: frames)
        var i = 0
        while i < frames {
            let t = now + Int64(i)
            // Fire what is due at this sample.
            while looping {
                let st = nextStepTime()
                if st > t { break }
                fireStep(at: t)
            }
            var p = 0
            while p < pendingCount {
                if pending[p].time <= t {
                    let c = pending[p]
                    startVoice(Recipe(rawValue: c.recipe) ?? .tick, midi: c.midi, velocity: c.velocity, hold: c.hold, at: t)
                    pendingCount -= 1
                    pending[p] = pending[pendingCount]
                } else {
                    p += 1
                }
            }
            // Render up to the next event.
            var end = frames
            if looping { end = min(end, Int(nextStepTime() - now)) }
            var q = 0
            while q < pendingCount { end = min(end, Int(pending[q].time - now)); q += 1 }
            if end <= i { end = i + 1 }
            let o = out + i
            let count = end - i
            var vi = 0
            while vi < Self.voiceCount {
                let v = voices + vi
                var s = 0
                while s < count, v.pointee.active {
                    o[s] += v.pointee.tick()
                    s += 1
                }
                vi += 1
            }
            i = end
        }
        // Master gain, then a peak limiter with instant attack: never above 0.95.
        let thr: Float = 0.95
        var s = 0
        while s < frames {
            let x = out[s] * 0.8
            let a = abs(x)
            limEnv = max(a, limEnv * limRel)
            var y = limEnv > thr ? x * (thr / limEnv) : x
            y = max(-thr, min(thr, y))
            out[s] = y
            s += 1
        }
        now += Int64(frames)
    }
}

/// The kernel: the render entry point plus the producer side of the ring.
final class SynthKernel: @unchecked Sendable {
    let ring = CommandRing()
    let dsp: UnsafeMutablePointer<DSP>
    /// Samples rendered so far.
    let rendered = Atomic<Int64>(0)
    /// Host time and sample time of the last render's first sample (seqlock by host).
    let lastHost = Atomic<UInt64>(0)
    let lastSample = Atomic<Int64>(0)
    let rateBits = Atomic<UInt64>(48000.0.bitPattern)
    let history: UnsafeMutablePointer<Atomic<UInt64>>
    let loopStart: UnsafeMutablePointer<Atomic<Int64>>
    private let producer = Mutex(())

    init(sampleRate: Double = 48000) {
        history = .allocate(capacity: DSP.historyCount)
        for i in 0..<DSP.historyCount { (history + i).initialize(to: Atomic(0)) }
        loopStart = .allocate(capacity: 1)
        loopStart.initialize(to: Atomic(-1))
        let voices = UnsafeMutablePointer<Voice>.allocate(capacity: DSP.voiceCount)
        voices.initialize(repeating: Voice(), count: DSP.voiceCount)
        let pending = UnsafeMutablePointer<Command>.allocate(capacity: DSP.maxPending)
        pending.initialize(repeating: Command(), count: DSP.maxPending)
        let staged = UnsafeMutablePointer<LoopRow>.allocate(capacity: DSP.maxRows)
        staged.initialize(repeating: LoopRow(), count: DSP.maxRows)
        let rows = UnsafeMutablePointer<LoopRow>.allocate(capacity: DSP.maxRows)
        rows.initialize(repeating: LoopRow(), count: DSP.maxRows)
        dsp = .allocate(capacity: 1)
        dsp.initialize(to: DSP(sampleRate: sampleRate, voices: voices, pending: pending, staged: staged, rows: rows, history: history, loopStart: loopStart))
        dsp.pointee.setRate(sampleRate)
        rateBits.store(sampleRate.bitPattern, ordering: .relaxed)
    }

    deinit {
        dsp.pointee.voices.deallocate()
        dsp.pointee.pending.deallocate()
        dsp.pointee.staged.deallocate()
        dsp.pointee.rows.deallocate()
        dsp.deallocate()
        history.deinitialize(count: DSP.historyCount)
        history.deallocate()
        loopStart.deinitialize(count: 1)
        loopStart.deallocate()
    }

    var sampleRate: Double { Double(bitPattern: rateBits.load(ordering: .relaxed)) }

    // MARK: Render thread

    /// Renders `frames` mono samples. Real-time safe.
    func render(frames: Int, into out: UnsafeMutablePointer<Float>, hostTime: UInt64 = 0) {
        var c = Command()
        while ring.pop(&c) { dsp.pointee.handle(c) }
        let first = dsp.pointee.now
        dsp.pointee.render(frames: frames, into: out)
        lastHost.store(0, ordering: .releasing)
        lastSample.store(first, ordering: .releasing)
        lastHost.store(hostTime, ordering: .releasing)
        rendered.store(first + Int64(frames), ordering: .releasing)
    }

    // MARK: Engine stopped only

    /// A new sample rate, called while nothing renders. Voices stop; a running
    /// loop starts again from the current step.
    func reset(sampleRate: Double) {
        let d = dsp
        for i in 0..<DSP.voiceCount { d.pointee.voices[i].active = false }
        d.pointee.pendingCount = 0
        d.pointee.setRate(sampleRate)
        d.pointee.anchor = d.pointee.now
        d.pointee.base = d.pointee.nextN
        rateBits.store(sampleRate.bitPattern, ordering: .relaxed)
    }

    /// Drops queued note-ons (stale taps from before the engine ran), keeps loop commands.
    func dropStaleNotes() {
        var c = Command()
        while ring.pop(&c) {
            if c.kind != .noteOn { dsp.pointee.handle(c) }
        }
    }

    // MARK: Producer side (any thread; a small lock keeps producers single)

    func send(_ c: Command) { producer.withLock { _ in _ = ring.push(c) } }

    func noteOn(_ recipe: Recipe, midi: Int, velocity: Float, hold: Float = -1, at time: Int64 = -1) {
        send(Command(kind: .noteOn, recipe: recipe.rawValue, midi: Int32(midi), velocity: velocity, hold: hold, time: time))
    }

    func setLoop(rows: [(Recipe, Int)], masks: [UInt32], steps: Int, bpm: Double, swing: Double) {
        let n = min(rows.count, DSP.maxRows)
        producer.withLock { _ in
            for i in 0..<n {
                ring.push(Command(kind: .loopRow, recipe: rows[i].0.rawValue, row: UInt8(i), midi: Int32(rows[i].1), mask: i < masks.count ? masks[i] : 0))
            }
            ring.push(Command(kind: .loopCommit, row: UInt8(n), steps: UInt8(max(1, min(steps, 32))), bpm: bpm, swing: swing))
        }
    }

    func startLoop() { send(Command(kind: .loopStart)) }
    func stopLoop() { send(Command(kind: .loopStop)) }

    // MARK: Reading (any thread)

    /// The last fired step at or before sample `t`, or nil.
    func step(at t: Int64) -> Int? {
        var best: Int64 = -1
        var step: Int?
        for i in 0..<DSP.historyCount {
            let v = history[i].load(ordering: .relaxed)
            if v == 0 { continue }
            let time = Int64(v & 0xFFFF_FFFF_FFFF)
            if time <= t, time > best { best = time; step = Int(v >> 48) - 1 }
        }
        return step
    }

    /// The loop's first step time in samples, nil when stopped.
    var loopStartSample: Int64? {
        let s = loopStart.pointee.load(ordering: .relaxed)
        return s < 0 ? nil : s
    }
}
