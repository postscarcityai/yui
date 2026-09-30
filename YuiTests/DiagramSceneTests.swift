import XCTest
import YuiLines
@testable import Yui

/// Diagrams (DRAW-2): the app's layout gives the same boxes and lines as the hub's
/// site/lib/yl/diagram.mjs. Resources/diagram-scenes.json holds, for ten diagrams
/// (flowchart in four directions, a wide left-to-right one that turns top down, cycles
/// and self links, subgraphs, state diagrams, a sequence with blocks and notes), the
/// patch the hub's parser gives at `end` and the layout diagram.mjs makes of it, run
/// with node. The Yui Lines parser's own patch is checked to be the same props below.
@MainActor
final class DiagramSceneTests: XCTestCase {
    private let tol = 1e-6

    private func scenes() throws -> [(name: String, input: String, props: [String: YLValue], layout: [String: Any])] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "diagram-scenes", withExtension: "json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(root["scenes"] as? [[String: Any]])
        return try cases.map { c in
            let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(c["props"]))
            return (c["name"] as? String ?? "?", c["input"] as? String ?? "",
                    try JSONDecoder().decode([String: YLValue].self, from: data), try XCTUnwrap(c["layout"] as? [String: Any]))
        }
    }

    private func d(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
    private func near(_ a: Double, _ b: Any?, _ what: String, line: UInt = #line) {
        guard let b = d(b) else { XCTFail("\(what): no expected number", line: line); return }
        XCTAssertEqual(a, b, accuracy: tol, what, line: line)
    }
    private func near(_ a: [Double], _ b: Any?, _ what: String, line: UInt = #line) {
        guard let b = b as? [Any], a.count == b.count else { XCTFail("\(what): \(a) vs \(String(describing: b))", line: line); return }
        for (x, y) in zip(a, b) { near(x, y, what, line: line) }
    }

    func testGraphsMatchTheHub() throws {
        var graphs = 0
        for c in try scenes() where c.props["type"]?.string != "sequence" {
            graphs += 1
            let g = DiagramModel.layoutGraph(DiagramModel.graphIn(c.props))
            let js = c.layout, name = c.name
            near(g.w, js["w"], "\(name): w"); near(g.h, js["h"], "\(name): h")
            XCTAssertEqual(g.turned, js["turned"] as? Bool, "\(name): turned")
            XCTAssertEqual(g.dir, js["dir"] as? String, "\(name): dir")
            let nodes = try XCTUnwrap(js["nodes"] as? [[String: Any]])
            XCTAssertEqual(g.nodes.map(\.id), nodes.map { $0["id"] as? String ?? "" }, "\(name): nodes")
            for (n, j) in zip(g.nodes, nodes) {
                let w = "\(name) node \(n.id)"
                near(n.cx, j["cx"], "\(w) cx"); near(n.cy, j["cy"], "\(w) cy")
                near(n.w, j["w"], "\(w) w"); near(n.h, j["h"], "\(w) h")
                near(Double(n.order), j["order"], "\(w) order")
                XCTAssertEqual(n.lines, j["lines"] as? [String], "\(w) lines")
            }
            let edges = try XCTUnwrap(js["edges"] as? [[String: Any]])
            XCTAssertEqual(g.edges.count, edges.count, "\(name): edges")
            for (e, j) in zip(g.edges, edges) {
                let w = "\(name) edge \(e.from)>\(e.to)"
                XCTAssertEqual(e.from, j["from"] as? String, w); XCTAssertEqual(e.to, j["to"] as? String, w)
                for (p, q) in zip(e.pts, j["pts"] as? [Any] ?? []) { near(p, q, "\(w) pts") }
                near(e.mid, j["mid"], "\(w) mid")
                XCTAssertEqual(e.back, j["back"] as? Bool, "\(w) back")
                near(Double(e.order), j["order"], "\(w) order")
            }
            let groups = try XCTUnwrap(js["groups"] as? [[String: Any]])
            XCTAssertEqual(g.groups.map(\.id), groups.map { $0["id"] as? String ?? "" }, "\(name): groups")
            for (b, j) in zip(g.groups, groups) {
                near(b.x, j["x"], "\(name) group \(b.id) x"); near(b.y, j["y"], "\(name) group \(b.id) y")
                near(b.w, j["w"], "\(name) group \(b.id) w"); near(b.h, j["h"], "\(name) group \(b.id) h")
            }
        }
        XCTAssertGreaterThanOrEqual(graphs, 9)
    }

    func testSequenceMatchesTheHub() throws {
        let seq = try scenes().filter { $0.props["type"]?.string == "sequence" }
        XCTAssertEqual(seq.count, 1)
        for c in seq {
            let q = DiagramModel.layoutSequence(DiagramModel.seqIn(c.props))
            let js = c.layout, name = c.name
            near(q.w, js["w"], "\(name): w"); near(q.h, js["h"], "\(name): h"); near(q.dx, js["dx"], "\(name): dx")
            near(q.life, js["life"], "\(name): life"); near(q.span, js["span"], "\(name): span")
            let actors = try XCTUnwrap(js["actors"] as? [[String: Any]])
            XCTAssertEqual(q.actors.count, actors.count)
            for (a, j) in zip(q.actors, actors) {
                near(a.x, j["x"], "actor \(a.id) x"); near(a.w, j["w"], "actor \(a.id) w"); near(a.h, j["h"], "actor \(a.id) h")
                XCTAssertEqual(a.lines, j["lines"] as? [String])
            }
            let items = try XCTUnwrap(js["items"] as? [[String: Any]])
            XCTAssertEqual(q.items.count, items.count, "item count")
            for (k, (it, j)) in zip(q.items, items).enumerated() {
                let w = "item \(k) \(it.kind)"
                XCTAssertEqual(it.kind, j["kind"] as? String, w)
                near(Double(it.order), j["order"], "\(w) order"); near(it.y, j["y"], "\(w) y")
                if it.kind != "msg" { near(it.h, j["h"], "\(w) h") } // the hub's message has no height of its own
                if it.kind != "note" { near(Double(it.depth), j["depth"], "\(w) depth") }
                if it.kind == "msg" {
                    near(it.x1, j["x1"], "\(w) x1"); near(it.x2, j["x2"], "\(w) x2"); near(Double(it.n), j["n"], "\(w) n")
                    XCTAssertEqual(it.selfMsg, j["self"] as? Bool, w); XCTAssertEqual(it.lines, j["lines"] as? [String], w)
                    near(it.tw, j["tw"], "\(w) tw")
                } else if it.kind == "note" {
                    near(it.x, j["x"], "\(w) x"); near(it.w, j["w"], "\(w) w")
                } else {
                    XCTAssertEqual(it.divs.count, (j["divs"] as? [Any])?.count, "\(w) dividers")
                }
            }
        }
    }

    func testWrapAndEdges() {
        XCTAssertEqual(DiagramModel.wrap("one two three four", 9), ["one two", "three", "four"])
        XCTAssertEqual(DiagramModel.wrap("Supercalifragilistic", 5), ["Supercalifragilistic"])
        XCTAssertEqual(DiagramModel.wrap("", 5), [""])
        let empty = DiagramModel.layoutGraph(DiagramModel.GraphIn())
        XCTAssertEqual(empty.w, 0); XCTAssertTrue(empty.nodes.isEmpty)
        XCTAssertTrue(DiagramModel.layoutSequence(DiagramModel.SeqIn()).actors.isEmpty)
        // An edge to a node nobody drew is left out; a step from an actor nobody declared too.
        var g = DiagramModel.GraphIn()
        g.nodes = [.init(id: "a")]; g.edges = [.init(from: "a", to: "zz")]
        XCTAssertEqual(DiagramModel.layoutGraph(g).edges.count, 0)
        var q = DiagramModel.SeqIn()
        q.actors = [.init(id: "A"), .init(id: "B")]
        var m = DiagramModel.StepIn(type: "msg"); m.from = "A"; m.to = "Q"; m.text = "x"
        q.steps = [m]
        XCTAssertEqual(DiagramModel.layoutSequence(q).items.count, 0)
    }

    func testSpokenTextFollowsTheWritingOrder() throws {
        let all = try scenes()
        let ships = try XCTUnwrap(all.first { $0.name == "ask ships" })
        var p = ships.props
        p["title"] = .string("How an ask ships")
        p["caption"] = .string("x")
        XCTAssertEqual(DiagramModel.describe(p),
                       "How an ask ships. Flowchart: You, Board, Lane, Checks green?, TestFlight. You to Board; Board to Lane; Lane to Checks green?; Checks green? to TestFlight, yes; Checks green? to Lane, no. x")
        let st = try XCTUnwrap(all.first { $0.name == "state" })
        XCTAssertEqual(DiagramModel.describe(st.props),
                       "State diagram: start, Uploaded, Processing, Valid, Invalid, end. start to Uploaded; Uploaded to Processing, Apple receives it; Processing to Valid, passes; Processing to Invalid, fails; Valid to end.")
        let sq = try XCTUnwrap(all.first { $0.name == "sequence" })
        XCTAssertTrue(DiagramModel.describe(sq.props).hasPrefix("Sequence diagram: You, Yui app, Agent. 1. You to Yui app: type and send; 2. Yui app to Agent: your words; loop while it thinks; 3. Yui app to You: working row;"))
    }

    // MARK: Mock

    func testMockOrderIsNavFirstTabsLastOverlaysAfter() {
        let p = { (kind: String, text: String) -> [String: YLValue] in ["kind": .string(kind), "text": .string(text)] }
        let parts = MockModel.parts([p("keyboard", ""), p("tabs", "t1"), p("text", "a"), p("nav", "n1"), p("alert", "x"), p("row", "b"),
                                     p("nav", "n2"), p("tabs", "t2"), p("sheet", "s")])
        XCTAssertEqual(parts.map(\.kind), ["nav", "text", "row", "tabs", "keyboard", "alert", "sheet"])
        XCTAssertEqual(parts.first?.text, "n1", "only the first nav counts")
        XCTAssertEqual(parts.first { $0.kind == "tabs" }?.text, "t1", "only the first tabs counts")
    }

    func testMockTabsFramesAndUnknownKinds() {
        XCTAssertEqual(MockModel.pick(["Home", "Agents", "Me"], .string("agents")), 1)
        XCTAssertEqual(MockModel.pick(["Home", "Agents", "Me"], .number(3)), 2)
        XCTAssertEqual(MockModel.pick(["Home"], nil), -1)
        XCTAssertEqual(MockModel.frame(["frame": .string("browser")]), "browser")
        XCTAssertEqual(MockModel.frame(["frame": .string("television")]), "phone")
        XCTAssertEqual(MockModel.frame([:]), "phone")
        let odd = MockModel.part(["kind": .string("hologram"), "text": .string("hi"), "items": .string("one"), "back": .bool(true), "chev": .bool(true)])
        XCTAssertEqual(odd.kind, "hologram"); XCTAssertEqual(odd.items, ["one"]); XCTAssertEqual(odd.back, ""); XCTAssertTrue(odd.chev)
        XCTAssertEqual(MockModel.part([:]).kind, "text")
    }

    func testMockSpokenText() {
        let head: [String: YLValue] = ["title": .string("Sign in")]
        let parts = MockModel.parts([
            ["kind": .string("nav"), "text": .string("Sign in"), "back": .string("Back")],
            ["kind": .string("field"), "text": .string("Password"), "ph": .string("at least 8"), "hi": .bool(true), "note": .string("meter")],
            ["kind": .string("button"), "text": .string("Go"), "x": .bool(true)],
            ["kind": .string("divider")],
        ])
        XCTAssertEqual(MockModel.describe(head: head, parts: parts),
                       "Sign in. Mock screen, phone: Navigation bar, Sign in, back Back; Field, Password, placeholder at least 8 (highlighted). Note: meter; Button, Go (crossed out).")
    }

    // MARK: The Yui Lines parser's patch

    /// The app's parser gives the same props as the hub's for the same text, and the demo parses into drawings.
    func testParserPropsMatchTheHub() throws {
        for c in try scenes() {
            let yl = YLScreen(c.input)
            let top = try XCTUnwrap(yl.top.first { $0.preset == "diagram" }, c.name)
            XCTAssertEqual(top.props["type"], c.props["type"], c.name)
            XCTAssertEqual(top.props["nodes"], c.props["nodes"], "\(c.name): nodes")
            XCTAssertEqual(top.props["edges"], c.props["edges"], "\(c.name): edges")
            XCTAssertEqual(top.props["actors"], c.props["actors"], "\(c.name): actors")
            XCTAssertEqual(top.props["steps"], c.props["steps"], "\(c.name): steps")
        }
    }

    func testDemoParses() throws {
        let presets = ChatView.drawDemo.map { YLScreen($0).top.map(\.preset) }
        XCTAssertEqual(presets, [["say", "diagram"], ["diagram"], ["diagram"], ["say", "mock"], ["mock"], ["mock"]])
        let mock = try XCTUnwrap(YLScreen(ChatView.drawDemo[3]).top.first { $0.preset == "mock" })
        let yl = YLScreen(ChatView.drawDemo[3])
        XCTAssertEqual(yl.components.members(of: mock).count, 7)
    }

    func testDiagramAndMockArePagePictures() throws {
        let yl = YLScreen("""
        deck "Pictures"
        page "Flow"
        diagram
        flowchart TD
          a --> b
        end
        page "Screen"
        mock
        part button Go
        page "Loose"
        """)
        let deck = try XCTUnwrap(yl.top.first)
        let steps = yl.components.steps(of: deck)
        XCTAssertEqual(steps.map(\.preset), ["page", "page", "page"])
        XCTAssertEqual(yl.components.picture(of: steps[0])?.preset, "diagram")
        XCTAssertEqual(yl.components.picture(of: steps[1])?.preset, "mock")
        XCTAssertNil(yl.components.picture(of: steps[2]))
    }
}
