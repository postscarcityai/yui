import Foundation
import Synchronization

// The DSP kernel: a voice pool, the looper, the metronome and a limiter on
// one sample clock.
// Pure Swift, no AVAudioEngine, so tests render it directly. The render path
// touches only preallocated pointers and POD values: no allocation, no locks,
// no arrays, strings or dictionaries. Loops are `while`, not `for in`: a
// debug (-Onone) build allocates for each turn of a `for in` range loop.

/// A fixed-size command from the main thread to the render thread.
struct Command {
    enum Kind: UInt8 { case none, noteOn, noteOff, loopRow, loopCommit, loopStart, loopStop, metroSet, metroStart, metroStop }
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
    /// Seconds after the render thread takes it (a strum's later strings).
    var delay: Float = 0
    /// Names a held note so noteOff can find it; 0 for none.
    var tag: UInt32 = 0
    var bpm: Double = 120
    var swing: Double = 0
    /// Pitch in Hz, 0 for the note's own (a4 other than 440, the metronome's tick).
    var hz: Float = 0
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

/// A note the engine started or let go, for the MIDI side of a take (step 5).
struct NoteEvent {
    var time: Int64 = 0
    var midi: Int32 = -1
    var velocity: Float = 0
    /// Seconds until release, < 0 for none (the note decays on its own).
    var hold: Float = -1
    var tag: UInt32 = 0
    var recipe: UInt8 = 0
    /// false: a noteOff for `tag`.
    var on = true
}

/// A lock-free single-producer single-consumer ring the render thread writes
/// note starts into while a take records. It writes nothing when off.
final class NoteLog: @unchecked Sendable {
    static let capacity = 4096
    let buffer: UnsafeMutablePointer<NoteEvent>
    let head = Atomic<Int>(0)
    let tail = Atomic<Int>(0)
    let on = Atomic<Bool>(false)
    /// Notes the ring had no room for (the reader fell behind).
    let dropped = Atomic<Int>(0)

    init() {
        buffer = .allocate(capacity: Self.capacity)
        buffer.initialize(repeating: NoteEvent(), count: Self.capacity)
    }
    deinit { buffer.deallocate() }

    @inline(__always) func push(_ e: NoteEvent) {
        let t = tail.load(ordering: .relaxed)
        if t - head.load(ordering: .acquiring) >= Self.capacity {
            dropped.add(1, ordering: .relaxed)
            return
        }
        buffer[t & (Self.capacity - 1)] = e
        tail.store(t + 1, ordering: .releasing)
    }

