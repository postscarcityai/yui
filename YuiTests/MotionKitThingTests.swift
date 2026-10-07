import XCTest
import WebKit
@testable import Yui

/// MOTION-14 on the phone: the bundled player carries `api.thing`, so a film draws the kit's objects (a roast chicken)
/// and a noun the kit has no object for (a submarine) falls back to the blob shape without failing the film.
@MainActor
final class MotionKitThingTests: XCTestCase {
    private func host(_ c: MotionController) -> UIWindow {
        let w = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let vc = UIViewController(); w.rootViewController = vc
        c.web.frame = w.bounds; vc.view.addSubview(c.web)
        w.makeKeyAndVisible()
        return w
    }

    private func shot(_ c: MotionController, _ name: String) async throws {
        let url = try await c.web.evaluateJavaScript("document.getElementById('cv').toDataURL('image/png')") as? String ?? ""
        let png = Data(base64Encoded: String(url.dropFirst("data:image/png;base64,".count))) ?? Data()
        XCTAssertGreaterThan(png.count, 1000)
        if let dir = ProcessInfo.processInfo.environment["MOTION_SHOTS"] ?? (try? String(contentsOfFile: "/tmp/yui-motion-shots-dir", encoding: .utf8)) {
            let d = dir.trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
            try? png.write(to: URL(fileURLWithPath: d + "/" + name + ".png"))
        }
    }

    /// A noun the kit has no object for: the film paints it itself with canvas calls, no `api.thing`.
    private static let submarine = """
        const x = api.w / 2, y = api.h / 2 - 20, k = api.ease(Math.min(1, t / 1.2));
        c.fillStyle = "#ffd36b"; c.beginPath(); c.ellipse(x, y, 130 * k, 52 * k, 0, 0, 6.2832); c.fill();
        c.fillRect(x - 30 * k, y - 80 * k, 60 * k, 40 * k);
        c.fillStyle = "#1c1730"; c.beginPath(); c.arc(x - 50 * k, y, 14 * k, 0, 6.2832); c.arc(x + 10 * k, y, 14 * k, 0, 6.2832); c.fill();
        api.say("A submarine", 0.3, 2.6);
        """

    private func play(_ noun: String, shot name: String, dark: Bool) async throws {
        let c = MotionController(); let w = host(c); _ = w
        let t = YuiTheme.yui
        c.setTheme(t.palette(for: dark ? .dark : .light), dark: dark)
        let code = noun == "submarine" ? Self.submarine : """
            api.thing("\(noun)", api.w / 2, api.h / 2 - 20, 260, { k: api.ease(Math.min(1, t / 1.2)) });
            api.say("A \(noun)", 0.3, 2.6);
            """
        c.addScene(MotionSceneSpec(name: "hook", dur: 3, code: code))
        c.end()
        for _ in 0..<100 where !c.hasFirstFrame { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(c.hasFirstFrame); XCTAssertFalse(c.isFailed, "\(c.phase)")
        try await Task.sleep(for: .milliseconds(1800))
        XCTAssertFalse(c.isFailed, "\(c.phase)")
        let has = try await c.web.evaluateJavaScript("String(typeof window.yui)") as? String
        XCTAssertEqual(has, "object")
        try await shot(c, name)
        c.stop()
    }

    func testBundleCarriesThing() throws {
        let b = Bundle(for: MotionController.self)
        let html = try String(contentsOfFile: b.path(forResource: "motion-player", ofType: "html")!, encoding: .utf8)
        XCTAssertTrue(html.contains("api.thing"))
        XCTAssertTrue(html.contains("api.defineThing"))
    }

    func testChickenFilmDarkAndLight() async throws {
        try await play("chicken", shot: "1-chicken-dark", dark: true)
        try await play("chicken", shot: "3-chicken-light", dark: false)
    }

    func testSubmarineFilmDarkAndLight() async throws {
        try await play("submarine", shot: "2-submarine-dark", dark: true)
        try await play("submarine", shot: "4-submarine-light", dark: false)
    }

    /// MOTION-15: the plugin sends kit-shape parts for a noun the kit lacks; the film registers them with
    /// `api.defineThing` and the kit draws a giraffe, not a blob.
    private static let giraffeParts = #"[["M-34 18 L-36 44",0,"fg",3],["M-20 20 L-22 44",0,"fg",3],["M18 20 L20 44",0,"fg",3],["M32 18 L36 44",0,"fg",3],["M-44 6 A40 18 0 1 1 36 6 A40 18 0 1 1 -44 6Z","warn","fg",1],["M22 6 C21.3 13.7 27 12 30 6 C33 0 37.7 -22.3 40 -30 C42.3 -37.7 45 -38.3 44 -40 C43 -41.7 37.7 -47.7 34 -40 C30.3 -32.3 22.7 -1.7 22 6Z","warn","fg",1],["M36 -40 A10 6 0 1 1 56 -40 A10 6 0 1 1 36 -40Z","warn","fg",1],["M42 -46 L40 -54",0,"fg",1.5],["M-44 2 L-52 14 L-50 24",0,"fg",1.5],["M-22 2 A6 6 0 1 1 -10 2 A6 6 0 1 1 -22 2Z","ink","fg",1],["M1 10 A5 5 0 1 1 11 10 A5 5 0 1 1 1 10Z","ink","fg",1],["M48.5 -42 A1.5 1.5 0 1 1 51.5 -42 A1.5 1.5 0 1 1 48.5 -42Z","ink","fg",1]]"#

    private func playDefined(shot name: String, dark: Bool) async throws {
        let c = MotionController(); let w = host(c); _ = w
        c.setTheme(YuiTheme.yui.palette(for: dark ? .dark : .light), dark: dark)
        c.addScene(MotionSceneSpec(name: "hook", dur: 3, code: """
            if (api.defineThing) api.defineThing("giraffe", \(Self.giraffeParts));
            api.thing("giraffe", api.w / 2, api.h / 2 - 20, 260, { k: api.ease(Math.min(1, t / 1.2)) });
            api.say("A giraffe", 0.3, 2.6);
            """))
        c.end()
        for _ in 0..<100 where !c.hasFirstFrame { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(c.hasFirstFrame); XCTAssertFalse(c.isFailed, "\(c.phase)")
        try await Task.sleep(for: .milliseconds(1800))
        XCTAssertFalse(c.isFailed, "\(c.phase)")
        try await shot(c, name)
        c.stop()
    }

    func testGiraffeDefinedByFilmDarkAndLight() async throws {
        try await playDefined(shot: "5-giraffe-dark", dark: true)
        try await playDefined(shot: "6-giraffe-light", dark: false)
    }
}
