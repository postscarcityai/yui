import Foundation
import Testing
@testable import YuiLines

// Runs the shared YL conformance vectors (copied from yuigui/spec/conformance
// by scripts/sync-vectors.sh). A vector passes when parsing the input whole,
// and streaming it one character at a time, both give `expected`; vectors with
// `chunks` must also emit `emits` chunk by chunk.

struct Vector: Sendable, CustomTestStringConvertible {
    let file: String
    let name: String
    let input: String
    let expected: [YLValue]
    let error: Bool
    let chunks: [String]?
    let emits: [[YLValue]]?
    /// Ids of the adds that open on the stage under `style` (spec section 5).
    let stage: [String]?
    /// The page of each add, in order (spec section 5, Pages).
    let pages: [Int]?
    /// The pages with the composer on after the input (chat with a screen).
    let talk: [Int]?
    /// Words typed on a screen and the body the agent reads: screen, words, body.
    let typed: [String: String]?
    /// Words about a Controls item: item (section, id, rev, or null), words, body.
    let attach: YLValue?
    /// The drawer after the input (spec section 5, The drawer).
    let menu: YLValue?
    /// A timeline's rows after the input, {rows: [{id, kind}], mark} (YUI-111).
    let rows: YLValue?
    let style: [String: String]
    /// Ids that last from earlier replies, id -> preset (spec section 5).
    let known: [String: String]
    var testDescription: String { "\(file) :: \(name)" }
}

enum Vectors {
    static let dir = Bundle.module.url(forResource: "conformance", withExtension: nil)!

    static let files: [String] = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.range(of: #"^\d\d-.*\.json$"#, options: .regularExpression) != nil }
        .sorted()

    static let all: [Vector] = files.flatMap { file -> [Vector] in
        let text = try! String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
        let doc = try! YLValue.parseJSON(text)
        return doc["vectors"]!.array!.map { v in
            Vector(
                file: file,
                name: v["name"]!.string!,
                input: v["input"]!.string!,
                expected: v["expected"]!.array!,
                error: v["error"]?.bool ?? false,
                chunks: v["chunks"]?.array?.map { $0.string! },
                emits: v["emits"]?.array?.map { $0.array! },
                stage: v["stage"]?.array?.map { $0.string! },
                pages: v["pages"]?.array?.map { Int($0.number!) },
                talk: v["talk"]?.array?.map { Int($0.number!) },
                typed: v["typed"]?.object?.compactMapValues { $0.string },
                attach: v["attach"],
                menu: v["menu"],
                rows: v["rows"],
                style: v["style"]?.object?.compactMapValues { $0.string } ?? [:],
                known: v["known"]?.object?.compactMapValues { $0.string } ?? [:]
            )
        }
    }
}

/// A node as the vectors spell it: no `line`, no error `message`.
func comparable(_ n: YLNode) -> YLValue {
    var o: [String: YLValue] = ["op": .string(n.op.rawValue), "screen": .string(n.screen)]
    if let v = n.preset { o["preset"] = .string(v) }
    if let v = n.id { o["id"] = .string(v) }
    if let v = n.target { o["target"] = .string(v) }
    if let v = n.name { o["name"] = .string(v) }
    if let v = n.inGroup { o["in"] = .string(v) }
    if let v = n.props { o["props"] = .object(v) }
    return .object(o)
}

func json(_ v: some Encodable) -> String {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try! e.encode(v), as: UTF8.self)
}

