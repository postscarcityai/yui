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

    /// The questions screen follows the last chunk.
    var pages: Int { chunks.count + (questions.isEmpty ? 0 : 1) }
}

enum StageChunks {
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

    /// Plain chat text on the stage: one chunk per paragraph, and a long
    /// paragraph split after every second sentence, so no chunk is a wall.
    static func text(_ text: String, most: Int = 40) -> [String] {
        var out: [String] = []
        let paras = text.components(separatedBy: paragraphBreak)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
        for para in paras {
            if para.split(separator: " ").count <= most { out.append(para); continue }
            let ns = para as NSString
            var sentences = sentence.matches(in: para, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
            if sentences.isEmpty { sentences = [para] }
            for i in stride(from: 0, to: sentences.count, by: 2) {
                out.append(sentences[i..<min(i + 2, sentences.count)].joined().trimmingCharacters(in: .whitespaces))
            }
        }
        return out
    }

    private static let paragraphBreak = try! NSRegularExpression(pattern: #"\n\s*\n"#)
    private static let sentence = try! NSRegularExpression(pattern: #"[^.!?]+[.!?]+["')\]]*\s*|[^.!?]+$"#)

    /// The turn that starts at the person's message `ask` (their newest when nil):
    /// every reply after it, up to the next thing they said.
    static func turn(_ messages: [ChatMessage], ask: String?) -> StageTurn {
        guard let i = ask.flatMap({ id in messages.lastIndex { $0.id == id } }) ?? messages.lastIndex(where: \.fromUser)
        else { return StageTurn() }
        var t = StageTurn(ask: messages[i])
        for m in messages[(i + 1)...] {
            if m.fromUser { break }
            add(m, to: &t)
        }
        return t
    }

    /// The agent's hello (YUI-167): the first messages of a thread marked as its hello,
    /// up to the first thing the person said. Empty when there is none.
    static func hello(_ messages: [ChatMessage]) -> StageTurn {
        var t = StageTurn(hello: true)
        for m in messages {
            if m.fromUser { break }
            if m.hello { add(m, to: &t) }
        }
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
