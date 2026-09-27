// Sound words and note names (yuigui spec/MUSIC.md section 4). Same rules as
// soundFor and noteToMidi in site/lib/music/theory.mjs. Main thread only:
// these use String and Dictionary, so they never run on the audio thread.

/// Note names to MIDI numbers.
public enum Note {
    /// "C4" is 60, "A4" is 69. Sharps (`#`) and flats (`b`), one octave digit,
    /// optionally negative. Anything else is nil.
    public static func midi(_ name: String) -> Int? {
        let s = Array(name.trimmingCharacters(in: .whitespaces).unicodeScalars)
        guard s.count >= 2 else { return nil }
        let pcs: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        guard let pc = pcs[Character(String(s[0]).uppercased())] else { return nil }
        var i = 1
        var shift = 0
        if s[i] == "#" { shift = 1; i += 1 } else if s[i] == "b" { shift = -1; i += 1 }
        var negative = false
        if i < s.count, s[i] == "-" { negative = true; i += 1 }
        guard i == s.count - 1, let d = Int(String(s[i])) else { return nil }
        let octave = negative ? -d : d
        return 12 * (octave + 1) + pc + shift
    }

    static func hz(_ midi: Int) -> Float { 440 * Float(pow(2.0, Double(midi - 69) / 12)) }
}

import Foundation

/// The voice recipes. Raw values 0...15 are the kit in pad order.
enum Recipe: UInt8 {
    case kick = 0, snare, clap, hat, open, rim, tom, shaker, crash, cow, snap, conga, pop, sweep, tick, bell
    case keys, pluck, pad, bass, lead

    var isPitched: Bool {
        switch self {
        case .bell, .keys, .pluck, .pad, .bass, .lead: true
        default: false
        }
    }

    /// Seconds a released note takes to fade (engine.js releaser).
    var releaseSeconds: Float {
        switch self {
        case .bell: 0.4
        case .pad: 0.5
        case .bass, .lead: 0.08
        default: 0.15
        }
    }

    /// Held voices sound until let go.
    var isHeld: Bool { self == .pad || self == .bass || self == .lead }
}

enum Words {
    static let kit = ["kick", "snare", "clap", "hat", "open", "rim", "tom", "shaker", "crash", "cow", "snap", "conga", "pop", "sweep", "tick", "bell"]
    static let pitched = ["keys", "pluck", "bell", "pad", "bass", "lead"]

    static let recipes: [String: Recipe] = {
        var d: [String: Recipe] = [:]
        for (i, w) in kit.enumerated() { d[w] = Recipe(rawValue: UInt8(i)) }
        d["keys"] = .keys; d["pluck"] = .pluck; d["pad"] = .pad; d["bass"] = .bass; d["lead"] = .lead
        return d
    }()

    // Words agents reach for that mean one of ours (ALIAS in theory.mjs).
    static let alias: [String: String] = [
        "bd": "kick", "bassdrum": "kick", "kickdrum": "kick", "sd": "snare", "snaredrum": "snare", "hh": "hat", "hihat": "hat", "hihats": "hat",
        "closedhat": "hat", "openhat": "open", "oh": "open", "ride": "crash", "cymbal": "crash", "cowbell": "cow", "clave": "rim", "rimshot": "rim",
        "shake": "shaker", "maraca": "shaker", "tambourine": "shaker", "finger": "snap", "click": "tick", "bongo": "conga",
        "piano": "keys", "ep": "keys", "organ": "keys", "rhodes": "keys", "guitar": "pluck", "harp": "pluck", "synth": "lead", "saw": "lead",
        "strings": "pad", "choir": "pad", "sub": "bass", "808": "bass", "chime": "bell", "glock": "bell", "marimba": "bell",
        // World percussion, by the kit voice closest to it.
        "surdo": "tom", "repinique": "tom", "repique": "tom", "floortom": "tom", "taiko": "tom", "dhol": "tom", "tabla": "conga",
        "caixa": "snare", "tarol": "snare", "tamborim": "rim", "woodblock": "rim", "sidestick": "rim", "claves": "rim",
        "ganza": "shaker", "chocalho": "shaker", "guiro": "shaker", "cabasa": "shaker", "afuche": "shaker", "maracas": "shaker", "egg": "shaker",
        "agogo": "cow", "gankogui": "cow", "triangle": "bell", "cuica": "conga", "timbal": "conga", "timbale": "conga",
        "timbales": "conga", "djembe": "conga", "tumba": "conga", "quinto": "conga", "bongos": "conga", "darbuka": "conga", "cajon": "kick",
        "pandeiro": "shaker", "splash": "crash", "china": "crash", "clapping": "clap", "handclap": "clap", "palmas": "clap",
    ]

    /// A word as the lookup reads it: lower case, no accents, no spaces, _ or -.
    static func bare(_ word: String) -> String {
        word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            .filter { $0 != " " && $0 != "_" && $0 != "-" }
    }

    static func known(_ word: String) -> Recipe? {
        let w = bare(word)
        return recipes[w] ?? alias[w].flatMap { recipes[$0] }
    }

    /// The voice for a word. In a pitched slot an unknown word plays keys; on
    /// a pad it plays tick.
    static func sound(_ word: String, pitched: Bool) -> Recipe {
        let r = known(word)
        if let r, !pitched || r.isPitched { return r }
        return pitched ? .keys : (r ?? .tick)
    }

    /// A loop's rows to voices (loopVoices in theory.mjs). A note row plays
    /// `sound`; a known drum word its voice; an unknown one the next kit drum no
    /// other row plays, so two unknown rows never sound the same (tick once all
    /// twelve are taken).
    static func loop(_ rows: [String], sound: String) -> [(Recipe, Int)] {
        let taken = Set(rows.compactMap { Note.midi($0) == nil ? known($0) : nil })
        var free = kit.prefix(12).compactMap { recipes[$0] }.filter { !taken.contains($0) }
        return rows.map { row in
            if Note.midi(row) != nil { return resolve(row, sound: sound) }
            if let r = known(row) { return (r, -1) }
            return (free.isEmpty ? .tick : free.removeFirst(), -1)
        }
    }

    /// A word or note name to a recipe and MIDI note (-1: the voice's own pitch).
    static func resolve(_ word: String, sound: String) -> (Recipe, Int) {
        if let m = Note.midi(word) { return (Self.sound(sound, pitched: true), m) }
        return (Self.sound(word, pitched: false), -1)
    }
}
