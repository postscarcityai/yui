import XCTest
import YuiLines
@testable import Yui

/// Every agent's own quiet visual (YUI-180, yuigui spec/VISUAL.md section 6): the defaults
/// resolve, the agent's own line wins, `visual off` sticks, the person's switch beats all,
/// and a default stays quiet.
final class VisualDefaultTests: XCTestCase {
    private func agent(_ handle: String, kind: String = "hosted", visual: VisualDefault? = nil) -> YuiAgent {
        YuiAgent(id: "t-\(handle)", name: handle, handle: handle, color: "mint", kind: kind, status: .connected,
                 isDefault: false, sort: 0, visual: visual)
    }

    private func plan(_ d: VisualDefault, words: Bool = false, motion: MotionLook = .characters["calm"]!, thermal: ProcessInfo.ThermalState = .nominal) -> VisualPlan {
        VisualPlan(d.line, accent: "#FF7E8A", ground: "#231D33", ink: "#F6EEF7", motion: motion, words: words, thermal: thermal, quiet: d)!
    }

    func testTheCrewsPicksMatchTheSpec() {
        let want: [String: (String, String, String)] = [
            "yui": ("orb", "voice", "dim"), "arnold": ("orb", "music", "dim"), "basil": ("orb", "voice", "dim"),
            "gouda": ("orb", "music", "dim"), "penny": ("orb", "off", "faint"), "quill": ("orb", "voice", "faint"),
        ]
        for (h, w) in want {
            let d = VisualDefault.of(agent(h))
            XCTAssertEqual(d.look, w.0, h); XCTAssertEqual(d.hears, w.1, h); XCTAssertEqual(d.strength, w.2, h)
            XCTAssertNotEqual(d.pace, "quick", h)
        }
    }

    func testTheListsPickWinsOverTheCrewTableAndEveryoneElseGetsTheSoftOrb() {
        let own = VisualDefault(look: "aurora", hears: "mic", strength: "dim", pace: "even")
        var blob = own
        blob.look = "orb"
        XCTAssertEqual(VisualDefault.of(agent("arnold", visual: own)), blob, "the list's hearing, strength and pace; the blob's look (YUI-232)")
        XCTAssertEqual(VisualDefault.of(agent("hermes", kind: "hermes")), .fallback)
        XCTAssertEqual(VisualDefault.of(agent("arnold", kind: "hermes")), .fallback, "a paired agent named like the crew is not the crew")
        XCTAssertEqual(VisualDefault.of(nil), .fallback)
        XCTAssertEqual(VisualDefault.fallback.look, "orb")
        XCTAssertEqual(VisualDefault.fallback.strength, "faint")
    }

    func testTheListDecodesTheVisualField() throws {
        let json = #"{"id":"a","name":"A","handle":"a","color":"mint","kind":"hosted","status":"connected","is_default":false,"sort":0,"visual":{"look":"bloom","hears":"voice","strength":"dim","pace":"slow","tone":"accent","line":"visual bloom"}}"#
        let a = try JSONDecoder().decode(YuiAgent.self, from: Data(json.utf8))
        XCTAssertEqual(a.visual?.look, "bloom")
        let old = #"{"id":"a","name":"A","handle":"a","color":"mint","kind":"hosted","status":"connected","is_default":false,"sort":0}"#
        XCTAssertNil(try JSONDecoder().decode(YuiAgent.self, from: Data(old.utf8)).visual)
    }

    func testWhoWins() {
        let def = VisualDefault.crew["penny"]!
        let said = YLVisual(look: "waves", tone: nil, react: "music")
        // nothing said: the default, quiet
        XCTAssertEqual(StageVisualChoice.choose(default: def, said: nil, saidAny: false, personOff: false), .quiet(def))
        // a line beats the default
        XCTAssertEqual(StageVisualChoice.choose(default: def, said: said, saidAny: true, personOff: false), .said(said))
        // `visual off` sticks: said, but nothing now
        XCTAssertEqual(StageVisualChoice.choose(default: def, said: nil, saidAny: true, personOff: false), .none)
        // the person's switch beats everything
        XCTAssertEqual(StageVisualChoice.choose(default: def, said: said, saidAny: true, personOff: true), .none)
        XCTAssertEqual(StageVisualChoice.choose(default: def, said: nil, saidAny: false, personOff: true), .none)
    }

