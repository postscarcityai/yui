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
                emits: v["emits"]?.array?.map { $0.array! }
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
    let whole = YuiLines.parse(v.input).map(comparable)
    #expect(whole == v.expected, "parse: \(json(whole)) != \(json(v.expected))")

    var s = YLStreamParser()
    var streamed: [YLNode] = []
    for ch in v.input.unicodeScalars { streamed += s.push(String(ch)) }
    streamed += s.flush()
    let byChar = streamed.map(comparable)
    #expect(byChar == v.expected, "stream by char: \(json(byChar))")

    if let chunks = v.chunks, let emits = v.emits {
        var s = YLStreamParser()
        var got = chunks.map { s.push($0).map(comparable) }
        got.append(s.flush().map(comparable))
        #expect(got == emits, "stream by chunk: \(json(got))")
    }

    #expect(v.expected.contains { $0["op"] == "error" } == v.error, "`error` flag does not match expected")
}

@Test func suiteIsLoaded() {
    #expect(Vectors.files.count >= 15)
    #expect(Vectors.all.count >= 60)
}

@Test func streamSurvivesByteSplitsInsideCharacters() {
    for v in Vectors.all {
        var s = YLStreamParser()
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

/// When the hub repo sits next to this one, the copied vectors must match it.
@Test(.enabled(if: FileManager.default.fileExists(atPath: hubVectors.path)))
func vectorsMatchHubRepo() throws {
    let hub = try FileManager.default.contentsOfDirectory(atPath: hubVectors.path)
        .filter { $0.range(of: #"^\d\d-.*\.json$"#, options: .regularExpression) != nil }.sorted()
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
