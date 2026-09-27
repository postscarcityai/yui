import CryptoKit
import XCTest
import YuiLines
@testable import Yui

/// Maps (YUI-158): the app's scene model gives the same map as the hub's
/// site/lib/yl/map.mjs. Resources/map-scenes.json is a copy of yuigui
/// spec/map/scenes.json (regenerate there with `node gen.mjs`, then copy it
/// here): the fit, the land and area outlines (as a hash of the path), label
/// spots, the clock at a few moments and the spoken text.
@MainActor
final class MapSceneTests: XCTestCase {
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

    private func same(_ rings: [[[Double]]], _ j: Any?, _ what: String) {
        guard let j = j as? [String: Any] else { XCTFail("\(what): no path in the fixture"); return }
        let d = MapModel.path(rings)
        let hash = SHA256.hash(data: Data(d.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        XCTAssertEqual(d.count, j["len"] as? Int, "\(what): path length")
        XCTAssertEqual(String(hash), j["hash"] as? String, "\(what): path")
    }

    func testTheSceneMatchesTheHub() throws {
        XCTAssertEqual(MapModel.countries.count, 177, "the bundled world outline")
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "map-scenes", withExtension: "json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(root["scenes"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 7)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let yl = YLScreen(c["input"] as? String ?? "")
            let top = try XCTUnwrap(yl.top.first, name)
            let sc = MapPreset.scene(top, all: yl.components)
            let js = try XCTUnwrap(c["scene"] as? [String: Any], name)
            near(sc.w, js["w"], "\(name): w"); near(sc.h, js["h"], "\(name): h")
            near(sc.fs, js["fs"], "\(name): fs"); near(sc.total, js["total"], "\(name): total")
            let view = try XCTUnwrap(js["view"] as? [String: Any])
            near(sc.view.lon, view["lon"], "\(name): view lon"); near(sc.view.lat, view["lat"], "\(name): view lat")
            XCTAssertEqual(sc.title, js["title"] as? String, name)
            XCTAssertEqual(sc.caption, js["caption"] as? String, name)
            XCTAssertEqual(sc.missing, js["missing"] as? [String], name)
            same(sc.land, js["land"], "\(name): land")
            let items = try XCTUnwrap(js["items"] as? [[String: Any]])
            XCTAssertEqual(sc.items.count, items.count, "\(name): part count")
            for (it, j) in zip(sc.items, items) {
                let w = "\(name) #\(it.i) \(it.kind)"
                XCTAssertEqual(it.i, j["i"] as? Int, w)
                XCTAssertEqual(it.kind, j["kind"] as? String, w)
                XCTAssertEqual(it.label, j["label"] as? String, w)
                XCTAssertEqual(it.tone, j["tone"] as? String, w)
                XCTAssertEqual(it.dash, j["dash"] as? Bool, w)
                XCTAssertEqual(it.pulse, j["pulse"] as? Bool, w)
                near(it.start, j["start"], "\(w) start"); near(it.dur, j["dur"], "\(w) dur")
                near(it.c, j["c"], "\(w) c")
                near(it.lx, j["lx"], "\(w) lx"); near(it.ly, j["ly"], "\(w) ly")
                XCTAssertEqual(it.anchor, j["anchor"] as? String, "\(w) anchor")
                switch it.kind {
                case "area":
                    same(it.rings, j["path"], "\(w) outline")
                    XCTAssertEqual(it.names.compactMap { $0 }, j["names"] as? [String], "\(w) names")
                case "pin":
                    XCTAssertEqual(it.grow, j["grow"] as? Bool, "\(w) grow")
                default:
                    let pts = j["pts"] as? [[Any]]
                    XCTAssertEqual(it.pts.count, pts?.count, "\(w) pts")
                    for (p, q) in zip(it.pts, pts ?? []) { near(p, q, "\(w) pt") }
                    XCTAssertEqual(it.arrow, j["arrow"] as? Bool, "\(w) arrow")
                    let names = (j["names"] as? [Any])?.map { $0 as? String }
                    XCTAssertEqual(it.names, names, "\(w) stop names")
                }
            }
            let frames = try XCTUnwrap(c["frames"] as? [String: [[String: Any]]])
            for (key, list) in frames {
                let t = key == "still" ? Double.infinity : try XCTUnwrap(Double(key))
                let got = MapModel.frame(sc, at: t)
                XCTAssertEqual(got.count, list.count, "\(name) t=\(key)")
                for (f, j) in zip(got, list) {
                    let w = "\(name) t=\(key) #\(f.item.i)"
                    near(f.o, j["o"], "\(w) o"); near(f.d, j["d"], "\(w) d")
                    near(f.s, j["s"], "\(w) s"); near(f.p, j["p"], "\(w) p")
                }
            }
            XCTAssertEqual(MapModel.describe(sc), c["text"] as? String, "\(name): spoken text")
        }
    }

    /// A map and its parts ride inside the head; a lone part is a map of its own;
    /// in a deck, a map right after a page is that page's picture.
    func testMapGroupLonePartAndDeckPicture() throws {
        let yl = YLScreen("map A\narea MN\npin Ulaanbaatar 47.9,106.9\nsay Done.\npin Alone 1,2")
        XCTAssertEqual(yl.top.map(\.preset), ["map", "say", "pin"])
        XCTAssertTrue(yl.errors.isEmpty)
        let deck = YLScreen("deck D\npage \"Where\" body=Here.\nmap caption=Look.\narea MN\npage Next\nend")
        let head = try XCTUnwrap(deck.top.first)
        let steps = deck.components.steps(of: head)
        XCTAssertEqual(steps.map(\.preset), ["page", "page"])
        XCTAssertEqual(deck.components.picture(of: steps[0])?.preset, "map")
        XCTAssertEqual(ChatView.mapDemo.map { YLScreen($0).errors.count }, ChatView.mapDemo.map { _ in 0 }, "the demo lines all parse")
    }
}