    /// Reader side (one thread at a time): everything written so far.
    func drain() -> [NoteEvent] {
        var out: [NoteEvent] = []
        var h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        while h < t {
            out.append(buffer[h & (Self.capacity - 1)])
            h += 1
        }
        head.store(h, ordering: .releasing)
        return out
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

    // The metronome: its own tick grid on the same clock. A tick is one
    // subdivision; tick 0 of each bar is the accent.
    var metro = false
    var metroBpm = 100.0
    var metroBeats = 4
    var metroSub = 1
    var metroGap = 0.0 // samples per tick
    var metroAnchor: Int64 = 0 // the time of tick `metroBase`
    var metroBase: Int64 = 0
    var metroNext: Int64 = 0 // the next tick to fire, counted from the start
    var metroFired = 0
    /// Packed (tick in bar + 1) << 48 | sample time, written for the UI.
    var metroHistory: UnsafeMutablePointer<Atomic<UInt64>>
    var metroStartAt: UnsafeMutablePointer<Atomic<Int64>>
    /// Where note starts go while a take records. unowned(unsafe): the kernel
    /// keeps it alive, and the render thread must not retain or release.
    unowned(unsafe) var notes: NoteLog

    static func stepSamples(sampleRate: Double, bpm: Double, steps: Int) -> Double {
        sampleRate * 60 / bpm * (steps <= 8 ? 0.5 : 0.25)
    }

    mutating func setRate(_ sr: Double) {
        sampleRate = sr
        limRel = Float(exp(-1 / (0.08 * sr)))
        sps = Self.stepSamples(sampleRate: sr, bpm: bpm, steps: steps)
        metroGap = sr * 60 / metroBpm / Double(metroSub)
    }

    @inline(__always) func nextTickTime() -> Int64 {
        metroAnchor + Int64((Double(metroNext - metroBase) * metroGap).rounded())
    }

    /// The first loop beat at or after now, unswung (a beat is 2 steps up to
    /// 8 steps, 4 past that). Lets the metronome start on the loop's beat.
    func nextLoopBeat() -> Int64 {
        let perBeat = Int64(steps <= 8 ? 2 : 4)
        var n = nextN
        if n % perBeat != 0 { n += perBeat - n % perBeat }
        var t = anchor + Int64((Double(n - base) * sps).rounded())
        while t < now {
            n += perBeat
            t = anchor + Int64((Double(n - base) * sps).rounded())
        }
        return t
    }

    /// The first metronome beat at or after now, for a loop that starts under it.
    func nextMetroBeat() -> Int64 {
        var n = metroNext
        let sub = Int64(metroSub)
        if n % sub != 0 { n += sub - n % sub }
        var t = metroAnchor + Int64((Double(n - metroBase) * metroGap).rounded())
        while t < now {
            n += sub
            t = metroAnchor + Int64((Double(n - metroBase) * metroGap).rounded())
        }
        return t
    }

    /// The sample time of step `nextN` (theory.mjs stepTime, from the anchor).
    @inline(__always) func nextStepTime() -> Int64 {
        let swingOffset = pos % 2 == 1 ? swing / 100 * sps * 0.5 : 0
        return anchor + Int64((Double(nextN - base) * sps + swingOffset).rounded())
    }

    mutating func startVoice(_ recipe: Recipe, midi: Int32, velocity: Float, hold: Float, at time: Int64, tag: UInt32 = 0, hz: Float = 0,
                             logged: Bool = true) {
        if logged, notes.on.load(ordering: .relaxed) {
            notes.push(NoteEvent(time: time, midi: midi, velocity: velocity, hold: hold, tag: tag, recipe: recipe.rawValue))
        }
        var slot = 0
        var oldest = Int64.max
        var i = 0
        while i < Self.voiceCount {
            if !voices[i].active { slot = i; break }
            if voices[i].start < oldest { oldest = voices[i].start; slot = i }
            i += 1
        }
        seed = seed &* 1_664_525 &+ 1_013_904_223
        voices[slot].noteOn(recipe, midi: Int(midi), velocity: velocity, hold: hold, sampleRate: Float(sampleRate), at: time, seed: seed, hz: hz)
        voices[slot].tag = tag
    }

    mutating func handle(_ c: Command) {
        switch c.kind {
        case .none: break
        case .noteOn:
            var c = c
            if c.delay > 0 { c.time = now + Int64(Double(c.delay) * sampleRate) }
            if c.time > now, pendingCount < Self.maxPending {
                pending[pendingCount] = c
                pendingCount += 1
            } else {
                startVoice(Recipe(rawValue: c.recipe) ?? .tick, midi: c.midi, velocity: c.velocity, hold: c.hold, at: now, tag: c.tag, hz: c.hz)
            }
        case .noteOff:
            if notes.on.load(ordering: .relaxed) { notes.push(NoteEvent(time: now, tag: c.tag, on: false)) }
            // Let go of the sounding note, and drop it if it has not started yet.
            var i = 0
            while i < Self.voiceCount {
                if voices[i].active, voices[i].tag == c.tag { voices[i].letGo() }
                i += 1
            }
            var p = 0
            while p < pendingCount {
                if pending[p].tag == c.tag {
                    pendingCount -= 1
                    pending[p] = pending[pendingCount]
                } else {
                    p += 1
                }
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
                // Under a running metronome the loop waits for its next beat.
                anchor = metro ? nextMetroBeat() : now
                base = 0
                nextN = 0
                pos = 0
                var i = 0
                while i < Self.historyCount { history[i].store(0, ordering: .relaxed); i += 1 }
                loopStart.pointee.store(anchor, ordering: .relaxed)
            }
        case .loopStop:
            looping = false
            loopStart.pointee.store(-1, ordering: .relaxed)
        case .metroSet:
            let newBpm = max(30, min(c.bpm, 300))
            let newSub = max(1, min(Int(c.steps), 4))
            let newGap = sampleRate * 60 / newBpm / Double(newSub)
            if metro, newGap != metroGap || newSub != metroSub {
                // Keep phase: the next tick stays put, later ones follow the new tempo.
                metroAnchor += Int64((Double(metroNext - metroBase) * metroGap).rounded())
                metroBase = metroNext
                if newSub != metroSub {
                    // A new subdivision lands on the next beat, counted in the new ticks.
                    let beat = (metroNext + Int64(metroSub) - 1) / Int64(metroSub)
                    metroAnchor += Int64((Double(beat * Int64(metroSub) - metroNext) * metroGap).rounded())
                    metroNext = beat * Int64(newSub)
                    metroBase = metroNext
                }
            }
            metroBpm = newBpm
            metroBeats = max(1, min(Int(c.row), 12))
            metroSub = newSub
            metroGap = newGap
        case .metroStart:
            if !metro {
                metro = true
                // Over a running loop the first click lands on the loop's next beat.
                metroAnchor = looping ? nextLoopBeat() : now
                metroBase = 0
                metroNext = 0
                var i = 0
                while i < Self.historyCount { metroHistory[i].store(0, ordering: .relaxed); i += 1 }
                metroStartAt.pointee.store(metroAnchor, ordering: .relaxed)
            }
        case .metroStop:
            metro = false
            metroStartAt.pointee.store(-1, ordering: .relaxed)
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

    /// One click: the accent on the bar's first tick, a softer one on each
    /// beat, softest between beats (music.js Metronome).
    mutating func fireTick(at time: Int64) {
        let perBar = Int64(metroBeats * metroSub)
        let k = Int(metroNext % perBar)
        if k == 0 {
            startVoice(.tick, midi: -1, velocity: 1, hold: -1, at: time, hz: 3000, logged: false)
        } else {
            startVoice(.tick, midi: -1, velocity: k % metroSub == 0 ? 0.65 : 0.3, hold: -1, at: time, hz: 2000, logged: false)
        }
        metroHistory[metroFired % Self.historyCount].store(UInt64(k + 1) << 48 | UInt64(time), ordering: .relaxed)
        metroFired += 1
        metroNext += 1
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
            while metro {
                if nextTickTime() > t { break }
                fireTick(at: t)
            }
            var p = 0
            while p < pendingCount {
                if pending[p].time <= t {
                    let c = pending[p]
                    startVoice(Recipe(rawValue: c.recipe) ?? .tick, midi: c.midi, velocity: c.velocity, hold: c.hold, at: t, tag: c.tag, hz: c.hz)
                    pendingCount -= 1
                    pending[p] = pending[pendingCount]
                } else {
                    p += 1
                }
            }
            // Render up to the next event.
            var end = frames
            if looping { end = min(end, Int(nextStepTime() - now)) }
            if metro { end = min(end, Int(nextTickTime() - now)) }
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
    /// Note starts for a take's MIDI file, written only while `notes.on`.
    let notes = NoteLog()
    let dsp: UnsafeMutablePointer<DSP>
    /// Samples rendered so far.
    let rendered = Atomic<Int64>(0)
    /// Host time and sample time of the last render's first sample (seqlock by host).
    let lastHost = Atomic<UInt64>(0)
    let lastSample = Atomic<Int64>(0)
    let rateBits = Atomic<UInt64>(48000.0.bitPattern)
    let history: UnsafeMutablePointer<Atomic<UInt64>>
    let loopStart: UnsafeMutablePointer<Atomic<Int64>>
    let metroHistory: UnsafeMutablePointer<Atomic<UInt64>>
    let metroStartAt: UnsafeMutablePointer<Atomic<Int64>>
    private let producer = Mutex(())

    init(sampleRate: Double = 48000) {
        history = .allocate(capacity: DSP.historyCount)
        for i in 0..<DSP.historyCount { (history + i).initialize(to: Atomic(0)) }
        loopStart = .allocate(capacity: 1)
        loopStart.initialize(to: Atomic(-1))
        metroHistory = .allocate(capacity: DSP.historyCount)
        for i in 0..<DSP.historyCount { (metroHistory + i).initialize(to: Atomic(0)) }
        metroStartAt = .allocate(capacity: 1)
        metroStartAt.initialize(to: Atomic(-1))
        let voices = UnsafeMutablePointer<Voice>.allocate(capacity: DSP.voiceCount)
        voices.initialize(repeating: Voice(), count: DSP.voiceCount)
        let pending = UnsafeMutablePointer<Command>.allocate(capacity: DSP.maxPending)
        pending.initialize(repeating: Command(), count: DSP.maxPending)
        let staged = UnsafeMutablePointer<LoopRow>.allocate(capacity: DSP.maxRows)
        staged.initialize(repeating: LoopRow(), count: DSP.maxRows)
        let rows = UnsafeMutablePointer<LoopRow>.allocate(capacity: DSP.maxRows)
        rows.initialize(repeating: LoopRow(), count: DSP.maxRows)
        dsp = .allocate(capacity: 1)
        dsp.initialize(to: DSP(sampleRate: sampleRate, voices: voices, pending: pending, staged: staged, rows: rows, history: history, loopStart: loopStart,
                                metroHistory: metroHistory, metroStartAt: metroStartAt, notes: notes))
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
        metroHistory.deinitialize(count: DSP.historyCount)
        metroHistory.deallocate()
        metroStartAt.deinitialize(count: 1)
        metroStartAt.deallocate()
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
        d.pointee.metroAnchor = d.pointee.now
        d.pointee.metroBase = d.pointee.metroNext
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

    func noteOn(_ recipe: Recipe, midi: Int, velocity: Float, hold: Float = -1, at time: Int64 = -1, delay: Float = 0, tag: UInt32 = 0, hz: Float = 0) {
        send(Command(kind: .noteOn, recipe: recipe.rawValue, midi: Int32(midi), velocity: velocity, hold: hold, time: time, delay: delay, tag: tag, hz: hz))
    }

    func noteOff(tag: UInt32) { send(Command(kind: .noteOff, tag: tag)) }

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

    /// Tempo, beats per bar and clicks per beat; lands on the next click while it plays.
    func setMetronome(bpm: Double, beats: Int, sub: Int) {
        send(Command(kind: .metroSet, row: UInt8(max(1, min(beats, 12))), steps: UInt8(max(1, min(sub, 4))), bpm: bpm))
    }
    func startMetronome() { send(Command(kind: .metroStart)) }
    func stopMetronome() { send(Command(kind: .metroStop)) }

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

    /// The metronome's last click at or before sample `t`: its place in the
    /// bar (0 is the accent), or nil.
    func tick(at t: Int64) -> Int? {
        var best: Int64 = -1
        var tick: Int?
        for i in 0..<DSP.historyCount {
            let v = metroHistory[i].load(ordering: .relaxed)
            if v == 0 { continue }
            let time = Int64(v & 0xFFFF_FFFF_FFFF)
            if time <= t, time > best { best = time; tick = Int(v >> 48) - 1 }
        }
        return tick
    }

    /// The metronome's first click in samples, nil when stopped.
    var metroStartSample: Int64? {
        let s = metroStartAt.pointee.load(ordering: .relaxed)
        return s < 0 ? nil : s
    }

    /// The loop's first step time in samples, nil when stopped.
    var loopStartSample: Int64? {
        let s = loopStart.pointee.load(ordering: .relaxed)
        return s < 0 ? nil : s
    }
}
