import XCTest
import YuiLines
@testable import Yui

/// The visual's plan (YUI-124 step 2): colors, scrim, envelopes, the follower, the
/// level and the whole plan, against yuigui site/lib/yl/visual.mjs.
/// Resources/visual-plan.json comes from `node scripts/visual-plan-fixture.mjs <yuigui>`.
final class VisualPlanTests: XCTestCase {
    static let yuiDark = (ground: "#231D33", ink: "#F6EEF7")
    static let yuiLight = (ground: "#FFF9F0", ink: "#3A3340")

    private func fixture() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "visual-plan", withExtension: "json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testThreeColorsAndTheScrimForEverySetInBothAppearances() throws {
        let rows = try XCTUnwrap(fixture()["colors"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 66)
        for r in rows {
            let dark = r["dark"] as! Bool
            let g = dark ? Self.yuiDark : Self.yuiLight
            let c = VisualPlan.colors(r["tone"] as! String, ground: g.ground, ink: g.ink)
            let what = "\(r["tone"]!) \(dark ? "dark" : "light")"
            XCTAssertEqual(c.a, r["a"] as? String, what)
            XCTAssertEqual(c.b, r["b"] as? String, what)
            XCTAssertEqual(c.c, r["c"] as? String, what)
            XCTAssertEqual(VisualPlan.scrim(c, dim: VisualPlan.Budget.behindDim), r["scrim"] as! Double, accuracy: 1e-9, what)
        }
    }

    func testTheScrimKeepsTheInkReadableOverTheWorstPixel() {
        for (name, r) in AgentLook.sets {
            for g in [Self.yuiDark, Self.yuiLight] {
                let c = VisualPlan.colors(r.accent, ground: g.ground, ink: g.ink)
                let a = VisualPlan.scrim(c, dim: VisualPlan.Budget.behindDim)
                let ground = RGB(hex: g.ground)!, ink = RGB(hex: g.ink)!
                for hex in [c.a, c.b, c.c] {
                    let x = RGB(hex: hex)!, d = VisualPlan.Budget.behindDim
                    let p = RGB(r: ground.r + (x.r - ground.r) * d, g: ground.g + (x.g - ground.g) * d, b: ground.b + (x.b - ground.b) * d)
                    let q = RGB(r: p.r + (ground.r - p.r) * a, g: p.g + (ground.g - p.g) * a, b: p.b + (ground.b - p.b) * a)
                    XCTAssertGreaterThanOrEqual(RGB.contrast(q, ink), 4.6, "\(name) \(hex)")
                }
            }
        }
    }

    func testEnvelopesAtEveryPace() throws {
        let rows = try XCTUnwrap(fixture()["envs"] as? [[String: Any]])
        for r in rows {
            let look = AgentLook(pace: r["pace"] as? String, pulse: r["pulse"] as? String)
            let env = VisualPlan.Envelope(MotionLook(character: "bouncy", look: look, reduced: false))
            let want = r["env"] as! [String: Double]
            let what = "\(r["pace"]!) \(r["pulse"]!)"
            XCTAssertEqual(env.attack, want["attack"], what)
            XCTAssertEqual(env.release, want["release"], what)
            XCTAssertEqual(Double(env.steps), want["steps"], what)
            XCTAssertEqual(env.gain, want["gain"], what)
        }
    }

    func testTheFollowerRisesAndFalls() throws {
        let rows = try XCTUnwrap(fixture()["follows"] as? [[String: Any]])
        let steps: [(Double, Double)] = [(0.8, 33), (0.8, 33), (0.2, 33), (0, 100), (1.5, 16), (0.5, 0)]
        for r in rows {
            let e = r["env"] as! [String: Double]
            let env = VisualPlan.Envelope(attack: e["attack"]!, release: e["release"]!, steps: Int(e["steps"]!), gain: e["gain"]!)
            var y = 0.0
            for (i, (x, dt)) in steps.enumerated() {
                y = env.follow(y, x, dt: dt)
                XCTAssertEqual(y, (r["out"] as! [Double])[i], accuracy: 1e-12, "step \(i)")
            }
        }
        XCTAssertEqual(VisualPlan.Envelope.still.follow(0.4, 1, dt: 16), 0, "still never reacts")
    }

    func testTheLevelOfABlockOfSamples() throws {
        let rows = try XCTUnwrap(fixture()["levels"] as? [[String: Any]])
        for r in rows {
            let s = (r["samples"] as! [Double]).map(Float.init)
            XCTAssertEqual(VisualPlan.level(s), r["level"] as! Double, accuracy: 1e-6, "\(s)")
        }
    }

