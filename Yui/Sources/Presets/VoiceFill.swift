import Foundation
import YuiLines

/// Speak to fill a form (TestFlight feedback AKNFDrNVFCY4IO44-4fjAnc: "I should be able to just
/// speak in my answers and it fills it out for me"). The words come from PushToTalk, on the
/// phone; this maps them onto the form's fields, also on the phone, so nothing about the form
/// leaves it before Send. Say a field's name and then its answer ("business name is Acme Bakery,
/// what you do is we bake sourdough") and each answer lands in its field. Words before the first
/// field name go to the first empty field; with no field name at all, the first empty text field
/// takes the lot. A choice is found by its option's words, a yes by yes or no. The person checks
/// the filled fields before Next, so a wrong guess is one tap away from fixed.
enum VoiceFill {
    /// A form with something a voice can fill. A photo, a date and a time are not.
    static func canFill(_ fields: [FormField]) -> Bool {
        fields.contains { !skipped.contains($0.type) }
    }

    /// What the words fill, by field key: only the fields the words reached.
    /// `current` is what the fields hold now, so words with no field name go to an empty one.
    static func fill(_ words: String, into fields: [FormField], current: [String: YLValue] = [:]) -> [String: YLValue] {
        let toks = tokens(words)
        guard !toks.isEmpty else { return [:] }
        let live = fields.filter { !skipped.contains($0.type) }

        // Where each field's name is said. Longest names first so "business name" wins over "name".
        var claimed: [(field: FormField, start: Int, end: Int)] = []
        for f in live.sorted(by: { cue($0).count > cue($1).count }) {
            for c in cues(f) {
                guard let at = find(c, in: toks, avoiding: claimed.map { ($0.start, $0.end) }) else { continue }
                claimed.append((f, at, at + c.count))
                break
            }
        }
        claimed.sort { $0.start < $1.start }

        var out: [String: YLValue] = [:]
        for (i, hit) in claimed.enumerated() {
            let stop = i + 1 < claimed.count ? claimed[i + 1].start : toks.count
            let before = hit.start > 0 ? toks[hit.start - 1].norm : ""
            if let v = value(Array(toks[hit.end..<stop]), for: hit.field, before: before) { out[hit.field.key] = v }
        }

        // Words ahead of the first field name, or all of them when no field was named.
        let lead = Array(toks[0..<(claimed.first?.start ?? toks.count)])
        let named = Set(claimed.map(\.field.key))
        let open = live.filter { !named.contains($0.key) }
        if let f = open.first(where: { isText($0) && empty(current[$0.key], $0) }) {
            let body = trimmed(lead, fillers: openers)
            if !body.isEmpty, !(claimed.isEmpty && open.contains(where: { $0.type == "choice" && pick($0, body) != nil })),
               let v = value(body, for: f, before: "") { out[f.key] = v }
        }
        // A choice is heard by its option's words anywhere in what was said.
        for f in open where f.type == "choice" && out[f.key] == nil {
            if let v = pick(f, toks) { out[f.key] = v }
        }
        return out
    }

    // MARK: words

    struct Tok: Equatable {
        /// As said, with its punctuation. Empty for the second half of a contraction.
        let raw: String
        /// Lowercase letters and digits only.
        let norm: String
    }

    /// "it's" is two tokens, `it` and `is`, so a field named "Who it is for" hears "who it's for".
    static func tokens(_ s: String) -> [Tok] {
        var out: [Tok] = []
        for w in s.split(whereSeparator: { $0.isWhitespace }) {
            let raw = String(w)
            let low = raw.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            if low.hasSuffix("'s") || low.hasSuffix("'re") {
                let stem = clean(String(low.prefix(while: { $0 != "'" })))
                let verb = low.hasSuffix("'s") ? "is" : "are"
                if !stem.isEmpty { out.append(Tok(raw: raw, norm: stem)); out.append(Tok(raw: "", norm: verb)); continue }
            }
            let n = clean(low)
            if !n.isEmpty { out.append(Tok(raw: raw, norm: n)) }
        }
        return out
    }

    private static func clean(_ s: String) -> String {
        String(s.filter { $0.isLetter || $0.isNumber })
    }

    private static func cue(_ f: FormField) -> [String] { cues(f).first ?? [] }

