import XCTest
import YuiLines
@testable import Yui

/// Shapes that move (YUI-104): the app's scene model gives the same diagram as the
/// hub's site/lib/yl/shapes.mjs. Resources/shapes-scenes.json is a copy of yuigui
/// spec/shapes/scenes.json (regenerate there with `node gen.mjs`, then copy it here):
/// layout, sizes, the clock at a few moments, wrapped labels and the spoken text.
@MainActor
final class ShapesSceneTests: XCTestCase {
    private let tol = 2e-3

    private func near(_ a: Double?, _ b: Any?, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let b = b as? Double ?? (b as? NSNumber)?.doubleValue else {
            XCTAssertNil(a, "\(what): expected none", file: file, line: line); return
        }
        guard let a else { XCTFail("\(what): missing, expected \(b)", file: file, line: line); return }
        XCTAssertEqual(a, b, accuracy: tol, what, file: file, line: line)
    }

    private func near(_ a: [Double]?, _ b: Any?, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let b = b as? [Any] else { XCTAssertNil(a, "\(what): expected none", file: file, line: line); return }
        guard let a, a.count == b.count else { XCTFail("\(what): \(String(describing: a)) vs \(b)", file: file, line: line); return }
        for (x, y) in zip(a, b) { near(x, y, what, file: file, line: line) }
    }

    private func end(_ e: ShapesModel.End?, _ j: Any?, _ what: String) {
        guard let j = j as? [String: Any] else { XCTAssertNil(e, what); return }
        switch e {
        case .ref(let r)?: XCTAssertEqual(r, j["ref"] as? Int, what)
        case .pt(let p)?: near(p, j["pt"], what)
        case nil: XCTFail("\(what): missing")
        }
    }

    func testTheSceneMatchesTheHub() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "shapes-scenes", withExtension: "json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(root["scenes"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 6)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let yl = YLScreen(c["input"] as? String ?? "")
            let top = try XCTUnwrap(yl.top.first, name)
            let parts = top.preset == "shape" ? [top] : yl.components.members(of: top).filter { $0.preset == "shape" }
            let sc = ShapesModel.scene(head: top.preset == "shape" ? [:] : top.props,
                                       members: parts.map { (id: $0.ylID, props: $0.props) })
            let js = try XCTUnwrap(c["scene"] as? [String: Any], name)
            near(sc.w, js["w"], "\(name): w"); near(sc.h, js["h"], "\(name): h")
            near(sc.fs, js["fs"], "\(name): fs"); near(sc.total, js["total"], "\(name): total")
            XCTAssertEqual(sc.title, js["title"] as? String, name)
            XCTAssertEqual(sc.caption, js["caption"] as? String, name)
            let items = try XCTUnwrap(js["items"] as? [[String: Any]])
            XCTAssertEqual(sc.items.count, items.count, "\(name): part count")
            for (it, j) in zip(sc.items, items) {
                let w = "\(name) #\(it.i) \(it.kind)"
                XCTAssertEqual(it.i, j["i"] as? Int, w)
                XCTAssertEqual(it.kind, j["kind"] as? String, w)
                XCTAssertEqual(it.label, j["label"] as? String, w)
                XCTAssertEqual(it.tone, j["tone"] as? String, w)
                XCTAssertEqual(it.fill, j["fill"] as? Bool, w)
                XCTAssertEqual(it.dash, j["dash"] as? Bool, w)
                XCTAssertEqual(it.pulse, j["pulse"] as? Bool, w)
                XCTAssertEqual(it.motion.rawValue, j["motion"] as? String, w)
                near(it.start, j["start"], "\(w) start"); near(it.dur, j["dur"], "\(w) dur")
                near(it.at, j["at"], "\(w) at"); near(it.size, j["size"], "\(w) size"); near(it.move, j["move"], "\(w) move")
                let pts = (j["pts"] as? [[Any]])
                XCTAssertEqual(it.pts?.count, pts?.count, "\(w) pts")
                for (p, q) in zip(it.pts ?? [], pts ?? []) { near(p, q, "\(w) pt") }
                end(it.from, j["from"], "\(w) from"); end(it.to, j["to"], "\(w) to")
            }
            let frames = try XCTUnwrap(c["frames"] as? [String: [[String: Any]]])
            for (key, list) in frames {
                let t = key == "still" ? Double.infinity : try XCTUnwrap(Double(key))
                let got = ShapesModel.frame(sc, at: t)
                XCTAssertEqual(got.count, list.count, "\(name) t=\(key)")
                for (f, j) in zip(got, list) {
                    let w = "\(name) t=\(key) #\(f.item.i)"
                    near(f.o, j["o"], "\(w) o"); near(f.s, j["s"], "\(w) s"); near(f.d, j["d"], "\(w) d")
                    near(f.c, j["c"], "\(w) c"); near(f.a, j["a"], "\(w) a"); near(f.b, j["b"], "\(w) b")
                }
            }
            let labels = c["labels"] as? [String: [String]] ?? [:]
            for it in sc.items where !it.label.isEmpty {
                let fs = it.from != nil || it.pts != nil ? sc.fs * 0.9 : sc.fs
                XCTAssertEqual(ShapesModel.wrap(it.label, width: ShapesModel.labelWidth(it, k: sc.k), fs: fs),
                               labels[String(it.i)], "\(name) #\(it.i) label lines")
            }
            XCTAssertEqual(ShapesModel.describe(sc), c["text"] as? String, "\(name): spoken text")
        }
    }

    /// Shapes and their members ride inside the head; a lone shape stands alone.
    func testShapesGroupAndLoneShape() throws {
        let yl = YLScreen("shapes A\nshape circle One\nshape arrow\nshape box Two\nsay Done.\nshape dot Alone")
        XCTAssertEqual(yl.top.map(\.preset), ["shapes", "say", "shape"])
        XCTAssertTrue(yl.errors.isEmpty)
        XCTAssertEqual(ChatView.shapesDemo.map { YLScreen($0).errors.count }, [0, 0, 0, 0], "the demo lines all parse")
    }
}
