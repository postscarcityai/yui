import XCTest
import YuiLines
@testable import Yui

/// Stage motion (YUI-120 step 2, YUI-123 step 4): looks from
/// the agent's theme. These are yuigui site/lib/yl/motion.test.mjs's cases for
/// motionLook, motionTimings and mergeTheme.
final class StageMotionTests: XCTestCase {
    func testAReplyOfOnlyErrorsFailsTheTurn() {
        // `theme app wobble` is an error line (no set named wobble).
        let only = YLScreen("theme app wobble")
        XCTAssertFalse(only.errors.isEmpty)
        XCTAssertTrue(StageMotion.failed(only))
        XCTAssertFalse(StageMotion.failed(YLScreen("say \"Hi\"\ntheme app wobble")), "a reply with something to show did not fail")
        XCTAssertFalse(StageMotion.failed(YLScreen("say \"Hi\"")))
        XCTAssertFalse(StageMotion.failed(nil))
    }

    // MARK: Looks

    private func look(_ c: String, _ saved: AgentLook? = nil, _ custom: [String: String]? = nil, reduced: Bool = false) -> [String] {
        let l = MotionLook(character: c, look: saved, custom: custom, reduced: reduced)
        return [l.pace.rawValue, l.ease.rawValue, l.enter.rawValue, l.pulse.rawValue, l.character]
    }

    func testCharacters() {
        XCTAssertEqual(look("bouncy"), ["even", "spring", "pop", "beat", "bouncy"])
        XCTAssertEqual(look("calm"), ["slow", "float", "rise", "soft", "calm"])
        XCTAssertEqual(look("snappy"), ["quick", "sharp", "slide", "tick", "snappy"])
        XCTAssertEqual(look("wobbly").last, "bouncy", "an unknown motion is bouncy")
    }

    func testWordsOverrideKeyByKey() {
        XCTAssertEqual(look("calm", nil, ["pace": "slow", "ease": "heavy", "enter": "drop", "pulse": "beat"]),
                       ["slow", "heavy", "drop", "beat", "custom"])
        XCTAssertEqual(look("snappy", nil, ["pace": "glacial", "enter": "spin"]), ["quick", "sharp", "slide", "tick", "snappy"],
                       "unknown words are dropped")
        XCTAssertEqual(look("calm", AgentLook(motion: "calm", ease: "heavy", enter: "drop")), ["slow", "heavy", "drop", "soft", "custom"],
                       "the four keys ride on the theme")
        XCTAssertEqual(look("bouncy", AgentLook(pace: "slow"), ["pace": "quick"])[0], "quick", "a trial look wins over the saved one")
        XCTAssertEqual(look("calm", AgentLook(motion: "calm", pulse: "wobble")), ["slow", "float", "rise", "soft", "calm"])
    }

    func testReduceMotionWins() {
        let l = MotionLook(character: "snappy", look: AgentLook(pace: "quick", pulse: "beat"), custom: ["pulse": "beat"], reduced: true)
        XCTAssertEqual(l, .still)
        XCTAssertEqual(l.character, "still")
        XCTAssertEqual(l.timings, .init(enter: 0, handoff: 0, stagger: 0, beat: 0, open: 0, breath: 0))
        XCTAssertEqual(l.words, "Reduce Motion: no movement")
    }

    func testTimingsFollowThePace() {
        func t(_ c: String) -> MotionLook.Timings { MotionLook(character: c, reduced: false).timings }
        XCTAssertGreaterThan(t("calm").enter, t("bouncy").enter)
        XCTAssertLessThan(t("snappy").enter, t("bouncy").enter)
        XCTAssertGreaterThan(t("calm").breath, t("snappy").breath)
        // The numbers are motion.mjs motionTimings', in seconds.
        XCTAssertEqual(t("bouncy"), .init(enter: 0.44, handoff: 0.36, stagger: 0.08, beat: 0.6, open: 0.52, breath: 1.7))
        XCTAssertEqual(t("calm").enter, 0.616, accuracy: 0.0005)
        XCTAssertEqual(t("calm").breath, 3.96, accuracy: 0.0005)
        XCTAssertEqual(t("snappy").enter, 0.299, accuracy: 0.0005)
        XCTAssertEqual(MotionLook(character: "bouncy", custom: ["pulse": "still"], reduced: false).timings.breath, 0,
                       "pulse still does not breathe")
    }

    func testLookInPlainWords() {
        let l = MotionLook(character: "bouncy", custom: ["pace": "quick", "ease": "heavy", "enter": "drop", "pulse": "beat"], reduced: false)
        XCTAssertEqual(l.words, "quick, heavy, drops in, beats")
    }

    // MARK: Saved next to the colors (look.mjs mergeTheme)

    func testThemeLinesStack() {
        var a = AgentLook(preset: "ocean", motion: "calm").applying(["ease": "heavy"], at: nil, by: "agent")
        XCTAssertEqual([a.preset, a.motion, a.ease], ["ocean", "calm", "heavy"], "keys add to the saved look")
        a = AgentLook(accent: "#123456", motion: "calm", ease: "heavy", pulse: "beat").applying(["motion": "snappy"], at: nil, by: "agent")
        XCTAssertEqual([a.motion, a.accent, a.ease, a.pulse], ["snappy", "#123456", nil, nil], "motion= alone clears the words")
        a = AgentLook(pace: "slow").applying(["motion": "snappy", "pulse": "beat"], at: nil, by: "agent")
        XCTAssertEqual([a.pace, a.motion, a.pulse], ["slow", "snappy", "beat"], "motion= with keys keeps them")
        a = AgentLook(pace: "slow").applying(["name": "zen"], at: nil, by: "agent")
        XCTAssertEqual([a.preset, a.pace], ["zen", nil], "a set starts fresh")
        a = AgentLook().applying(["pace": "glacial", "enter": "DROP"], at: nil, by: "agent")
        XCTAssertEqual([a.pace, a.enter], [nil, "drop"], "unknown values are dropped")
    }

    func testTheLookSurvivesTheColumn() throws {
        let json = #"{"preset":"zen","pace":"quick","ease":"heavy","enter":"drop","pulse":"beat","pulse2":"x"}"#
        let a = try JSONDecoder().decode(AgentLook.self, from: Data(json.utf8))
        XCTAssertEqual([a.pace, a.ease, a.enter, a.pulse], ["quick", "heavy", "drop", "beat"])
        let back = try JSONDecoder().decode(AgentLook.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(back, a)
        XCTAssertFalse(AgentLook(pulse: "still").isEmpty)
    }

    func testTheAgentsCharacter() {
        XCTAssertEqual(AgentLook.character(nil, name: "coach"), "snappy", "a set's name picks its set")
        XCTAssertEqual(AgentLook.character(nil, name: "wizard"), "calm")
        XCTAssertEqual(AgentLook.character(nil, name: "yui", isYui: true), "bouncy")
        XCTAssertEqual(AgentLook.character(AgentLook(preset: "zen", motion: "snappy"), name: "x"), "snappy", "motion= wins over the set")
        XCTAssertEqual(AgentLook.character(AgentLook(preset: "zen"), name: "x"), "calm")
        XCTAssertTrue(AgentLook.motions.contains(AgentLook.character(nil, name: "nova")), "seeded from the name")
    }
}
