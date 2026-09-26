import Foundation

// One voice of the pool: a recipe, its phases, envelopes and filters, all
// plain values. The recipes are ports of site/app/playground/music/engine.js
// (itself from synth.py). Nothing here allocates; it runs on the audio thread.

/// engine.js `hit`: a linear rise to `peak` over `att`, then exp(-t / tau).
struct Hit {
    var peak: Float = 0
    var att = 0
    var level: Float = 1
    var mul: Float = 1

    init() {}
    init(_ peak: Float, tau: Float, att: Float = 0.002, sr: Float) {
        self.peak = peak
        self.att = Int((att * sr).rounded())
        mul = tau > 0 ? expf(-1 / (tau * sr)) : 1
    }

    /// Call once per sample with the voice's sample index.
    @inline(__always) mutating func next(_ n: Int) -> Float {
        if n < att { return peak * Float(n) / Float(att) }
        let v = level
        level *= mul
        return peak * v
    }
}

/// A value that falls from `from` to `to` with time constant tau (setTargetAtTime).
struct Glide {
    var to: Float = 0
    var span: Float = 0
    var level: Float = 1
    var mul: Float = 1

    init() {}
    init(from: Float, to: Float, tau: Float, sr: Float) {
        self.to = to
        span = from - to
        mul = expf(-1 / (tau * sr))
    }

    @inline(__always) mutating func next() -> Float {
        let v = to + span * level
        level *= mul
        return v
    }
}

/// A state-variable filter (Simper's TPT form): low, high or band pass.
struct SVF {
    enum Mode: UInt8 { case low, high, band }
    var mode: Mode = .low
    var k: Float = 1.414
    var a1: Float = 0, a2: Float = 0, a3: Float = 0
    var ic1: Float = 0, ic2: Float = 0

    init() {}
    init(_ mode: Mode, _ fc: Float, q: Float = 0.7071, sr: Float) {
        self.mode = mode
        let g = tanf(Float.pi * min(fc, sr * 0.45) / sr)
        k = 1 / q
        a1 = 1 / (1 + g * (g + k))
        a2 = g * a1
        a3 = g * a2
    }

    @inline(__always) mutating func run(_ x: Float) -> Float {
        let v3 = x - ic2
        let v1 = a1 * ic1 + a2 * v3
        let v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        switch mode {
        case .low: return v2
        case .high: return x - k * v1 - v2
        case .band: return k * v1 // unit gain at the center, like Web Audio's bandpass
        }
    }
}

@inline(__always) func sine(_ p: Float) -> Float { sinf(2 * Float.pi * p) }

@inline(__always) func step(_ p: inout Float, _ inc: Float) {
    p += inc
    if p >= 1 || p < 0 { p -= p.rounded(.down) }
}

// PolyBLEP keeps the saw and square from aliasing too much.
@inline(__always) func blep(_ t: Float, _ dt: Float) -> Float {
    if t < dt { let x = t / dt; return x + x - x * x - 1 }
    if t > 1 - dt { let x = (t - 1) / dt; return x * x + x + x + 1 }
    return 0
}

@inline(__always) func saw(_ p: Float, _ dt: Float) -> Float { 2 * p - 1 - blep(p, dt) }

@inline(__always) func square(_ p: Float, _ dt: Float) -> Float {
    var q = p + 0.5
    if q >= 1 { q -= 1 }
    return (p < 0.5 ? 1 : -1) + blep(p, dt) - blep(q, dt)
}

@inline(__always) func triangle(_ p: Float) -> Float { 4 * abs(p - 0.5) - 1 }

/// engine.js `drive`: tanh saturation normalized so full scale stays full scale.
@inline(__always) func drive(_ x: Float, _ k: Float) -> Float { tanhf(x * k) / tanhf(k) }

struct Voice {
    var active = false
    var recipe: Recipe = .tick
    var start: Int64 = 0
    var n = 0
    var len = 0
    var release = Int.max
    var gate: Float = 1
    var gateMul: Float = 1
    var sr: Float = 48000
    var inv: Float = 1.0 / 48000
    var v: Float = 1
    var f: Float = 440
    var p0: Float = 0, p1: Float = 0, p2: Float = 0, p3: Float = 0
    var e0 = Hit(), e1 = Hit(), e2 = Hit(), e3 = Hit()
    var g0 = Glide()
    var f0 = SVF(), f1 = SVF()
    var rng: UInt32 = 0x9E37_79B9
    var aux = 0
    /// The note's name for noteOff (0: none).
    var tag: UInt32 = 0

    @inline(__always) mutating func noise() -> Float {
        rng ^= rng << 13
        rng ^= rng >> 17
        rng ^= rng << 5
        return Float(Int32(bitPattern: rng)) * (1.0 / 2_147_483_648.0)
    }