@Test("conformance vector", arguments: Vectors.all)
func conformance(_ v: Vector) {
    let whole = YuiLines.parse(v.input, known: v.known).map(comparable)
    #expect(whole == v.expected, "parse: \(json(whole)) != \(json(v.expected))")

    var s = YLStreamParser(known: v.known)
    var streamed: [YLNode] = []
    for ch in v.input.unicodeScalars { streamed += s.push(String(ch)) }
    streamed += s.flush()
    let byChar = streamed.map(comparable)
    #expect(byChar == v.expected, "stream by char: \(json(byChar))")

    if let chunks = v.chunks, let emits = v.emits {
        var s = YLStreamParser(known: v.known)
        var got = chunks.map { s.push($0).map(comparable) }
        got.append(s.flush().map(comparable))
        #expect(got == emits, "stream by chunk: \(json(got))")
    }

    if let stage = v.stage {
        let staged = YuiLines.parse(v.input, known: v.known).filter { YuiLines.opensOnStage($0, style: v.style) }.compactMap(\.id)
        #expect(staged == stage, "stage: \(staged)")
    }

    if let pages = v.pages {
        let got = YuiLines.parse(v.input, known: v.known).filter { $0.op == .add }.map { YuiLines.page(of: $0.screen) }
        #expect(got == pages, "pages: \(got)")
    }

    if let talk = v.talk {
        let got = YuiLines.talking(YuiLines.parse(v.input, known: v.known))
        #expect(got == talk, "talk: \(got)")
    }

    if let t = v.typed, let screen = t["screen"], let words = t["words"], let body = t["body"] {
        let made = YuiLines.typedBody(screen: screen, words: words)
        #expect(made == body, "typed body: \(made)")
        let read = YuiLines.readTyped(body)
        if YuiLines.page(of: screen) == 1 {
            #expect(read == nil, "typed read back: \(String(describing: read))")
        } else {
            #expect(read?.screen == screen && read?.words == words, "typed read back: \(String(describing: read))")
        }
    }

    if let a = v.attach, let words = a["words"]?.string, let body = a["body"]?.string {
        let item = a["item"]?.object?.compactMapValues { $0.string } ?? [:]
        let made = YuiLines.attachBody(section: item["section"] ?? "", id: item["id"] ?? "", rev: item["rev"] ?? "",
                                       words: words)
        #expect(made == body, "attach body: \(made)")
        let read = YuiLines.readAttach(body)
        if made == words {
            #expect(read == nil, "attach read back: \(String(describing: read))")
        } else {
            #expect(read?.section == item["section"] && read?.id == item["id"] && read?.rev == item["rev"]
                        && read?.words == words, "attach read back: \(String(describing: read))")
        }
    }

    if let want = v.menu {
        let m = YuiLines.menu(YuiLines.parse(v.input))
        let got = YLValue.object(Dictionary(uniqueKeysWithValues: YuiLines.menuBuckets.map { b in
            (b, YLValue.array(m[b].map { it in
                var o: [String: YLValue] = ["id": .string(it.id), "label": .string(it.label)]
                if let x = it.sub { o["sub"] = .string(x) }
                if let x = it.say { o["say"] = .string(x) }
                if let x = it.show { o["show"] = .string(x) }
                if let x = it.url { o["url"] = .string(x) }
                return .object(o)
            }))
        }))
        #expect(got == want, "menu: \(json(got))")
    }

    if let want = v.rows {
        // Timeline rows after the input is applied to an empty screen: adds in
        // line order, a patch lands on the newest id or preset match, and
        // `kind=` re-kinds a row in place (YL.md, timeline, Moving a row).
        var parts: [(id: String, preset: String)] = []
        for n in YuiLines.parse(v.input, known: v.known) {
            if n.op == .add { parts.append((n.id ?? "", n.preset ?? "say")) }
            if n.op == .patch, let t = n.target, let i = parts.lastIndex(where: { $0.id == t || $0.preset == t }),
               let kind = rowKind(of: parts[i].preset, patch: n.props ?? [:]) {
                parts[i].preset = kind
            }
        }
        let rows = parts.filter { timelineRows.contains($0.preset) }
        let got = YLValue.object([
            "rows": .array(rows.map { .object(["id": .string($0.id), "kind": .string($0.preset)]) }),
            "mark": .number(Double(markAt(rows.map(\.preset)))),
        ])
        #expect(got == want, "rows: \(json(got))")
    }

    #expect(v.expected.contains { $0["op"] == "error" } == v.error, "`error` flag does not match expected")
}

@Test func suiteIsLoaded() {
    #expect(Vectors.files.count >= 15)
    #expect(Vectors.all.count >= 60)
}

@Test func streamSurvivesByteSplitsInsideCharacters() {
    for v in Vectors.all {
        var s = YLStreamParser(known: v.known)
        var out: [YLNode] = []
        for b in v.input.utf8 { out += s.push(bytes: [b]) }
        out += s.flush()
        #expect(out.map(comparable) == v.expected, "\(v.testDescription)")
    }
}

@Test func asyncStreamEmitsLineByLine() async throws {
    let chunks = AsyncStream<String> { c in
        for piece in ["timer 40/20x8 Ta", "bata\nask Log", " this set?"] { c.yield(piece) }
        c.finish()
    }
    var got: [YLNode] = []
    for try await node in YuiLines.nodes(from: chunks) { got.append(node) }
    #expect(got.map(\.preset) == ["timer", "ask"])
    #expect(got[0].props?["rounds"] == .number(8))
}

@Test func nodesRoundTripThroughCodable() throws {
    let nodes = YuiLines.parse(Vectors.all.map(\.input).joined(separator: "\n"))
    #expect(nodes.count > 150)
    let data = try JSONEncoder().encode(nodes)
    #expect(try JSONDecoder().decode([YLNode].self, from: data) == nodes)
    #expect(json(YuiLines.parse("timer 40/20x8")[0].props!) == #"{"rest":20,"rounds":8,"work":40}"#)
}

@Test func strictJSONMatchesJSONParse() throws {
    for bad in ["", "{", "[1,]", "{\"a\":1,}", "01", "1.", ".5", "+1", "'x'", "{a:1}", "\"\u{01}\"", "1 2", "nul"] {
        #expect(throws: YLJSONError.self, "\(bad)") { try YLValue.parseJSON(bad) }
    }
    #expect(try YLValue.parseJSON(" -0.5e2 ") == .number(-50))
    let pair = "\"" + ["ud83d", "udcaa"].map { "\\" + $0 }.joined() + "\""  // a JSON surrogate pair
    #expect(try YLValue.parseJSON(pair) == .string("\u{1F4AA}"))
}

/// Hub areas this parser has not taken on yet. Keep in step with
/// `scripts/sync-vectors.sh`; drop a name here once the parser passes that file.
let notYetInApp: Set<String> = ["30-tables.json", "35-doing.json"]  // YUI-89 and YUI-63 step 2 (app halves)

/// When the hub repo sits next to this one, the copied vectors must match it.
@Test(.enabled(if: FileManager.default.fileExists(atPath: hubVectors.path)))
func vectorsMatchHubRepo() throws {
    let hub = try FileManager.default.contentsOfDirectory(atPath: hubVectors.path)
        .filter { $0.range(of: #"^\d\d-.*\.json$"#, options: .regularExpression) != nil && !notYetInApp.contains($0) }.sorted()
    #expect(hub == Vectors.files, "run scripts/sync-vectors.sh")
    for f in hub {
        let a = try Data(contentsOf: hubVectors.appendingPathComponent(f))
        let b = try Data(contentsOf: Vectors.dir.appendingPathComponent(f))
        #expect(a == b, "\(f) is stale, run scripts/sync-vectors.sh")
    }
}

let hubVectors = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("../../../yuigui/spec/conformance").standardizedFileURL
