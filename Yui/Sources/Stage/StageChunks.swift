import Foundation
import YuiLines

// Stage first (YUI-119, spec yuigui/spec/YL.md section 5, Stage first): how a
// reply plays on the stage as a run of chunks, a line and one picture each,
// with every question gathered after the last chunk onto one screen and one
// Send. Nothing is new on the wire: this reads the components a reply already
// makes. The reference is `stageChunks` and `textChunks` in yuigui
// site/lib/yl/chunks.mjs; YuiTests/StageChunksTests replays its cases.

/// One thing to read on the stage: a line, and the picture that goes with it.
struct StageChunk: Identifiable, Equatable {
    /// The reply the chunk came from: its message id, which is also its scope.
    let scope: String
    /// Unique in the turn: the reply and the component or paragraph.
    let id: String
    /// The words to read: a `say`, a page's title or a paragraph of plain text.
    var line: String?
    /// A deck's or plan's page, for its body and points.
    var page: YLComponent?
    /// What draws: a group head for sketch, shapes and timeline (the members come from `all`).
    var pic: YLComponent?
    /// The reply's components, so a drawing finds its members.
    var all: [YLComponent] = []
    /// The ideas that share this page (VIS-4): up to 2 more, stacked under this one.
    var more: [StageChunk] = []

    /// Every idea on the page, top to bottom.
    var blocks: [StageChunk] {
        var first = self
        first.more = []
        return [first] + more
    }
    /// The replies whose words are on this page.
    var scopes: Set<String> { Set(blocks.map(\.scope)) }
}

/// A question waiting for the end of the turn.
struct StageQuestion: Identifiable, Equatable {
    let scope: String
    let c: YLComponent
    var all: [YLComponent] = []
    var id: String { "\(scope)#\(c.serial)" }
}

/// What the stage plays for one thing the person said: their words, the chunks
/// of every reply after it, and the questions to ask at the end.
struct StageTurn: Equatable {
    var ask: ChatMessage?
    /// The agent's hello, before anything was said (YUI-167): it plays with no ask.
    var hello = false
    var chunks: [StageChunk] = []
    var questions: [StageQuestion] = []
    /// The plan the questions came from: Send answers its questions as that plan,
    /// and the loose ones as their own events.
    var plan: StageQuestion?
    /// Replies landed for this turn so far (text or screens).
    var replies = 0
    /// A reply came back as nothing but error lines: the turn failed (Stage motion's error).
    var failed = false
    /// The person stopped it (YUI-190): nothing more comes for this turn.
    var stopped = false

    /// The questions screen follows the last chunk.
    var pages: Int { chunks.count + (questions.isEmpty ? 0 : 1) }
}

enum StageChunks {
    /// Ideas on one page (VIS-4, Chris 2026-09-30: "we can put up to 3 ideas on a card, as long as we're showing them").
    static let perPage = 3
    /// Words a page holds before the next idea starts a new one.
    static let pageWords = 60
    /// Drawings that share a page: they scale to the width and stack. A map, a game, a timer or a
    /// form keeps a page of its own.
    static let stackable: Set<String> = ["sketch", "shapes", "chart", "stat", "timeline", "list", "table", "row", "card", "compare", "math", "step"]

    /// Packs a turn's chunks onto pages, up to `perPage` ideas each (mirror: `packPages` in
    /// yuigui site/lib/yl/chunks.mjs). A deck or plan page, and any chunk that is not a line with
    /// a stackable drawing (or a line alone), is a page of its own.
    static func pack(_ chunks: [StageChunk]) -> [StageChunk] {
        var out: [StageChunk] = []
        var words = 0
        for c in chunks {
            let w = c.line.map { $0.split(whereSeparator: \.isWhitespace).count } ?? 0
            if canStack(c), var last = out.last, canStack(last), last.blocks.count < perPage, words + w <= pageWords {
                last.more.append(c)
                out[out.count - 1] = last
                words += w
            } else {
                out.append(c)
                words = canStack(c) ? w : pageWords
            }
        }
        return out
    }

    private static func canStack(_ c: StageChunk) -> Bool {
        guard c.page == nil else { return false }
        if let pic = c.pic { return stackable.contains(pic.preset) }
        return c.line?.isEmpty == false
    }

    /// Things to answer. On the stage they wait for the end, all on one screen.
    static let questions: Set<String> = ["ask", "choose", "pick", "slide", "form", "mic", "camera"]
    /// Groups whose pages become chunks and whose questions join the end.
    static let flows: Set<String> = ["deck", "plan"]

    /// One reply's chunks and questions, in line order.
    static func of(_ yl: YLScreen, scope: String) -> (chunks: [StageChunk], questions: [StageQuestion], plan: YLComponent?) {
        let all = yl.components
        var chunks: [StageChunk] = []
        var qs: [StageQuestion] = []
        var plan: YLComponent?
        // The chunk still waiting for its picture.
        var open: Int?

        func start(_ c: StageChunk) {
            chunks.append(c)
            open = c.pic == nil ? chunks.count - 1 : nil
        }

        // Pages 2 to 12 are the agent's screens, not this turn's story.
        for c in all where c.page == 1 {
            let head = yl.head(of: c)
            // A member of a drawing belongs to the drawing, not to the flow.
            if let head, !flows.contains(head.preset) { continue }
            if flows.contains(c.preset) { open = nil; continue }
            // A deck page you act on (Basil's week, a day a card, each meal a swap, YUI-183): a question
            // with its own title is that page, played in turn, and a tap on it goes at once. A quiz
            // question has no title and still waits for the end.
            if questions.contains(c.preset), head?.preset == "deck", c.string("title") != nil {
                start(StageChunk(scope: scope, id: "\(scope)#\(c.serial)", pic: c, all: all))
                open = nil
                continue
            }
            if questions.contains(c.preset) {
                qs.append(StageQuestion(scope: scope, c: c, all: all))
                if let head, head.preset == "plan" { plan = head }
                continue
            }
            let id = "\(scope)#\(c.serial)"
            switch c.preset {
            case "say":
                start(StageChunk(scope: scope, id: id, line: c.string("text") ?? "", all: all))
            case "page":
                start(StageChunk(scope: scope, id: id, line: c.string("title") ?? "", page: c, all: all))
            default:
                if let i = open {
                    chunks[i].pic = c
                    open = nil
                } else {
                    // A picture with no line before it, or anything else (a timer, a game): a chunk of its own.
                    start(StageChunk(scope: scope, id: id, pic: c, all: all))
                    open = nil
                }
            }
        }
        return (chunks, qs, plan)
    }