    /// Sets the voice up for one note. `midi` < 0 plays the recipe's own pitch
    /// (C4 for pitched voices, C5 for the bell on a pad). `hold` is seconds
    /// until release, < 0 for none (held voices then get the pad cap).
    mutating func noteOn(_ r: Recipe, midi: Int, velocity: Float, hold: Float, sampleRate: Float, at time: Int64, seed: UInt32) {
        self = Voice()
        active = true
        recipe = r
        start = time
        sr = sampleRate
        inv = 1 / sampleRate
        v = velocity
        rng = seed | 1
        let s = sampleRate
        let m = midi >= 0 ? midi : (r == .bell || r == .pop ? 72 : 60)
        f = Note.hz(m)
        var seconds: Float = 0.5
        switch r {
        case .kick:
            seconds = 0.7
            g0 = Glide(from: 134, to: 44, tau: 0.045, sr: s)
            e0 = Hit(v, tau: 0.28, sr: s)
            e1 = Hit(0.25 * v, tau: 0.002, att: 0.0005, sr: s)
            aux = Int(0.03 * s)
        case .snare:
            seconds = 0.6
            f0 = SVF(.high, 1200, sr: s); f1 = SVF(.low, 7500, sr: s)
            e0 = Hit(1.4 * v, tau: 0.12, sr: s)
            e1 = Hit(0.8 * v, tau: 0.06, sr: s)
        case .clap:
            seconds = 0.45
            f0 = SVF(.high, 900, sr: s); f1 = SVF(.low, 4200, sr: s)
            e0 = Hit(0.8 * v, tau: 0.09, sr: s)
            e1 = Hit(1.3 * v, tau: 0.008, att: 0, sr: s)
            aux = Int((0.011 * s).rounded())
        case .hat, .open:
            seconds = r == .open ? 0.5 : 0.1
            f0 = SVF(.high, 7000, sr: s)
            e0 = Hit(0.9 * v, tau: r == .open ? 0.08 : 0.018, att: 0.001, sr: s)
        case .rim:
            seconds = 0.1
            f0 = SVF(.high, 400, sr: s)
            e0 = Hit(v, tau: 0.012, att: 0.0005, sr: s)
        case .tom:
            seconds = 0.7
            g0 = Glide(from: 220, to: 110, tau: 0.08, sr: s)
            e0 = Hit(0.9 * v, tau: 0.16, sr: s)
        case .shaker:
            seconds = 0.2
            f0 = SVF(.high, 5500, sr: s)
            e0 = Hit(1.4 * v, tau: 0.035, att: 0.012, sr: s)
        case .crash:
            seconds = 3
            f0 = SVF(.high, 3500, sr: s); f1 = SVF(.low, 14000, sr: s)
            e0 = Hit(0.55 * v, tau: 0.7, sr: s)
        case .cow:
            seconds = 0.4
            f0 = SVF(.band, 900, q: 2, sr: s)
            e0 = Hit(0.5 * v, tau: 0.07, sr: s)
        case .snap:
            seconds = 0.12
            f0 = SVF(.band, 2300, q: 2.5, sr: s)
            e0 = Hit(2.2 * v, tau: 0.014, att: 0.001, sr: s)
            e1 = Hit(0.15 * v, tau: 0.006, sr: s)
        case .conga:
            seconds = 0.5
            f0 = SVF(.band, 1500, q: 1, sr: s)
            e0 = Hit(0.8 * v, tau: 0.1, sr: s)
            e1 = Hit(0.2 * v, tau: 0.004, sr: s)
            aux = Int(0.15 * s)
        case .tick:
            seconds = 0.05
            f = 3000
            e0 = Hit(v, tau: 0.004, att: 0.0005, sr: s)
        case .pop:
            seconds = 0.35
            e0 = Hit(0.8 * v, tau: 0.05, sr: s)
            aux = Int(0.025 * s)
        case .sweep:
            seconds = 0.52
            aux = Int(0.5 * s)
        case .bell:
            seconds = 3
            g0 = Glide(from: 2.2 * f * 3.5, to: 0, tau: 0.25, sr: s)
            e0 = Hit(0.4 * v, tau: 0.55, sr: s)
            e1 = Hit(0.1 * v, tau: 0.3, sr: s)
        case .pluck, .keys:
            let keys = r == .keys
            let slow: Float = keys ? 1.8 : 1
            seconds = keys ? 4 : 1.4
            e0 = Hit(0.45 * v, tau: keys ? 0.7 : 0.14, att: 0.003, sr: s)
            e1 = Hit(0.35, tau: 0.05 * slow, att: 0.001, sr: s)
            e2 = Hit(0.12, tau: 0.03 * slow, att: 0.001, sr: s)
            e3 = Hit(0.06, tau: 0.015 * slow, att: 0.001, sr: s)
        case .pad:
            e0 = Hit(0.3 * v, tau: 0, att: 0.35, sr: s)
            f0 = SVF(.low, 3200, sr: s)
        case .bass:
            e0 = Hit(0.55 * v, tau: 0, att: 0.01, sr: s)
        case .lead:
            e0 = Hit(0.28 * v, tau: 0, att: 0.04, sr: s)
            f0 = SVF(.high, 250, sr: s); f1 = SVF(.low, 2400, sr: s)
            aux = Int(0.25 * s)
        }
        len = Int(seconds * s)
        var holdSeconds = hold
        if r.isHeld {
            // Held voices let go after `hold`, and never ring past 8 s.
            holdSeconds = hold < 0 ? 8 : min(hold, 8)
        }
        if r.isPitched { gateMul = expf(-1 / (r.releaseSeconds / 3 * s)) }
        if r.isPitched, holdSeconds >= 0 {
            let rel = r.releaseSeconds
            release = Int(holdSeconds * s)
            gateMul = expf(-1 / (rel / 3 * s))
            let end = release + Int((rel * 2 + 0.05) * s)
            len = r.isHeld ? end : min(len, end)
        }
    }

