import XCTest
import WebKit
@testable import Yui

/// The native motion player (spec/MOTION.md 2.3): the message contract, the watchdog, and the real
/// harness running real scenes in a WKWebView.
@MainActor
final class MotionPlayerTests: XCTestCase {
    // MARK: Contract

    func testMessagesParse() {
        XCTAssertEqual(MotionMessage(["motion": "ready"]), .ready)
        XCTAssertEqual(MotionMessage(["motion": "first-frame"]), .firstFrame)
        XCTAssertEqual(MotionMessage(["motion": "ended"]), .ended)
        XCTAssertEqual(MotionMessage(["motion": "error", "scene": "dive", "message": "boom"]), .error(scene: "dive", message: "boom"))
        XCTAssertEqual(MotionMessage(["motion": "tap"]), .tap(id: nil))
        XCTAssertEqual(MotionMessage(["motion": "tap", "id": "photon"]), .tap(id: "photon"))
        XCTAssertEqual(MotionMessage(["motion": "time", "t": 1.5, "total": 9.0, "paused": true]), .time(t: 1.5, total: 9, paused: true))
        XCTAssertEqual(MotionMessage(["motion": "cues", "scene": "a", "cues": [["text": "Hi", "from": 1.0, "to": 2.5]]]),
                       .cues(scene: "a", cues: [MotionCue(text: "Hi", from: 1, to: 2.5)]))
        XCTAssertNil(MotionMessage(["motion": "launch-missiles"]), "an unknown verb is dropped")
        XCTAssertNil(MotionMessage("not a dict"))
    }

    func testSceneJSONCarriesAnyCode() throws {
        let code = "c.fillText(\"it's \\\"x\\\"\", 1, 2); // \u{2028} line\nconst a = `${1}`;"
        let spec = MotionSceneSpec(name: "q\"uote", dur: 4, code: code)
        let back = try JSONSerialization.jsonObject(with: Data(spec.json.utf8)) as? [String: Any]
        XCTAssertEqual(back?["code"] as? String, code)
        XCTAssertEqual(back?["name"] as? String, "q\"uote")
        XCTAssertEqual(back?["dur"] as? Double, 4)
    }

    func testFailureReportLine() {
        XCTAssertEqual(MotionReport.line(node: "n1", reason: "dive: x is not defined"), "[yui] n1 motion error=dive: x is not defined")
        XCTAssertEqual(MotionReport.line(node: "n1", reason: "a\nb"), "[yui] n1 motion error=a b")
        XCTAssertEqual(MotionWatchdog.reason(for: .slow), "slow frames")
        XCTAssertEqual(MotionWatchdog.reason(for: .error(scene: "s", message: "m")), "s: m")
        XCTAssertNil(MotionWatchdog.reason(for: .ended))
    }

