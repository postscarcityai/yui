import Foundation

// Keys, scales, roman numerals and chord names (yuigui spec/MUSIC.md section 2).
// The same rules as parseKey, scaleSteps, inScale, romanToChord, chordNotes
// and progression in site/lib/music/theory.mjs, which is the reference: the
// test suite checks this file against a table that module wrote.

public enum Theory {
    static let pcs: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
    static let sharps = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    static let flatNames = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]

    /// A key: a root pitch class and a mode. "C", "F#", "Bb", "Am".
    public struct Key: Equatable, Sendable {
        public let root: Int
        public let minor: Bool
        public let name: String
        /// Flat keys spell with flats: F, Bb, Eb, Ab, Db, Gb and Dm, Gm, Cm, Fm, Bbm, Ebm.
        public let flats: Bool

        public init(_ text: String?) {
            let s = Array((text ?? "C").trimmingCharacters(in: .whitespaces))
            var ok = !s.isEmpty && s.count <= 3
            var i = 1
            var acc: Character?
            var minor = false
            if ok, let pc = pcs[Character(s[0].uppercased())] {
                if i < s.count, s[i] == "#" || s[i] == "b" { acc = s[i]; i += 1 }
                if i < s.count, s[i] == "m" { minor = true; i += 1 }
                ok = i == s.count
                if ok {
                    let shift = acc == "#" ? 1 : acc == "b" ? -1 : 0
                    root = (pc + shift + 12) % 12
                    self.minor = minor
                    name = s[0].uppercased() + (acc.map { String($0) } ?? "") + (minor ? "m" : "")
                    if acc == "b" { flats = true } else if acc == "#" { flats = false } else {
                        let major = minor ? (root + 3) % 12 : root
                        flats = [5, 10, 3, 8, 1, 6].contains(major)
                    }
                    return
                }
            }
            root = 0; self.minor = false; name = "C"; flats = false
        }
    }

    public static let scales = ["major", "minor", "pentatonic", "blues", "dorian", "mixolydian", "chromatic"]

    /// Semitones above the root. Pentatonic and blues follow the key: minor
    /// pentatonic in Am, major pentatonic in C. Unknown words follow the key.
    public static func scaleSteps(_ scale: String, minor: Bool = false) -> [Int] {
        switch scale {
        case "major": [0, 2, 4, 5, 7, 9, 11]
        case "minor": [0, 2, 3, 5, 7, 8, 10]
        case "dorian": [0, 2, 3, 5, 7, 9, 10]
        case "mixolydian": [0, 2, 4, 5, 7, 9, 10]
        case "chromatic": Array(0..<12)
        case "pentatonic": minor ? [0, 3, 5, 7, 10] : [0, 2, 4, 7, 9]
        case "blues": minor ? [0, 3, 5, 6, 7, 10] : [0, 2, 3, 4, 7, 9]
        default: scaleSteps(minor ? "minor" : "major")
        }
    }

    /// Whether a MIDI note is in the key's scale.
    public static func inScale(_ midi: Int, key: Key, scale: String) -> Bool {
        scaleSteps(scale, minor: key.minor).contains(((midi - key.root) % 12 + 12) % 12)
    }

    /// 69 is "A4". Flats when asked, sharps otherwise.
    public static func name(_ midi: Int, flats: Bool = false) -> String {
        let pc = (midi % 12 + 12) % 12
        let octave = Int((Double(midi) / 12).rounded(.down)) - 1
        return (flats ? flatNames : sharps)[pc] + String(octave)
    }

    // MARK: Chords

    static let quality: [String: [Int]] = [
        "": [0, 4, 7], "maj": [0, 4, 7], "m": [0, 3, 7], "min": [0, 3, 7],
        "7": [0, 4, 7, 10], "maj7": [0, 4, 7, 11], "m7": [0, 3, 7, 10], "dim": [0, 3, 6], "dim7": [0, 3, 6, 9],
        "m7b5": [0, 3, 6, 10], "aug": [0, 4, 8], "+": [0, 4, 8], "sus2": [0, 2, 7], "sus4": [0, 5, 7], "sus": [0, 5, 7],
        "6": [0, 4, 7, 9], "m6": [0, 3, 7, 9], "add9": [0, 4, 7, 14], "9": [0, 4, 7, 10, 14], "m9": [0, 3, 7, 10, 14], "5": [0, 7],
    ]

    /// A letter and an optional # or b at the start of `s`: its pitch class and length.
    static func letter(_ s: [Character], at i: Int = 0) -> (pc: Int, len: Int)? {
        guard i < s.count, s[i].isUppercase, let pc = pcs[s[i]] else { return nil }
        if i + 1 < s.count, s[i + 1] == "#" { return ((pc + 1) % 12, 2) }
        if i + 1 < s.count, s[i + 1] == "b" { return ((pc + 11) % 12, 2) }
        return (pc, 1)
    }

    /// "Am" is A C E, "G7" is G B D F, "C/E" puts E in the bass. MIDI notes:
    /// a bass root from E2 to D#3, then the chord with its root from G3 to F#4.
    /// nil when the name does not read.
    public static func chordNotes(_ name: String) -> [Int]? {
        let s = Array(name.trimmingCharacters(in: .whitespaces))
        guard let (root, n) = letter(s) else { return nil }
        var rest = Array(s[n...])
        var bassPc = root
        if let slash = rest.firstIndex(of: "/") {
            let b = Array(rest[(slash + 1)...])
            guard let (pc, len) = letter(b), len == b.count else { return nil }
            bassPc = pc
            rest = Array(rest[..<slash])
        }
        let suffix = String(rest)
        guard suffix.allSatisfy({ ($0.isLowercase && $0.isASCII) || $0.isNumber || $0 == "+" }),
              let steps = quality[suffix] else { return nil }
        let top = 55 + (root - 7 + 12) % 12
        let bass = 40 + (bassPc - 4 + 12) % 12
        return [bass] + steps.map { top + $0 }
    }

    static let romans: [(String, Int)] = [("vii", 6), ("iii", 2), ("vi", 5), ("iv", 3), ("ii", 1), ("v", 4), ("i", 0)]

    /// "V" in C is "G", "vi" is "Am", "bVII" is "Bb", "V7" is "G7", "ii7" is
    /// "Dm7". A plain degree follows the key's own scale, so "VI" in Am is "F".
    /// A b or # counts from the major scale, so "bVII" is "G" in Am and "Bb" in
    /// C. Upper case is major, lower case minor. nil for anything else.
    public static func chord(numeral: String, key: Key) -> String? {
        var s = Substring(numeral.trimmingCharacters(in: .whitespaces))
        var shift = 0
        var accidental: Character?
        if let f = s.first, f == "b" || f == "#" {
            accidental = f
            shift = f == "b" ? -1 : 1
            s = s.dropFirst()
        }
        guard let (word, deg) = romans.first(where: { s.lowercased().hasPrefix($0.0) }) else { return nil }
        let numeralText = s.prefix(word.count)
        let upper = numeralText == numeralText.uppercased()
        let lower = numeralText == numeralText.lowercased()
        guard upper || lower else { return nil }
        let steps = scaleSteps(key.minor && shift == 0 ? "minor" : "major")
        let pc = (key.root + steps[deg] + shift + 12) % 12
        let flats = accidental == "b" || (accidental != "#" && key.flats)
        let root = (flats ? flatNames : sharps)[pc]
        var suffix = String(s.dropFirst(word.count))
        if suffix == "°" || suffix == "o" { suffix = "dim" }
        if lower {
            if suffix == "7" { suffix = "m7" }
            else if suffix.isEmpty { suffix = "m" }
            else if !(suffix.hasPrefix("m") || suffix.hasPrefix("dim")) { suffix = "m" + suffix }
        }
        return root + suffix
    }

    /// One chord button: its name, and the numeral it came from ("" for names).
    public struct Chord: Equatable, Sendable {
        public let name: String
        public let numeral: String
    }

    /// The chords a `chords` line plays: names win, else the progression in the
    /// key, else I V vi IV. A numeral that does not read shows as written.
    public static func progression(key: Key, prog: [String], chords: [String]) -> [Chord] {
        if !chords.isEmpty { return chords.map { Chord(name: $0, numeral: "") } }
        let p = prog.isEmpty ? ["I", "V", "vi", "IV"] : prog
        return p.map { Chord(name: chord(numeral: $0, key: key) ?? $0, numeral: $0) }
    }

    /// The notes a chord button strums: the name, else its root and quality
    /// cut back to a plain triad, else C major.
    public static func strumNotes(_ name: String) -> [Int] {
        if let n = chordNotes(name) { return n }
        let s = Array(name.trimmingCharacters(in: .whitespaces))
        if let (_, len) = letter(s) {
            let root = String(s[..<len])
            let minor = s.count > len && s[len] == "m" && !String(s[len...]).hasPrefix("maj")
            if let n = chordNotes(root + (minor ? "m" : "")) { return n }
        }
        return [48, 60, 64, 67]
    }
}