    /// The finger lifted: a pitched voice fades over its release from now on,
    /// a drum rings out as it would anyway.
    mutating func letGo() {
        guard recipe.isPitched, n < release else { return }
        release = n
        len = min(len, n + Int((recipe.releaseSeconds * 2 + 0.05) * sr))
    }

    /// One sample.
    @inline(__always) mutating func tick() -> Float {
        let x: Float
        switch recipe {
        case .kick:
            step(&p0, g0.next() * inv)
            let click = e1.next(n)
            let nz = n < aux ? noise() * click : 0
            x = 0.9 * drive(sine(p0) * e0.next(n) + nz, 1.6)
        case .snare:
            let nz = f1.run(f0.run(noise())) * e0.next(n)
            step(&p0, 190 * inv)
            x = 0.8 * drive(nz + sine(p0) * e1.next(n), 1.3)
        case .clap:
            let nf = f1.run(f0.run(noise()))
            if n == aux || n == 2 * aux { e1.level = 1 } // three bursts 11 ms apart
            x = nf * (e1.next(n) + e0.next(n))
        case .hat, .open:
            x = f0.run(noise()) * e0.next(n)
        case .rim:
            step(&p0, 820 * inv)
            x = e0.next(n) * (0.7 * sine(p0) + 0.3 * f0.run(noise()))
        case .tom:
            step(&p0, g0.next() * inv)
            x = drive(sine(p0) * e0.next(n), 1.4)
        case .shaker:
            x = f0.run(noise()) * e0.next(n)
        case .crash:
            x = f1.run(f0.run(noise())) * e0.next(n)
        case .cow:
            let a = square(p0, 540 * inv), b = square(p1, 800 * inv)
            step(&p0, 540 * inv); step(&p1, 800 * inv)
            x = f0.run(a + b) * e0.next(n)
        case .snap:
            step(&p0, 1600 * inv)
            x = f0.run(noise()) * e0.next(n) + sine(p0) * e1.next(n)
        case .conga:
            let fr = n < aux ? 330 * powf(220.0 / 330.0, Float(n) / Float(aux)) : 220
            step(&p0, fr * inv)
            let hitNoise = e1.next(n)
            x = sine(p0) * e0.next(n) + f0.run(noise()) * hitNoise
        case .tick:
            step(&p0, f * inv)
            x = e0.next(n) * (0.6 * sine(p0) + 0.4 * noise())
        case .pop:
            let fr = n < aux ? f * (0.7 + 0.3 * Float(n) / Float(aux)) : f
            step(&p0, fr * inv)
            x = sine(p0) * e0.next(n)
        case .sweep:
            let t = min(Float(n) / Float(aux), 1)
            step(&p0, 300 * powf(8, t) * inv)
            let g = t < 0.5 ? t * 2 : 2 - t * 2
            x = sine(p0) * 0.5 * v * g
        case .bell:
            step(&p1, 3.5 * f * inv)
            step(&p0, (f + g0.next() * sine(p1)) * inv)
            step(&p2, 2 * f * inv)
            x = sine(p0) * e0.next(n) + sine(p2) * e1.next(n)
        case .pluck, .keys:
            let s = sine(p0) + sine(p1) * e1.next(n) + sine(p2) * e2.next(n) + sine(p3) * e3.next(n)
            step(&p0, f * inv); step(&p1, 2 * f * inv); step(&p2, 3 * f * inv); step(&p3, 5 * f * inv)
            x = s * e0.next(n)
        case .pad:
            let s = triangle(p0) + triangle(p1) + triangle(p2)
            step(&p0, f * 0.995965 * inv) // -7 cents
            step(&p1, f * inv)
            step(&p2, f * 1.003472 * inv) // +6 cents
            x = f0.run(s * e0.next(n))
        case .bass:
            step(&p0, f * inv); step(&p1, 2 * f * inv)
            x = drive(sine(p0) + 0.3 * sine(p1), 1.4) * e0.next(n)
        case .lead:
            let depth = 0.004 * f * min(Float(n) / Float(aux), 1)
            step(&p2, 5.2 * inv)
            let fr = f + depth * sine(p2)
            let dt = fr * inv
            let s = 0.5 * saw(p0, dt) + 0.3 * square(p1, dt)
            step(&p0, dt); step(&p1, dt)
            x = f1.run(f0.run(s)) * e0.next(n)
        }
        var y = x
        if n >= release {
            gate *= gateMul
            y *= gate
            if gate < 1e-4 { active = false }
        }
        n += 1
        if n >= len { active = false }
        return y
    }
}
