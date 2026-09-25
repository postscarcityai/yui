import Foundation
import YuiLines

/// A long plain answer is never a wall in the thread (YUI-79, TestFlight build 82:
/// "I don't want these text bombs"). Past `foldWords` an agent's bubble shows its
/// first sentences and "Read as pages"; the pages are a deck made from the text,
/// one idea per page (YUI-82): list items apart, prose a sentence or two at a time.
enum LongText {
    /// An agent message longer than this folds.
    static let foldWords = 60
    /// About two or three sentences: what the folded bubble shows.
    static let excerptWords = 40
    /// A page holds about this many words. A sentence longer than `hugeWords`
    /// is split at its clauses, then at words; anything shorter stays whole.
    static let pageWords = 40...70
    static let hugeWords = 90

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// Whether an agent's plain text folds in the thread.
    static func folds(_ text: String) -> Bool { wordCount(text) > foldWords }

    /// The first whole sentences, up to `excerptWords`, then an ellipsis. A first
    /// sentence longer than that is cut at a word.
    static func excerpt(_ text: String) -> String {
        let all = sentences(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var out: [String] = []
        var n = 0
        for s in all {
            let w = wordCount(s)
            guard n + w <= excerptWords else { break }
            out.append(s)
            n += w
        }
        // Too little to go on (a short opener before a long sentence): fill with words.
        if n < excerptWords / 2, out.count < all.count {
            let words = all[out.count].split(whereSeparator: \.isWhitespace).prefix(excerptWords - n)
            out.append(trimEnd(words.joined(separator: " ")))
        }
        let joined = out.joined(separator: " ")
        return wordCount(joined) < wordCount(text) ? trimEnd(joined) + "…" : joined
    }

    /// The deck's title: the first sentence, or the words before its colon
    /// ("A2A bridge: add any ..." is "A2A bridge"). A long sentence gives its first
    /// whole clause and "…", never a cut phrase ("with the…", YUI-82). Never empty.
    static func title(_ text: String) -> String {
        guard let first = sentences(text.trimmingCharacters(in: .whitespacesAndNewlines)).first else { return "Message" }
        if let colon = first.firstIndex(of: ":"), (1...6).contains(wordCount(String(first[..<colon]))) {
            return String(first[..<colon]).trimmingCharacters(in: .whitespaces)
        }
        let words = first.split(whereSeparator: \.isWhitespace)
        if words.count <= 12 { return trimEnd(first) }
        if let clause = firstClause(first), (2...9).contains(wordCount(clause)) { return clause + "…" }
        return trimEnd(words.prefix(8).joined(separator: " ")) + "…"
    }

    /// The words before a sentence's first comma, semicolon or dash.
    static func firstClause(_ sentence: String) -> String? {
        let stops = [", ", "; ", " — ", " – ", " - "].compactMap { sentence.range(of: $0)?.lowerBound }
        guard let cut = stops.min() else { return nil }
        let head = String(sentence[..<cut]).trimmingCharacters(in: .whitespaces)
        return head.isEmpty ? nil : head
    }

    // MARK: Story

    /// One page of a story: a headline and the quieter words under it. A page
    /// with no title is a statement: its words are the headline.
    struct Page: Equatable {
        var title: String?
        var body: String?
    }

    /// About this many words on a story page: one idea, read in a glance.
    static let storyWords = 30
    /// A first sentence this short heads its page (a list item's, up to `itemHeadWords`).
    static let headWords = 8
    static let itemHeadWords = 12

    /// The text as a story (YUI-82, TestFlight build 96: "we're telling a story
    /// visually with the letters"), one idea per page: each list item is its own
    /// page, prose goes a sentence or two at a time. A short first sentence, or
    /// the words before an item's colon, heads the page; otherwise the words are
    /// the headline. Nothing is cut: a lead-in that ends in a colon ends in "…"
    /// and the next page picks it up.
    static func story(_ text: String) -> [Page] {
        var out: [Page] = []
        for p in paragraphs(text) {
            var prose: [String] = []
            func flush() {
                guard !prose.isEmpty else { return }
                out += storyProse(prose.joined(separator: " "))
                prose = []
            }
            for line in p.components(separatedBy: "\n") {
                let l = line.trimmingCharacters(in: .whitespaces)
                if let item = listItem(l) {
                    flush()
                    out.append(itemPage(item))
                } else if !l.isEmpty {
                    prose.append(l)
                }
            }
            flush()
        }
        return out
    }

    /// Prose as pages of a sentence or two, broken only between sentences
    /// (a huge sentence at its clauses).
    static func storyProse(_ text: String) -> [Page] {
        let all = sentences(text).flatMap { wordCount($0) > hugeWords ? clauses($0) : [$0] }
        var groups: [[String]] = []
        var n = 0
        for s in all {
            let w = wordCount(s)
            if let last = groups.last, !last.isEmpty, n + w <= storyWords {
                groups[groups.count - 1].append(s)
                n += w
            } else {
                groups.append([s])
                n = w
            }
        }
        return groups.map { ss in
            if ss.count > 1, wordCount(ss[0]) <= headWords, !ss[0].hasSuffix(":") {
                return Page(title: headline(ss[0]), body: lead(ss.dropFirst().joined(separator: " ")))
            }
            return Page(title: nil, body: lead(ss.joined(separator: " ")))
        }
    }

    /// A list item's page: "Head: the rest" and a short first sentence head it.
    static func itemPage(_ item: String) -> Page {
        for sep in [": ", " — ", " – "] {
            if let r = item.range(of: sep) {
                let head = String(item[..<r.lowerBound]), rest = String(item[r.upperBound...])
                if (1...6).contains(wordCount(head)), wordCount(rest) > 0 {
                    return Page(title: head.trimmingCharacters(in: .whitespaces), body: lead(capitalized(rest)))
                }
            }
        }
        let ss = sentences(item)
        if ss.count > 1, wordCount(ss[0]) <= itemHeadWords {
            return Page(title: headline(ss[0]), body: lead(ss.dropFirst().joined(separator: " ")))
        }
        return Page(title: nil, body: lead(item))
    }

    /// The words of a list line ("- a", "•  a", "1. a", "2) a"), or nil for prose.
    static func listItem(_ line: String) -> String? {
        for mark in ["- ", "* ", "+ ", "• "] where line.hasPrefix(mark) {
            return line.dropFirst(mark.count).trimmingCharacters(in: .whitespaces)
        }
        let digits = line.prefix(while: \.isNumber)
        guard (1...2).contains(digits.count) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let mark = rest.first, ".)".contains(mark), rest.dropFirst().first == " " else { return nil }
        return rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
    }

    /// A sentence set as a headline: no closing period (a question keeps its mark).
    private static func headline(_ s: String) -> String {
        var s = s.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix("."), !s.hasSuffix("..") { s.removeLast() }
        return s
    }

    /// Words that lead into the next page ("... deck:") end in "…" instead.
    private static func lead(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.hasSuffix(":") ? String(t.dropLast()) + "…" : t
    }

    private static func capitalized(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    /// The text as pages of about `pageWords`: paragraphs stay together when they
    /// fit, a long one breaks between sentences into even pages, and only a huge
    /// sentence breaks inside, at a clause or a word.
    static func pages(_ text: String) -> [String] {
        var units: [(text: String, paragraph: Bool)] = []
        for p in paragraphs(text) {
            if wordCount(p) <= pageWords.upperBound {
                units.append((p, true))
            } else {
                let pieces = sentences(p).flatMap { wordCount($0) > hugeWords ? clauses($0) : [$0] }
                units += even(pieces, joiner: " ").map { ($0, false) }
            }
        }
        // Short paragraphs share a page; a split paragraph's pages stand alone.
        var out: [String] = []
        var open = false
        for u in units {
            if open, u.paragraph, let last = out.last, wordCount(last) + wordCount(u.text) <= pageWords.upperBound {
                out[out.count - 1] = last + "\n\n" + u.text
            } else {
                out.append(u.text)
            }
            open = u.paragraph
        }
        return out
    }

    /// The deck the pages open as: the same `deck` and `page` components an agent
    /// would send, on the full screen, so the stage, swipe, dots and the X come with it.
    /// One page per idea of the story (YUI-82), each with its own headline.
    static func deck(_ text: String) -> YLScreen {
        var s = YLScreen()
        s.apply(YLNode(op: .add, screen: "full", preset: "deck", id: "pages",
                       props: ["title": .string(title(text))], line: "deck"))
        for (i, p) in story(text).enumerated() {
            var props: [String: YLValue] = [:]
            if let t = p.title { props["title"] = .string(t) }
            if let b = p.body { props["body"] = .string(b) }
            s.apply(YLNode(op: .add, screen: "full", preset: "page", id: "page\(i + 1)", inGroup: "pages",
                           props: props, line: "page"))
        }
        return s
    }

    // MARK: Splitting

    static func paragraphs(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Sentences, each with its own punctuation: a break after `.`, `!` or `?` and
    /// a space, and at every line break. "1.0", "a2a.ts" and "e.g." stay inside.
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            if ch == "\n" {
                push(&out, cur)
                cur = ""
                continue
            }
            cur.append(ch)
            guard ".!?".contains(ch), i + 1 == chars.count || chars[i + 1].isWhitespace else { continue }
            if ch == ".", abbreviation(cur) { continue }
            push(&out, cur)
            cur = ""
        }
        push(&out, cur)
        return out
    }

    /// Words that end in a period without ending the sentence.
    private static let abbreviations: Set<String> = ["e.g.", "i.e.", "etc.", "vs.", "mr.", "mrs.", "ms.", "dr.", "st.", "no."]

    private static func abbreviation(_ s: String) -> Bool {
        guard let last = s.split(whereSeparator: \.isWhitespace).last?.lowercased() else { return false }
        let word = last.trimmingCharacters(in: CharacterSet(charactersIn: "(\"'"))
        // A single letter and a period: an initial ("J. Smith").
        return abbreviations.contains(word) || (word.count == 2 && word.first!.isLetter)
    }

    /// A huge sentence in pieces of at most `pageWords`: at `;`, `:` or `,`, then at words.
    static func clauses(_ sentence: String) -> [String] {
        var parts: [String] = []
        var cur = ""
        for ch in sentence {
            cur.append(ch)
            if ";:,".contains(ch) {
                push(&parts, cur)
                cur = ""
            }
        }
        push(&parts, cur)
        let max = pageWords.upperBound
        let small = parts.flatMap { p -> [String] in
            let words = p.split(whereSeparator: \.isWhitespace).map(String.init)
            guard words.count > max else { return [p] }
            return stride(from: 0, to: words.count, by: max).map { words[$0..<min($0 + max, words.count)].joined(separator: " ") }
        }
        return even(small, joiner: " ")
    }

    /// Pieces packed into as few pages as fit `pageWords`, each about the same size:
    /// 150 words are three pages of 50, not 70, 70 and 10. Each piece goes to the
    /// page its middle word falls on; a page still over the limit breaks again.
    static func even(_ pieces: [String], joiner: String) -> [String] {
        let total = pieces.reduce(0) { $0 + wordCount($1) }
        guard total > 0 else { return [] }
        let count = Int((Double(total) / Double(pageWords.upperBound)).rounded(.up))
        let target = Double(total) / Double(count)
        var groups = Array(repeating: [String](), count: count)
        var start = 0
        for p in pieces {
            let w = wordCount(p)
            groups[min(count - 1, Int((Double(start) + Double(w) / 2) / target))].append(p)
            start += w
        }
        var out: [String] = []
        for g in groups where !g.isEmpty {
            var cur: [String] = []
            var n = 0
            for p in g {
                let w = wordCount(p)
                if !cur.isEmpty, n + w > pageWords.upperBound {
                    out.append(cur.joined(separator: joiner))
                    cur = []
                    n = 0
                }
                cur.append(p)
                n += w
            }
            if !cur.isEmpty { out.append(cur.joined(separator: joiner)) }
        }
        return out
    }

    private static func push(_ out: inout [String], _ s: String) {
        let t = s.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { out.append(t) }
    }

    /// Drops a trailing period, comma or colon (a title, a cut excerpt).
    private static func trimEnd(_ s: String) -> String {
        var s = s.trimmingCharacters(in: .whitespaces)
        while let last = s.last, ".,;:".contains(last) { s.removeLast() }
        return s
    }
}
