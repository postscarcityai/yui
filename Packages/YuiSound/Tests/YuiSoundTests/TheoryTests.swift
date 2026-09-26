import Foundation
import Testing
@testable import YuiSound

// Keys and chords (YUI-116 step 3, yuigui spec/MUSIC.md section 2): every
// numeral form the spec names (upper case, lower case, a b in front, 7, dim,
// sus4) names the right chord in all 12 major and all 12 minor keys. Checked
// two ways: against the reference module's own table (theory-golden.json,
// written by scripts/theory_golden.mjs), and from first principles, so a
// shared mistake in both ports still fails.

struct Golden: Decodable {
    struct Row: Decodable { let key: String; let numeral: String; let name: String; let notes: [Int]? }
    struct Named: Decodable { let name: String; let notes: [Int]? }
    struct KeyRow: Decodable { let key: String; let root: Int; let minor: Bool; let name: String; let flats: Bool }
    let keys: [KeyRow]
    let rows: [Row]
    let chords: [Named]

    static let shared: Golden = {
        let url = Bundle.module.url(forResource: "theory-golden", withExtension: "json")!
        return try! JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }()
}

@Suite struct TheoryTests {
    @Test func keysReadLikeTheReference() {
        #expect(Golden.shared.keys.count == 24)
        for k in Golden.shared.keys {
            let key = Theory.Key(k.key)
            #expect(key.root == k.root && key.minor == k.minor && key.name == k.name && key.flats == k.flats, "\(k.key)")
        }
        #expect(Theory.Key("H") == Theory.Key("C"))
        #expect(Theory.Key("am").name == "Am")
    }

    @Test func everyNumeralMatchesTheReferenceInEveryKey() {
        let rows = Golden.shared.rows
        #expect(rows.count == 24 * 41)
        var wrong: [String] = []
        for r in rows {
            let name = Theory.chord(numeral: r.numeral, key: Theory.Key(r.key))
            if name != r.name { wrong.append("\(r.numeral) in \(r.key): \(name ?? "nil"), want \(r.name)") }
            if Theory.chordNotes(r.name) != r.notes { wrong.append("notes of \(r.name)") }
        }
        #expect(wrong.isEmpty, "\(wrong.prefix(10))")
    }

