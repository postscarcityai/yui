import Accelerate
import Foundation

// The tuner's parts that need no microphone (yuigui spec/MUSIC.md section 6):
// the McLeod pitch method, the tunings table, the nearest string, the
// "held in tune for a second" rule and tap tempo. Same rules as detectPitch,
// tunerStrings, pitchRange, nearestString and nearestNote in
// site/lib/music/theory.mjs.

public enum Pitch {
    /// One reading: the pitch, how periodic the window was (0 to 1) and how loud.
    public struct Reading: Equatable, Sendable {
        public var hz: Double
        public var clarity: Double
        public var rms: Double
    }

    /// McLeod pitch method (McLeod and Wyvill, 2005) over one window: the
    /// normalized squared difference function, the first key peak above `k`
    /// times the highest one, then a parabola through it. Quiet input or low
    /// clarity returns nil, so room noise shows nothing instead of a jumping
    /// needle. `minHz` and `maxHz` clamp the search.
    public static func detect(_ x: UnsafeBufferPointer<Float>, sampleRate: Double, minHz: Double = 30, maxHz: Double = 1500,
                              k: Double = 0.9, minClarity: Double = 0.8, minRms: Double = 0.01) -> Reading? {
        let n = x.count
        guard n > 8, let p = x.baseAddress else { return nil }
        var sum: Float = 0
        vDSP_svesq(p, 1, &sum, vDSP_Length(n))
        let rms = sqrt(Double(sum) / Double(n))
        guard rms >= minRms else { return nil }
        let tauMax = min(Int((sampleRate / minHz).rounded(.up)) + 1, n - 2)
        let tauMin = max(1, Int((sampleRate / maxHz).rounded(.down)))
        guard tauMax > tauMin + 2 else { return nil }
        var nsdf = [Double](repeating: 0, count: tauMax + 2)
        var m = 2 * Double(sum)
        for tau in 0...(tauMax + 1) {
            if tau > 0 { m -= Double(p[tau - 1] * p[tau - 1] + p[n - tau] * p[n - tau]) }
            var r: Float = 0
            vDSP_dotpr(p, 1, p + tau, 1, &r, vDSP_Length(n - tau))
            nsdf[tau] = m > 0 ? 2 * Double(r) / m : 0
        }
        // Key maxima: the highest point of each positive lobe after the curve
        // first goes negative.
        var peaks: [Int] = []
        var t = 1
        while t <= tauMax, nsdf[t] > 0 { t += 1 }
        var best = -1
        while t <= tauMax {
            if nsdf[t] > 0, nsdf[t - 1] <= 0 { best = t }
            if best >= 0, nsdf[t] > nsdf[best] { best = t }
            if best >= 0, nsdf[t] <= 0 || t == tauMax { peaks.append(best); best = -1 }
            t += 1
        }
        let inRange = peaks.filter { $0 >= tauMin }
        guard let top = inRange.map({ nsdf[$0] }).max(),
              let tau = inRange.first(where: { nsdf[$0] >= k * top }) else { return nil }
        let a = nsdf[tau - 1], b = nsdf[tau], c = nsdf[tau + 1]
        let den = a + c - 2 * b
        let shift = den != 0 ? (a - c) / (2 * den) : 0
        let clarity = min(1, b - (a - c) * shift / 4)
        guard clarity >= minClarity else { return nil }
        let hz = sampleRate / (Double(tau) + shift)
        guard hz >= minHz, hz <= maxHz else { return nil }
        return Reading(hz: hz, clarity: clarity, rms: rms)
    }

    public static func detect(_ x: [Float], sampleRate: Double, minHz: Double = 30, maxHz: Double = 1500) -> Reading? {
        x.withUnsafeBufferPointer { detect($0, sampleRate: sampleRate, minHz: minHz, maxHz: maxHz) }
    }

    /// Cents from `target` to `hz`.
    public static func cents(_ hz: Double, _ target: Double) -> Double { 1200 * log2(hz / target) }

    public static func hz(midi: Int, a4: Double = 440) -> Double { a4 * pow(2, Double(midi - 69) / 12) }

    static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// "E2" for 40, sharps only (midiName in theory.mjs).
    public static func name(midi: Int) -> String {
        names[((midi % 12) + 12) % 12] + String(Int((Double(midi) / 12).rounded(.down)) - 1)
    }
}

/// What a tuner line asks for, resolved: the strings, the search range, the
/// window, and whether the named tuning fell back to standard.
public struct Tuning: Equatable, Sendable {
    public static let table: [String: [String: [String]]] = [
        "guitar": [
            "standard": ["E2", "A2", "D3", "G3", "B3", "E4"],
            "dropd": ["D2", "A2", "D3", "G3", "B3", "E4"],
            "dadgad": ["D2", "A2", "D3", "G3", "A3", "D4"],
        ],
        "ukulele": ["standard": ["G4", "C4", "E4", "A4"], "lowg": ["G3", "C4", "E4", "A4"]],
        "bass": ["standard": ["E1", "A1", "D2", "G2"], "five": ["B0", "E1", "A1", "D2", "G2"]],
        "chromatic": ["standard": []],
    ]
    /// Where the pitch search looks, so a guitar never hears its own octave below.
    static let ranges: [String: (Double, Double)] = [
        "guitar": (70, 1000), "ukulele": (150, 1000), "bass": (28, 450), "chromatic": (28, 2000),
    ]
    /// In tune is within 3 cents, under the 5 or 6 most people can hear.
    public static let inTune = 3.0