    func testTheThreadsVisualOffIsRemembered() {
        let on = YuiLines.parse("visual aurora")
        let off = YuiLines.parse("visual off")
        let lines = (on + off).filter { $0.op == .visual }
        XCTAssertEqual(lines.count, 2)
        XCTAssertNil(YuiLines.visual(of: lines))
        XCTAssertFalse(lines.isEmpty, "said, so the default stays away")
    }

    func testThePersonSwitchIsPerAgentAndOnByDefault() {
        let d = UserDefaults(suiteName: "visual-switch-test")!
        d.removePersistentDomain(forName: "visual-switch-test")
        XCTAssertFalse(VisualSwitch.isOff("a", in: d))
        VisualSwitch.set(on: false, for: "a", in: d)
        XCTAssertTrue(VisualSwitch.isOff("a", in: d))
        XCTAssertFalse(VisualSwitch.isOff("b", in: d))
        VisualSwitch.set(on: true, for: "a", in: d)
        XCTAssertFalse(VisualSwitch.isOff("a", in: d))
        XCTAssertNil(d.object(forKey: VisualSwitch.key("a")), "on stores nothing")
    }

    func testADefaultIsQuiet() {
        let dim = plan(VisualDefault.crew["yui"]!)
        XCTAssertEqual(dim.dim, 0.7, accuracy: 1e-9)
        XCTAssertEqual(plan(VisualDefault.crew["quill"]!).dim, 0.45, accuracy: 1e-9)
        // behind words it sinks again by 0.7
        XCTAssertEqual(plan(VisualDefault.crew["yui"]!, words: true).dim, 0.49, accuracy: 1e-9)
        XCTAssertEqual(plan(VisualDefault.crew["quill"]!, words: true).dim, 0.315, accuracy: 1e-9)
        for (_, d) in VisualDefault.crew {
            let p = plan(d)
            XCTAssertLessThan(p.dim, 1)
            XCTAssertEqual(p.fps, 30, "30 fps alone or behind words")
            XCTAssertEqual(p.idleFps, 15, "15 while nothing is heard")
            XCTAssertTrue(p.quiet)
        }
        // a said visual is as before: full alone, 60 fps
        let said = VisualPlan(YLVisual(look: "orb"), accent: "#FF7E8A", ground: "#231D33", ink: "#F6EEF7", motion: .characters["calm"]!)!
        XCTAssertEqual(said.dim, 1); XCTAssertEqual(said.fps, 60); XCTAssertEqual(said.idleFps, 60); XCTAssertFalse(said.quiet)
    }

    func testTheSlowerPaceWins() {
        let slow = VisualDefault(look: "orb", hears: "voice", strength: "dim", pace: "slow")
        let even = VisualDefault(look: "orb", hears: "voice", strength: "dim", pace: "even")
        let snappy = MotionLook.characters["snappy"]!
        XCTAssertEqual(plan(slow, motion: snappy).speed, 1 / 1.4, accuracy: 1e-9, "the default's slow beats a quick agent")
        XCTAssertEqual(plan(even, motion: MotionLook.characters["calm"]!).speed, 1 / 1.4, accuracy: 1e-9, "a calm agent beats an even default")
        XCTAssertEqual(plan(even, motion: MotionLook.characters["bouncy"]!).speed, 1, accuracy: 1e-9)
        let quick = VisualDefault(look: "orb", hears: "voice", strength: "dim", pace: "quick")
        XCTAssertEqual(quick.motionPace, .slow, "a default never runs quick")
    }

    func testAFullStrengthDefaultIsRefused() {
        let full = VisualDefault(look: "orb", hears: "voice", strength: "full", pace: "slow")
        XCTAssertLessThanOrEqual(full.level, 0.7)
    }

    func testTheStillsStayStill() {
        let d = VisualDefault.crew["arnold"]!
        XCTAssertTrue(plan(d, motion: .still).still)
        XCTAssertEqual(plan(d, motion: .still).idleFps, 0)
        XCTAssertEqual(plan(d, thermal: .serious).fps, 0)
    }

    func testPennyHearsNothingAndSoStaysOnItsOwn() {
        let p = plan(VisualDefault.crew["penny"]!)
        XCTAssertEqual(p.env, .still)
        XCTAssertEqual(p.react, "off")
    }
}