    func testWholePlans() throws {
        let rows = try XCTUnwrap(fixture()["plans"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 8)
        for r in rows {
            let props = r["props"] as! [String: String]
            let o = r["opts"] as! [String: Any]
            let want = r["plan"] as! [String: Any]
            let theme = o["theme"] as? [String: String] ?? [:]
            let look = AgentLook(preset: theme["preset"], accent: theme["accent"], motion: theme["motion"],
                                 pace: theme["pace"], pulse: theme["pulse"])
            let motion = MotionLook(character: theme["motion"] ?? "bouncy", look: look, reduced: o["reduced"] as? Bool ?? false)
            let g = o["dark"] as? Bool ?? true ? Self.yuiDark : Self.yuiLight
            let thermal: ProcessInfo.ThermalState = switch o["thermal"] as? String {
            case "fair": .fair
            case "serious": .serious
            case "critical": .critical
            default: .nominal
            }
            let plan = try XCTUnwrap(VisualPlan(
                YLVisual(look: props["look"], tone: props["tone"], react: props["react"]),
                accent: theme["accent"] ?? "#FF7E8A", ground: g.ground, ink: g.ink, motion: motion,
                words: o["words"] as? Bool ?? false, lowPower: o["lowPower"] as? Bool ?? false,
                thermal: thermal, hidden: o["hidden"] as? Bool ?? false))
            let what = "\(props) \(o)"
            XCTAssertEqual(plan.look, want["look"] as? String, what)
            XCTAssertEqual(plan.react, want["react"] as? String, what)
            XCTAssertEqual(plan.tone, want["tone"] as? String, what)
            XCTAssertEqual(plan.speed, want["speed"] as! Double, accuracy: 1e-12, what)
            XCTAssertEqual(plan.dim, want["dim"] as? Double, what)
            XCTAssertEqual(plan.scrim, want["scrim"] as! Double, accuracy: 1e-9, what)
            XCTAssertEqual(plan.fps, want["fps"] as? Int, what)
            XCTAssertEqual(plan.scale, want["scale"] as? Double, what)
            XCTAssertEqual(plan.still, want["still"] as? Bool, what)
            XCTAssertEqual(plan.why?.rawValue, want["why"] as? String, what)
            XCTAssertEqual(plan.label, want["label"] as? String, what)
            let env = want["env"] as! [String: Double]
            XCTAssertEqual(plan.env.attack, env["attack"], what)
            XCTAssertEqual(plan.env.gain, env["gain"], what)
            let colors = want["colors"] as! [String: String]
            XCTAssertEqual([plan.colors.a, plan.colors.b, plan.colors.c], [colors["a"], colors["b"], colors["c"]].compactMap { $0 }, what)
        }
    }

    /// The app's words sit mid stage, not low like the mock's: the scrim follows them.
    func testTheScrimZoneFollowsTheWords() {
        XCTAssertEqual(VisualPlan.Zone.spec, VisualPlan.Zone(low: 0.34, high: 0.58))
        let mid = VisualPlan.Zone.under(top: 0.55)
        XCTAssertEqual(mid.low, 0.58, accuracy: 1e-9, "full scrim to just above the words")
        XCTAssertEqual(mid.high, 0.72, accuracy: 1e-9)
        XCTAssertEqual(VisualPlan.Zone.under(top: 0.1).low, 0.34, "never less than the spec's")
        XCTAssertEqual(VisualPlan.Zone.under(top: 1).high, 1, "questions: the whole stage")
    }

    func testNoVisualIsNoPlan() {
        XCTAssertNil(VisualPlan(nil, accent: "#FF7E8A", ground: "#231D33", ink: "#F6EEF7", motion: .still))
    }

    /// From real lines to the stage: the thread's newest visual wins until `visual off`.
    @MainActor func testTheThreadsNewestVisualWins() {
        func reply(_ s: String) -> ChatMessage {
            var yl = YLScreen()
            for n in YuiLines.parse(s) { yl.apply(n) }
            return ChatMessage(text: s, fromUser: false, yl: yl)
        }
        let store = ChatStore(messages: [reply("visual aurora tone=mint\nsay Breathe in."), reply("say Out.")])
        XCTAssertEqual(store.visual, YLVisual(look: "aurora", tone: "mint"))
        XCTAssertEqual(store.shown.count, 2)
        store.messages.append(reply("visual waves react=music"))
        XCTAssertEqual(store.visual, YLVisual(look: "waves", react: "music"))
        XCTAssertEqual(store.shown.count, 2, "a reply of only a visual draws no row")
        store.messages.append(reply("visual off"))
        XCTAssertNil(store.visual)
    }
}
