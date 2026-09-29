import XCTest
import YuiLines
@testable import Yui

/// Hold the icon (YUI-191): which shortcuts show, in what order, and never more than four.
@MainActor
final class QuickActionsTests: XCTestCase {
    private func cand(_ agent: String, _ id: String) -> QuickCandidate {
        QuickCandidate(agentID: agent, agentName: agent.capitalized, item: YLMenuItem(id: id, label: id, say: id))
    }

    private var all: [QuickCandidate] {
        [cand("basil", "log-food"), cand("basil", "plan"), cand("basil", "groceries"),
         cand("arnold", "log"), cand("arnold", "workout"),
         cand("penny", "todo")]
    }

    func testTheDefaultTakesOnePerAgentBeforeAnyAgentGetsTwo() {
        let shown = QuickActions.pick(all, picks: nil, used: [:]).map(\.id)
        XCTAssertEqual(shown, ["basil/log-food", "arnold/log", "penny/todo", "basil/plan"])
    }

    func testNewestUsedGoesFirst() {
        let used = ["arnold/workout": Date(timeIntervalSince1970: 200), "penny/todo": Date(timeIntervalSince1970: 100)]
        let shown = QuickActions.pick(all, picks: nil, used: used).map(\.id)
        XCTAssertEqual(shown.first, "arnold/workout")
        XCTAssertEqual(shown[1], "penny/todo")
        XCTAssertEqual(shown.count, 4)
    }

    func testNeverMoreThanFour() {
        let many = (0..<12).map { cand("a\($0 % 3)", "s\($0)") }
        XCTAssertEqual(QuickActions.pick(many, picks: nil, used: [:]).count, 4)
        let picks = many.map(\.id)
        XCTAssertEqual(QuickActions.pick(many, picks: picks, used: [:]).count, 4)
    }

    func testThePersonsPicksWinInTheirOrder() {
        let shown = QuickActions.pick(all, picks: ["penny/todo", "basil/groceries"], used: ["arnold/log": .now]).map(\.id)
        XCTAssertEqual(shown, ["penny/todo", "basil/groceries"])
    }

    func testAPickThatLeftTheDrawerDrops() {
        let shown = QuickActions.pick(all, picks: ["basil/gone", "arnold/log"], used: [:]).map(\.id)
        XCTAssertEqual(shown, ["arnold/log"])
    }

    func testAnEmptyPickShowsNothingNotTheDefault() {
        XCTAssertTrue(QuickActions.pick(all, picks: [], used: [:]).isEmpty)
    }

    func testOnlyTheAgentsThePersonHasContribute() {
        let mine = [AgentStore.demo[0]]
        let menu: (String) -> AgentMenu = { id in
            var m = AgentMenu()
            m.apply([YLNode(op: .menu, screen: "1", id: "s", props: ["bucket": .string("shortcut"), "label": .string("Say hi")], line: "")], at: .now)
            _ = id
            return m
        }
        let got = QuickActions.candidates(agents: mine, menu: menu)
        XCTAssertEqual(got.map(\.agentID), [mine[0].id])
        XCTAssertTrue(QuickActions.candidates(agents: [], menu: menu).isEmpty)
    }

    func testTheKeywordPicksASymbol() {
        XCTAssertEqual(QuickActions.symbol(for: YLMenuItem(id: "a", label: "Log food", say: "Log food: ")), "fork.knife")
        XCTAssertEqual(QuickActions.symbol(for: YLMenuItem(id: "b", label: "Hello")), "bubble.left")
    }
}