    func testBlockListCompiles() async throws {
        let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "yui-motion-test", encodedContentRuleList: MotionController.blockAll)
        XCTAssertNotNil(list)
    }

    func testHarnessIsBundledWithItsCSP() {
        let html = MotionController.harnessHTML
        XCTAssertTrue(html.contains("default-src 'none'"), "the harness carries its own no-network CSP")
        XCTAssertTrue(html.contains("window.yui"))
        XCTAssertFalse(html.contains("fetch("))
        XCTAssertFalse(html.contains("XMLHttpRequest"))
    }

    // MARK: Messages move state

    func testStateFollowsMessages() {
        let c = MotionController()
        XCTAssertEqual(c.phase, .loading)
        c.handle(.firstFrame)
        XCTAssertEqual(c.phase, .playing)
        XCTAssertNotNil(c.firstFrameSeconds)
        c.handle(.timeline(total: 12, scenes: 2, ended: false))
        c.handle(.time(t: 3, total: 12, paused: false))
        XCTAssertEqual(c.time, 3)
        XCTAssertEqual(c.total, 12)
        c.handle(.cues(scene: "b", cues: [MotionCue(text: "Two", from: 6, to: 8)]))
        c.handle(.cues(scene: "a", cues: [MotionCue(text: "One", from: 1, to: 3)]))
        XCTAssertEqual(c.spoken, "One Two", "cues read in film order, whichever scene was probed first")
        c.pause(); XCTAssertEqual(c.phase, .paused)
        c.resume(); XCTAssertEqual(c.phase, .playing)
        c.handle(.ended); XCTAssertEqual(c.phase, .ended)
        c.replay(); XCTAssertEqual(c.phase, .playing); XCTAssertEqual(c.time, 0)
        c.stop()
    }

    func testAnErrorBeforeAnyFrameFailsTheFilm() {
        let c = MotionController()
        var told: String?
        c.onFailure = { told = $0 }
        c.handle(.error(scene: "hook", message: "scene does not parse"))
        XCTAssertEqual(c.phase, .failed("hook: scene does not parse"))
        XCTAssertEqual(told, "hook: scene does not parse")
        c.stop()
    }

    func testAnErrorAfterFramesKeepsPlayingButSlowFramesFail() {
        let c = MotionController()
        var told: [String] = []
        c.onFailure = { told.append($0) }
        c.handle(.firstFrame)
        c.handle(.error(scene: "dive", message: "x is not defined"))
        XCTAssertEqual(c.phase, .playing, "a scene that throws is cut short and the film goes on")
        c.handle(.slow)
        XCTAssertEqual(c.phase, .failed("slow frames"))
        c.handle(.slow)
        XCTAssertEqual(told, ["slow frames"], "the agent hears it once")
        c.stop()
    }

    func testTapsSplitBetweenTargetsAndChrome() {
        let c = MotionController()
        var hit: String?, chrome = 0
        c.onHit = { hit = $0 }; c.onChromeTap = { chrome += 1 }
        c.handle(.tap(id: "photon")); c.handle(.tap(id: nil))
        XCTAssertEqual(hit, "photon")
        XCTAssertEqual(chrome, 1)
        c.stop()
    }

    // MARK: The real harness

    private func waitFor(_ c: MotionController, _ what: String, timeout: Double = 15, _ ok: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !ok() && Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(ok(), what)
    }

    private func host(_ c: MotionController) -> UIWindow {
        let w = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let vc = UIViewController(); w.rootViewController = vc
        c.web.frame = w.bounds; vc.view.addSubview(c.web)
        w.makeKeyAndVisible()
        return w
    }

    private static let scene1 = MotionSceneSpec(name: "hook", dur: 3, code: """
        api.cam(0, 0, 1 + 0.3 * api.ease(t / 3));
        c.fillStyle = "#ff6b8b"; c.beginPath(); c.arc(api.w / 2, api.h / 2, 60 + 20 * Math.sin(t * 3), 0, 6.2832); c.fill();
        api.say("Everything is a string", 0.3, 2.6);
        api.hit("ball", api.w / 2, api.h / 2, 60);
        """)
    private static let scene2 = MotionSceneSpec(name: "dive", dur: 2, code: """
        const w = api.pts.wave(40, api.w - 80, 40 * api.eout(t / 1), t * 4);
        api.cam(0, 0, 1); c.translate(api.w / 2, api.h / 2); c.strokeStyle = "#f6eef7"; c.lineWidth = 4; api.path(w, false); c.stroke();
        api.say("Hum", 0.2, 1.8);
        """)

    func testFilmPlaysThroughTheRealHarness() async throws {
        let c = MotionController(); let w = host(c); _ = w
        c.addScene(Self.scene1)
        await waitFor(c, "first frame") { c.hasFirstFrame }
        XCTAssertEqual(c.phase, .playing)
        XCTAssertLessThan(c.firstFrameSeconds ?? 99, 3, "scene 1 is on screen inside the watchdog window")
        c.addScene(Self.scene2); c.end()
        await waitFor(c, "cues from both scenes") { c.cues.count == 2 }
        XCTAssertEqual(c.cues.map(\.text), ["Everything is a string", "Hum"])
        XCTAssertEqual(c.cues[1].from, 3.2, accuracy: 0.31, "scene 2's cue is in film time (it starts at 3 s)")
        await waitFor(c, "timeline of 5 s") { abs(c.total - 5) < 0.01 }
        await waitFor(c, "the film ends", timeout: 12) { c.phase == .ended }
        XCTAssertEqual(c.time, 5, accuracy: 0.3)
        // Replay and scrub both move the film clock.
        c.replay()
        await waitFor(c, "back to playing from the start") { c.phase == .playing && c.time < 2 }
        c.pause(); c.seek(4)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(c.phase, .paused)
        c.stop()
    }

    func testABrokenSceneOnTheFirstFrameFallsBack() async throws {
        let c = MotionController(); let w = host(c); _ = w
        var told: String?
        c.onFailure = { told = $0 }
        c.addScene(MotionSceneSpec(name: "bad", dur: 3, code: "this is ( not js"))
        await waitFor(c, "fallback") { c.isFailed }
        XCTAssertEqual(told, "bad: scene does not parse")
        c.stop()
    }

    func testAThrowingSceneIsCutAndTheFilmGoesOn() async throws {
        let c = MotionController(); let w = host(c); _ = w
        c.addScene(Self.scene1)
        await waitFor(c, "first frame") { c.hasFirstFrame }
        c.addScene(MotionSceneSpec(name: "oops", dur: 1, code: "nope.nothing();"))
        c.end()
        await waitFor(c, "the film still ends", timeout: 12) { c.phase == .ended }
        XCTAssertFalse(c.isFailed)
        c.stop()
    }

    func testNoFirstFrameInThreeSecondsFallsBack() async throws {
        // Never attached to a window: the page never paints, so no first frame.
        let c = MotionController()
        var told: String?
        c.onFailure = { told = $0 }
        c.addScene(Self.scene1)
        await waitFor(c, "watchdog", timeout: 8) { c.isFailed }
        XCTAssertEqual(told, MotionWatchdog.noFirstFrame)
        c.stop()
    }

    func testTheBoxHasNoNetwork() async throws {
        let c = MotionController(); let w = host(c); _ = w
        c.addScene(MotionSceneSpec(name: "net", dur: 2, code: """
            if (!window.__t) { window.__t = 1;
              fetch("https://example.com/x").then(() => { window.__net = "open"; }).catch(() => { window.__net = "blocked"; });
              const i = new Image(); i.onload = () => { window.__img = "loaded"; }; i.onerror = () => { window.__img = "blocked"; }; i.src = "https://example.com/a.png";
            }
            """))
        await waitFor(c, "first frame") { c.hasFirstFrame }
        try await Task.sleep(for: .seconds(2))
        let net = try? await c.web.evaluateJavaScript("String(window.__net) + '/' + String(window.__img)") as? String
        XCTAssertEqual(net, "blocked/blocked")
        let ls = try? await c.web.evaluateJavaScript("typeof localStorage === 'undefined' ? 'none' : (()=>{try{localStorage.setItem('a','b');return 'open'}catch(e){return 'blocked'}})()") as? String
        XCTAssertNotEqual(ls, "open", "no storage that outlives the film")
        c.stop()
    }

    func testSnapshotOfAFrame() async throws {
        let c = MotionController(); let w = host(c); _ = w
        c.addScene(Self.scene1); c.addScene(Self.scene2); c.end()
        await waitFor(c, "first frame") { c.hasFirstFrame }
        try await Task.sleep(for: .milliseconds(1200))
        // The canvas itself: a WKWebView snapshot of a GPU canvas can come back white in a test host.
        let url = try await c.web.evaluateJavaScript("document.getElementById('cv').toDataURL('image/png')") as? String ?? ""
        let png = Data(base64Encoded: String(url.dropFirst("data:image/png;base64,".count))) ?? Data()
        XCTAssertGreaterThan(png.count, 1000)
        if let dir = ProcessInfo.processInfo.environment["MOTION_SHOTS"] ?? (try? String(contentsOfFile: "/tmp/yui-motion-shots-dir", encoding: .utf8)) {
            let d = dir.trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
            try? png.write(to: URL(fileURLWithPath: d + "/motion-frame.png"))
        }
        // Not blank: the middle of the frame is the pink ball.
        let rgb = try await c.web.evaluateJavaScript("(()=>{const k=document.getElementById('cv'),d=k.getContext('2d').getImageData(k.width/2,k.height/2,1,1).data;return [d[0],d[1],d[2]]})()") as? [Int] ?? [0, 0, 0]
        XCTAssertGreaterThan(rgb[0], 150, "the ball is drawn")
        c.stop()
    }
}