    public let instrument: String
    /// The tuning as the tuned event names it: the one asked for, "standard"
    /// when it fell back, "custom" for strings=.
    public let tuning: String
    public let strings: [String]
    public let midis: [Int]
    public let a4: Double
    /// True when the line named a tuning we do not know.
    public let fellBack: Bool
    public var custom: Bool { tuning == "custom" }
    public var chromatic: Bool { instrument == "chromatic" && !custom }

    public init(instrument: String? = nil, tuning: String? = nil, strings: [String] = [], a4: Double? = nil) {
        let inst = instrument.map { $0.lowercased() }.flatMap { Self.table[$0] != nil ? $0 : nil } ?? "guitar"
        self.instrument = inst
        let a = a4 ?? 440
        self.a4 = a > 300 && a < 600 ? a : 440
        let given = strings.filter { Note.midi($0) != nil }
        let asked = (tuning ?? "standard").lowercased().filter { $0 != "-" && $0 != " " }
        let t = Self.table[inst]!
        if !given.isEmpty {
            self.strings = given
            self.tuning = "custom"
            fellBack = false
        } else if let known = t[asked] {
            self.strings = known
            self.tuning = asked
            fellBack = false
        } else {
            self.strings = t["standard"]!
            self.tuning = "standard"
            fellBack = true
        }
        midis = self.strings.compactMap(Note.midi)
    }

    /// Samples per pitch window: two periods of the lowest note, rounded up
    /// to a power of two. 2048 for guitar and ukulele, 4096 for bass and chromatic.
    public var window: Int { instrument == "bass" || instrument == "chromatic" ? 4096 : 2048 }

    /// The search range, stretched to fit custom strings.
    public var range: (minHz: Double, maxHz: Double) {
        var (lo, hi) = Self.ranges[instrument] ?? Self.ranges["guitar"]!
        for m in midis {
            let hz = Pitch.hz(midi: m, a4: a4)
            lo = min(lo, hz / 1.12)
            hi = max(hi, hz * 1.5)
        }
        return (lo, hi)
    }

    public func hz(_ string: Int) -> Double { Pitch.hz(midi: midis[string], a4: a4) }

    /// The nearest string to a pitch and how far off it is, or for the
    /// chromatic tuner the nearest of all twelve notes (index -1).
    public func nearest(_ hz: Double) -> (index: Int, note: String, cents: Double) {
        if midis.isEmpty {
            let m = Int((12 * log2(hz / a4) + 69).rounded())
            return (-1, Pitch.name(midi: m), Pitch.cents(hz, Pitch.hz(midi: m, a4: a4)))
        }
        var best = (index: 0, note: strings[0], cents: Double.infinity)
        for (i, m) in midis.enumerated() {
            let c = Pitch.cents(hz, Pitch.hz(midi: m, a4: a4))
            if abs(c) < abs(best.cents) { best = (i, strings[i], c) }
        }
        return best
    }
}

/// A string counts as tuned once it holds within 3 cents for a second. When
/// every string has, `allTuned` goes true once (the tuned event).
public struct TunedTracker: Sendable {
    public let count: Int
    public private(set) var cents: [Int: Double] = [:]
    private var holding = -1
    private var since = 0.0
    private var sent = false

    public init(strings: Int) { count = strings }

    /// Feed one reading (string index and cents, `time` in seconds). Returns
    /// true the one time every string has become tuned.
    public mutating func feed(index: Int, cents c: Double, time: Double) -> Bool {
        guard index >= 0, index < count else { return false }
        if abs(c) > Tuning.inTune || holding != index {
            holding = abs(c) <= Tuning.inTune ? index : -1
            since = time
            return false
        }
        guard time - since >= 1 else { return false }
        cents[index] = c
        guard !sent, cents.count == count else { return false }
        sent = true
        return true
    }

    /// Nothing heard: the hold starts over.
    public mutating func silence() { holding = -1 }

    public func isTuned(_ i: Int) -> Bool { cents[i] != nil }
}

/// Tap tempo: the average gap of the last five taps within 2 s of each other.
public struct TapTempo: Sendable {
    private var taps: [Double] = []
    public init() {}

    /// A tap at `time` seconds. Returns the tempo once there are two taps.
    public mutating func tap(_ time: Double, range: ClosedRange<Int> = 30...300) -> Int? {
        taps = taps.filter { time - $0 < 2 } + [time]
        taps = Array(taps.suffix(5))
        guard taps.count >= 2 else { return nil }
        let gap = (taps.last! - taps.first!) / Double(taps.count - 1)
        guard gap > 0 else { return nil }
        return min(range.upperBound, max(range.lowerBound, Int((60 / gap).rounded())))
    }
}