    /// Plain chat text on the stage: one chunk per paragraph. A whole thought stays on one
    /// page (SITE-97, YUI-196: "we're almost speaking like a caveman"): up to 3 sentences
    /// and 70 words. Longer splits after every second sentence, so no chunk is a wall.
    /// A paragraph that is markdown (a list, a heading, `Label: value` lines) keeps its
    /// lines: it is one block to read, never flattened into a run of words.
    static func text(_ text: String, most: Int = 70) -> [String] {
        var out: [String] = []
        let paras = text.components(separatedBy: paragraphBreak)
            .map { p -> String in
                let lines = p.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                return lines.count > 1 && isStructured(lines) ? lines.joined(separator: "\n")
                    : p.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            }
            .filter { !$0.isEmpty }
        for para in paras {
            if para.contains("\n") { out.append(para); continue }
            // The deck's splitter: a period inside 0.6.0, a URL or "e.g." ends nothing (YUI-198).
            var sentences = LongText.sentences(para)
            if sentences.isEmpty { sentences = [para] }
            if para.split(separator: " ").count <= most, sentences.count <= 3 { out.append(para); continue }
            for i in stride(from: 0, to: sentences.count, by: 2) {
                out.append(sentences[i..<min(i + 2, sentences.count)].joined(separator: " "))
            }
        }
        return out
    }

    /// Whether lines that share a paragraph are markdown blocks: a list item, a heading
    /// or a `Label: value` line among them.
    private static func isStructured(_ lines: [String]) -> Bool {
        lines.contains { l in
            BubbleMarkdown.match(BubbleMarkdown.bullet, l) != nil || BubbleMarkdown.match(BubbleMarkdown.number, l) != nil
                || BubbleMarkdown.match(BubbleMarkdown.heading, l) != nil
                || { if case .label = ReadingBlock.parse(l).first { return true } else { return false } }()
        }
    }

    private static let paragraphBreak = try! NSRegularExpression(pattern: #"\n\s*\n"#)

    /// The turn that starts at the person's message `ask` (their newest when nil):
    /// every reply after it, up to the next thing they said.
    static func turn(_ messages: [ChatMessage], ask: String?) -> StageTurn {
        guard let i = ask.flatMap({ id in messages.lastIndex { $0.id == id } }) ?? messages.lastIndex(where: \.fromUser)
        else { return StageTurn() }
        var t = StageTurn(ask: messages[i])
        for m in messages[(i + 1)...] {
            if m.fromUser { break }
            if m.home { continue }  // the agent's home is its chips and pages, not part of an answer (YUI-168)
            if m.stopped { t.stopped = true; continue }  // a note in the record, never a chunk (YUI-190)
            add(m, to: &t)
        }
        t.chunks = pack(t.chunks)
        return t
    }

    /// The agent's hello (YUI-167): the first messages of a thread marked as its hello,
    /// up to the first thing the person said. Empty when there is none.
    ///
    /// `from` (YUI-262) is an agent message nobody answered and no hello leads: a reply from another channel
    /// in a thread the person never spoke in. It plays like a hello, from that message on.
    static func hello(_ messages: [ChatMessage], from lead: String? = nil) -> StageTurn {
        var t = StageTurn(hello: true)
        let led = lead.flatMap { id in messages.firstIndex { $0.id == id && !$0.hello } }
        for m in messages[(led ?? 0)...] {
            if m.fromUser { break }
            if led != nil ? !m.home && !m.stopped : m.hello { add(m, to: &t) }
        }
        t.chunks = pack(t.chunks)
        return t
    }

    /// One reply's chunks and questions onto the turn.
    private static func add(_ m: ChatMessage, to t: inout StageTurn) {
        if let yl = m.yl {
            if StageMotion.failed(yl) { t.failed = true }
            let r = of(yl, scope: m.id)
            guard !r.chunks.isEmpty || !r.questions.isEmpty else { return }
            t.replies += 1
            t.chunks += r.chunks
            t.questions += r.questions
            if let p = r.plan { t.plan = StageQuestion(scope: m.id, c: p, all: yl.components)}
        } else {
            let parts = text(m.text)
            guard !parts.isEmpty else { return }
            t.replies += 1
            t.chunks += parts.enumerated().map { StageChunk(scope: m.id, id: "\(m.id)#p\($0.offset)", line: $0.element) }
        }
    }
}

extension NSRegularExpression {
    fileprivate func split(_ s: String) -> [String] {
        let ns = s as NSString
        var out: [String] = []
        var at = 0
        for m in matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: at, length: m.range.location - at)))
            at = m.range.location + m.range.length
        }
        out.append(ns.substring(from: at))
        return out
    }
}

extension String {
    fileprivate func components(separatedBy re: NSRegularExpression) -> [String] { re.split(self) }
}
