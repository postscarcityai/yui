import Foundation

// The MIDI side of a take (yuigui spec/MUSIC.md section 3): the notes the
// engine played while it recorded, as a Standard MIDI File any DAW opens.
// Drums go on channel 10 as General MIDI drums; each pitched voice gets its
// own channel and a GM program close to it, so a DAW shows one track per sound.

/// One note of a take, in seconds from the take's start.
public struct TakeNote: Equatable, Sendable {
    public var start: Double
    public var length: Double
    /// MIDI note number.
    public var note: Int
    /// 1...127
    public var velocity: Int
    /// 0-based MIDI channel (9 is drums).
    public var channel: Int

    public init(start: Double, length: Double, note: Int, velocity: Int, channel: Int) {
        self.start = start
        self.length = length
        self.note = note
        self.velocity = velocity
        self.channel = channel
    }
}

enum GM {
    /// The kit in pad order as General MIDI drum notes (channel 10).
    /// kick, snare, clap, hat, open, rim, tom, shaker, crash, cow, snap,
    /// conga, pop, sweep, tick, bell.
    static let drums: [Int] = [36, 38, 39, 42, 46, 37, 45, 70, 49, 56, 54, 63, 76, 55, 33, 53]

    /// Channel and program (0-based) for a pitched voice.
    static func channel(_ r: Recipe) -> (channel: Int, program: Int, name: String) {
        switch r {
        case .keys: (0, 4, "Keys")      // Electric Piano 1
        case .pluck: (1, 24, "Pluck")   // Nylon Guitar
        case .bell: (2, 14, "Bell")     // Tubular Bells
        case .pad: (3, 88, "Pad")       // Pad 1 (new age)
        case .bass: (4, 38, "Bass")     // Synth Bass 1
        case .lead: (5, 81, "Lead")     // Saw Lead
        default: (9, 0, "Drums")
        }
    }

    static func name(channel: Int) -> String {
        channel == 9 ? "Drums" : [Recipe.keys, .pluck, .bell, .pad, .bass, .lead].first { Self.channel($0).channel == channel }
            .map { Self.channel($0).name } ?? "Notes"
    }

    static func program(channel: Int) -> Int? {
        channel == 9 ? nil : [Recipe.keys, .pluck, .bell, .pad, .bass, .lead].first { Self.channel($0).channel == channel }
            .map { Self.channel($0).program }
    }
}

enum TakeNotes {
    /// Engine note events (sample times) to notes from `start`. A note ends
    /// at its noteOff (keys held by a finger), after its hold (a strum, a
    /// loop's note rows), or, for one that just decays, a 16th for a drum
    /// and half a second for a pitched voice. Stops at `end`.
    static func from(_ events: [NoteEvent], start: Int64, end: Int64, sampleRate: Double) -> [TakeNote] {
        var out: [TakeNote] = []
        var open: [UInt32: Int] = [:] // tag -> index in out
        let endS = Double(end - start) / sampleRate
        for e in events.sorted(by: { $0.time < $1.time }) {
            let t = Double(e.time - start) / sampleRate
            if !e.on {
                if let i = open.removeValue(forKey: e.tag) {
                    out[i].length = max(0.01, t - out[i].start)
                }
                continue
            }
            guard e.time >= start, e.time < end, let r = Recipe(rawValue: e.recipe) else { continue }
            let note: Int
            let channel: Int
            if e.midi >= 0 && r.isPitched {
                note = Int(e.midi)
                channel = GM.channel(r).channel
            } else {
                note = GM.drums[min(Int(r.rawValue), GM.drums.count - 1)]
                channel = 9
            }
            guard (0...127).contains(note) else { continue }
            let length: Double
            if e.hold > 0 { length = Double(e.hold) } else if channel == 9 { length = 0.1 } else { length = 0.5 }
            out.append(TakeNote(start: t, length: length, note: note, velocity: max(1, min(127, Int((e.velocity * 127).rounded()))),
                                channel: channel))
            if e.tag != 0 {
                open[e.tag] = out.count - 1
            }
        }
        // Still held when the take stopped: they end with it.
        for i in open.values { out[i].length = max(0.01, endS - out[i].start) }
        for i in out.indices where out[i].start + out[i].length > endS { out[i].length = max(0.01, endS - out[i].start) }
        return out
    }
}

/// Writes a Standard MIDI File, type 1: a tempo track, then one track per
/// channel used, named after its sound.
public enum MIDIFile {
    public static let ppq = 480

    public static func data(_ notes: [TakeNote], bpm: Double, name: String = "Yui take") -> Data {
        let bpm = max(20, min(bpm, 300))
        func ticks(_ s: Double) -> Int { max(0, Int((s * bpm / 60 * Double(ppq)).rounded())) }

        var tracks: [[UInt8]] = []
        // Track 0: name, tempo, 4/4.
        var t0: [(Int, [UInt8])] = []
        t0.append((0, meta(0x03, Array(name.utf8.prefix(64)))))
        let us = Int((60_000_000 / bpm).rounded())
        t0.append((0, meta(0x51, [UInt8(us >> 16 & 0xFF), UInt8(us >> 8 & 0xFF), UInt8(us & 0xFF)])))
        t0.append((0, meta(0x58, [4, 2, 24, 8])))
        tracks.append(encode(t0))

        for ch in Set(notes.map(\.channel)).sorted() {
            var ev: [(Int, [UInt8])] = []
            ev.append((0, meta(0x03, Array(GM.name(channel: ch).utf8))))
            if let p = GM.program(channel: ch) { ev.append((0, [0xC0 | UInt8(ch), UInt8(p)])) }
            // Offs before ons at the same tick, so a repeated note is not cut.
            var timed: [(Int, Int, [UInt8])] = []
            for n in notes where n.channel == ch {
                let on = ticks(n.start)
                let off = max(on + 1, ticks(n.start + n.length))
                timed.append((on, 1, [0x90 | UInt8(ch), UInt8(n.note), UInt8(n.velocity)]))
                timed.append((off, 0, [0x80 | UInt8(ch), UInt8(n.note), 0]))
            }
            timed.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
            ev += timed.map { ($0.0, $0.2) }
            tracks.append(encode(ev))
        }

        var out: [UInt8] = Array("MThd".utf8) + be32(6) + be16(1) + be16(tracks.count) + be16(ppq)
        for t in tracks { out += Array("MTrk".utf8) + be32(t.count) + t }
        return Data(out)
    }

    private static func meta(_ type: UInt8, _ bytes: [UInt8]) -> [UInt8] { [0xFF, type] + vlq(bytes.count) + bytes }

    /// Absolute-tick events to delta times, with the end of track.
    private static func encode(_ events: [(Int, [UInt8])]) -> [UInt8] {
        var out: [UInt8] = []
        var last = 0
        for (t, bytes) in events {
            out += vlq(t - last) + bytes
            last = t
        }
        return out + [0x00, 0xFF, 0x2F, 0x00]
    }

    static func vlq(_ v: Int) -> [UInt8] {
        var v = max(0, v)
        var out: [UInt8] = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 {
            out.insert(UInt8(v & 0x7F) | 0x80, at: 0)
            v >>= 7
        }
        return out
    }

    private static func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    private static func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
}