    /// The names a field answers to: its label, then its key when that reads differently.
    private static func cues(_ f: FormField) -> [[String]] {
        let a = tokens(f.label).map(\.norm)
        let b = tokens(f.key.replacingOccurrences(of: "_", with: " ")).map(\.norm)
        return [a, b].filter { !$0.isEmpty }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    private static func find(_ cue: [String], in toks: [Tok], avoiding taken: [(Int, Int)]) -> Int? {
        guard !cue.isEmpty, toks.count >= cue.count else { return nil }
        for i in 0...(toks.count - cue.count) {
            guard (0..<cue.count).allSatisfy({ toks[i + $0].norm == cue[$0] }) else { continue }
            if taken.contains(where: { i < $0.1 && i + cue.count > $0.0 }) { continue }
            return i
        }
        return nil
    }

    private static let skipped: Set<String> = ["photo", "date", "time"]
    private static let linkers: Set<String> = ["is", "are", "was", "equals", "be", "would", "should", "colon"]
    private static let openers: Set<String> = ["ok", "okay", "so", "um", "uh", "yeah", "hi", "well", "and"]
    private static let tails: Set<String> = ["and", "then", "next", "also", "um", "uh"]

    private static func isText(_ f: FormField) -> Bool {
        !["choice", "yes", "range", "number"].contains(f.type)
    }

    private static func empty(_ v: YLValue?, _ f: FormField) -> Bool {
        guard let v else { return true }
        return v == .null || (v.string?.trimmingCharacters(in: .whitespaces).isEmpty ?? false)
    }

    /// Drops a run of filler words off the front, and "and"-like ones off the back.
    private static func trimmed(_ t: [Tok], fillers: Set<String>) -> [Tok] {
        var a = t[...]
        while let f = a.first, fillers.contains(f.norm) { a = a.dropFirst() }
        while let l = a.last, tails.contains(l.norm) { a = a.dropLast() }
        return Array(a)
    }

    // MARK: values

    private static func value(_ seg: [Tok], for f: FormField, before: String) -> YLValue? {
        var body = seg
        var lead = 0
        while lead < 2, let t = body.first, linkers.contains(t.norm) { body = Array(body.dropFirst()); lead += 1 }
        body = trimmed(body, fillers: [])
        let text = body.map(\.raw).filter { !$0.isEmpty }.joined(separator: " ")
        switch f.type {
        case "yes":
            let words = Set(body.map(\.norm))
            if !words.isDisjoint(with: ["no", "not", "nope", "without", "none", "dont", "never"]) { return .bool(false) }
            if body.isEmpty { return .bool(!["no", "not", "without", "nope"].contains(before)) }
            return .bool(true)
        case "range":
            return number(body).map { .number(min(max($0.rounded(), f.min), f.max)) }
        case "number":
            return number(body).map { .number($0) }
        case "choice":
            return pick(f, body)
        case "email":
            let s = body.map(\.norm).joined(separator: " ")
            return text.isEmpty ? nil : .string(spoken(s))
        case "url":
            return text.isEmpty ? nil : .string(spoken(body.map(\.norm).joined(separator: " ")))
        case "phone":
            let d = text.filter { $0.isNumber || "+-() ".contains($0) }.trimmingCharacters(in: .whitespaces)
            return d.contains(where: \.isNumber) ? .string(d) : nil
        default:
            guard !text.isEmpty else { return nil }
            var s = text.trimmingCharacters(in: CharacterSet(charactersIn: ",;:"))
            if f.type != "long" && f.type != "voice" { s = s.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:")) }
            return .string(s.prefix(1).uppercased() + s.dropFirst())
        }
    }

    /// "ann at acme dot com" is ann@acme.com.
    private static func spoken(_ s: String) -> String {
        var t = " " + s + " "
        for (said, mark) in [(" at ", "@"), (" dot ", "."), (" slash ", "/"), (" dash ", "-"), (" underscore ", "_")] {
            t = t.replacingOccurrences(of: said, with: mark)
        }
        return t.replacingOccurrences(of: " ", with: "")
    }

    private static let small = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
                                "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20]

    private static func number(_ seg: [Tok]) -> Double? {
        for t in seg {
            if let n = Double(t.norm) { return n }
            if let n = small[t.norm] { return Double(n) }
        }
        // "3.5" and "1,200" lose their marks in `norm`; read the raw words too.
        for t in seg {
            let r = t.raw.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: CharacterSet(charactersIn: ".!?;:$"))
            if let n = Double(r) { return n }
        }
        return nil
    }

    /// The option said in these words: the longest option wins, so "landing page" beats "page".
    private static func pick(_ f: FormField, _ toks: [Tok]) -> YLValue? {
        var best: (String, Int)?
        for o in f.options {
            let words = tokens(o).map(\.norm)
            guard !words.isEmpty, find(words, in: toks, avoiding: []) != nil else { continue }
            if best == nil || words.count > best!.1 { best = (o, words.count) }
        }
        return best.map { .string($0.0) }
    }
}