    /// From first principles: the root counts up the key's own scale (major, or
    /// natural minor), a b or # moves a degree of the major scale, upper case
    /// is a major triad, lower case minor, 7 adds a minor seventh (dominant on
    /// upper case), dim is a diminished triad and sus4 swaps the third for a fourth.
    @Test func everyNumeralNamesTheRightNotesInEveryKey() {
        let major = [0, 2, 4, 5, 7, 9, 11], minor = [0, 2, 3, 5, 7, 8, 10]
        let degrees = ["i", "ii", "iii", "iv", "v", "vi", "vii"]
        var checked = 0
        for k in Golden.shared.keys {
            let key = Theory.Key(k.key)
            for r in Golden.shared.rows where r.key == k.key {
                var s = r.numeral
                var shift = 0
                if s.hasPrefix("b") { shift = -1; s.removeFirst() }
                let word = degrees.sorted { $0.count > $1.count }.first { s.lowercased().hasPrefix($0) }!
                let deg = degrees.firstIndex(of: word)!
                let upper = s.first!.isUppercase
                let suffix = String(s.dropFirst(word.count))
                let root = (key.root + (shift == 0 && key.minor ? minor : major)[deg] + shift + 12) % 12
                let shape: [Int] = switch (suffix, upper) {
                case ("", true): [0, 4, 7]
                case ("", false): [0, 3, 7]
                case ("7", true): [0, 4, 7, 10]
                case ("7", false): [0, 3, 7, 10]
                case ("dim", _): [0, 3, 6]
                case ("sus4", true): [0, 5, 7]
                default: []
                }
                #expect(!shape.isEmpty, "unknown form \(r.numeral)")
                let name = Theory.chord(numeral: r.numeral, key: key) ?? ""
                let notes = Theory.chordNotes(name) ?? []
                #expect(notes.count == shape.count + 1, "\(r.numeral) in \(k.key) is \(name)")
                guard notes.count == shape.count + 1 else { continue }
                // The bass is the root; the chord above it is the shape on the root.
                #expect(notes[0] % 12 == root, "\(r.numeral) in \(k.key): bass of \(name)")
                #expect(notes.dropFirst().map { $0 - notes[1] } == shape, "\(r.numeral) in \(k.key): \(name)")
                #expect(notes[1] % 12 == root, "\(r.numeral) in \(k.key): root of \(name)")
                // The name spells that root.
                let spelled = Theory.Key(String(name.prefix(name.dropFirst().first.map { $0 == "#" || $0 == "b" } == true ? 2 : 1)))
                #expect(spelled.root == root, "\(r.numeral) in \(k.key): \(name) spells the wrong root")
                // A b numeral or a flat key never spells with a sharp; a sharp key's plain numerals never with a flat.
                let acc = name.dropFirst().first
                if shift < 0 || key.flats { #expect(acc != "#", "\(r.numeral) in \(k.key): \(name)") }
                if shift == 0 && !key.flats { #expect(acc != "b", "\(r.numeral) in \(k.key): \(name)") }
                checked += 1
            }
        }
        #expect(checked == 24 * 41)
    }

    @Test func theSpecsExamples() {
        let g = Theory.Key("G"), am = Theory.Key("Am"), c = Theory.Key("C")
        #expect(Theory.progression(key: g, prog: ["I", "V", "vi", "IV"], chords: []).map(\.name) == ["G", "D", "Em", "C"])
        #expect(Theory.progression(key: am, prog: ["i", "bVII", "bVI", "V7"], chords: []).map(\.name) == ["Am", "G", "F", "E7"])
        #expect(Theory.progression(key: Theory.Key("D"), prog: ["I", "V", "vi", "IV"], chords: []).map(\.name) == ["D", "A", "Bm", "G"])
        #expect(Theory.progression(key: c, prog: [], chords: []).map(\.name) == ["C", "G", "Am", "F"])
        #expect(Theory.progression(key: c, prog: [], chords: ["C", "G", "Am", "F"]).map(\.numeral) == ["", "", "", ""])
        #expect(Theory.chord(numeral: "VI", key: am) == "F")
        #expect(Theory.chord(numeral: "bVII", key: c) == "Bb")
        #expect(Theory.chord(numeral: "ii7", key: c) == "Dm7")
        #expect(Theory.chord(numeral: "Vi", key: c) == nil)
        #expect(Theory.chord(numeral: "x", key: c) == nil)
    }

    @Test func chordNamesReadLikeTheReference() {
        for n in Golden.shared.chords {
            #expect(Theory.chordNotes(n.name) == n.notes, "\(n.name)")
        }
        #expect(Theory.strumNotes("Cmaj13") == Theory.chordNotes("C"))
        #expect(Theory.strumNotes("Ebm11") == Theory.chordNotes("Ebm"))
        #expect(Theory.strumNotes("???") == [48, 60, 64, 67])
    }

    @Test func scalesLockTheRightKeys() {
        let c = Theory.Key("C"), am = Theory.Key("Am")
        let white = [60, 62, 64, 65, 67, 69, 71]
        #expect((60..<72).filter { Theory.inScale($0, key: c, scale: "major") } == white)
        #expect((60..<72).filter { Theory.inScale($0, key: am, scale: "minor") } == white)
        #expect((60..<72).filter { Theory.inScale($0, key: am, scale: "pentatonic") } == [60, 62, 64, 67, 69])
        #expect((60..<72).filter { Theory.inScale($0, key: c, scale: "pentatonic") } == [60, 62, 64, 67, 69])
        #expect((60..<72).filter { Theory.inScale($0, key: am, scale: "blues") } == [60, 62, 63, 64, 67, 69])
        #expect((60..<72).allSatisfy { Theory.inScale($0, key: c, scale: "chromatic") })
        #expect(Theory.name(69) == "A4" && Theory.name(70, flats: true) == "Bb4" && Theory.name(61) == "C#4")
    }
}
