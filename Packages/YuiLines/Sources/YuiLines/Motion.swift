// A film: `motion [title] [film=] [part=] [+last]`, then scene blocks up to `end`.
//
// The head is an add (preset "motion", props title?, film?, part?, last?). Every line after it, up to a
// line that is only `end`, is the film's own text (`=== scene <name> <seconds> ===` headers over
// JavaScript bodies) and not YL, as a `draw` reads SVG. The `end` (or the end of the reply) gives one patch
// on the motion with `source`: the scene text as written. If the first line after the head is not a scene
// header, the motion stays empty and that line is read as YL. The agent never writes this block: the
// plugin makes it from the agent's one-line ask (spec/MOTION.md section 0.5).
//
// The parser does not read the scenes. MotionFilmSource (the app) splits them and the player runs them.

struct YLMotionReader: Sendable {
    /// A film longer than this is cut: the rest of its lines are dropped, the `end` still closes it.
    static let mostChars = 120_000

    var id: String
    var screen: String
    var src: [String] = []
    var chars = 0
}

extension YLParser {
    /// One line of an open motion. Nil when no motion is open, or this line shows there is no film
    /// (it is then read as YL); `.some(nil)` for a line taken, `.some(node)` for the patch at `end`.
    mutating func motionLine(_ src: String) -> YLNode?? {
        guard var m = mot else { return nil }
        let line = src.hasSuffix("\r") ? String(src.dropLast()) : src
        let t = line.trimmingCharacters(in: .whitespaces)
        if t == "end" { return .some(motionDone(line: line)) }
        if m.src.isEmpty {
            if t.isEmpty { return .some(nil) }
            if !t.hasPrefix("===") { mot = nil; return nil }
        }
        if m.chars + line.count <= YLMotionReader.mostChars {
            m.src.append(line)
            m.chars += line.count + 1
        }
        mot = m
        return .some(nil)
    }

    /// The patch an open motion gives at its end (or at the end of input).
    mutating func motionDone(line: String) -> YLNode? {
        guard let m = mot else { return nil }
        mot = nil
        guard !m.src.isEmpty else { return nil }
        return YLNode(op: .patch, screen: m.screen, target: m.id,
                      props: ["source": .string(m.src.joined(separator: "\n"))], line: line)
    }
}
