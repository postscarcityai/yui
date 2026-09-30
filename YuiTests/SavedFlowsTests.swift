import XCTest
import YuiLines
@testable import Yui

/// Saved flows and a flow's kept run (YUI-115, spec FLOWS.md sections 5, 8 and 9).
@MainActor
final class SavedFlowsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "yui-saved-flows-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testEveryStarterParsesIntoARunnableGraph() {
        XCTAssertEqual(StarterFlows.all.count, 10)
        for f in StarterFlows.all {
            let g = SavedFlows.starter(f)
            XCTAssertTrue(g.nodes.contains { $0.preset != nil }, "\(f.name) has no steps")
            XCTAssertNotNil(YuiLines.flowFirst(g), "\(f.name) has no first step")
            // Nothing answered: the path stops at the first question.
            XCTAssertNotNil(YuiLines.flowPath(g, [:]).open, "\(f.name) asks nothing")
        }
    }

    func testANameMatchesOnLettersAndDigits() {
        let d = defaults()
        for name in ["website-intake", "Website intake", "WEBSITE_INTAKE", "websiteintake"] {
            XCTAssertEqual(SavedFlows.resolve(name, in: d)?.name, "website-intake", name)
        }
        XCTAssertEqual(SavedFlows.resolve("first-plan", in: d)?.submit, "Build my week")
        XCTAssertNil(SavedFlows.resolve("no-such-flow", in: d), "an unknown name must be nil so the phone can say so")
        XCTAssertNil(SavedFlows.resolve("", in: d))
    }

    func testTheWebsiteIntakeBranchesOnTheKindOfSite() {
        let g = SavedFlows.resolve("website-intake", in: defaults())!.graph
        let shop: [String: YLValue] = ["biz": .object(["name": .string("A")]), "kind": .string("Shop")]
        XCTAssertEqual(YuiLines.flowPath(g, shop).open, "products")
        let redesign: [String: YLValue] = ["biz": .object([:]), "kind": .string("Redesign")]
        XCTAssertEqual(YuiLines.flowPath(g, redesign).open, "today")
    }

    func testAVariantIsKeptByNameAndRunsFromItsBase() {
        let d = defaults()
        let changes = YuiLines.parse("flow website-intake as=cafe-intake\ndrop pages\nend")
            .first { $0.op == .patch }?.props?["changes"]?.array ?? []
        XCTAssertFalse(changes.isEmpty)
        SavedFlows.keep(KeptVariant(name: "cafe-intake", title: "Cafe intake", base: "website-intake", changes: changes), in: d)
        let v = SavedFlows.resolve("Cafe intake", in: d)
        XCTAssertEqual(v?.title, "Cafe intake")
        XCTAssertEqual(v?.base, "website-intake")
        XCTAssertNil(v?.graph.node("pages"), "the dropped step is gone")
        XCTAssertNotNil(SavedFlows.resolve("website-intake", in: d)?.graph.node("pages"), "the base is untouched")
        // The hub's own variant.
        XCTAssertNotNil(SavedFlows.resolve("restaurant-intake", in: d)?.graph.node("menu"))
    }

    func testAVariantLoopOrAMissingBaseIsNoSavedFlow() {
        let d = defaults()
        SavedFlows.keep(KeptVariant(name: "a", title: "A", base: "b", changes: []), in: d)
        SavedFlows.keep(KeptVariant(name: "b", title: "B", base: "a", changes: []), in: d)
        SavedFlows.keep(KeptVariant(name: "c", title: "C", base: "ghost", changes: []), in: d)
        XCTAssertNil(SavedFlows.resolve("a", in: d))
        XCTAssertNil(SavedFlows.resolve("c", in: d))
    }

    func testARunSurvivesAKillAndNeverForgetsASkip() throws {
        let d = defaults()
        var run = FlowRun()
        run.events["goal"] = ["choice": .string("Get stronger")]
        run.events["days"] = ["picked": .array([.string("Mon"), .string("Wed")])]
        run.events["gear"] = FlowRun.skipped
        run.step = "time"
        run.graph = SavedFlows.resolve("first-plan", in: d)!.graph.value
        run.save("demo-1", "n2", in: d)
        let back = try XCTUnwrap(FlowRun.load("demo-1", "n2", in: d))
        XCTAssertEqual(back, run)
        XCTAssertEqual(back.step, "time")
        XCTAssertEqual(back.answers["days"], .array([.string("Mon"), .string("Wed")]))
        XCTAssertEqual(back.answers["gear"], YLValue.null, "a skipped question is on the path and answers null")
        XCTAssertEqual(YLFlowGraph(props: back.graph!.object!), run.graph.map { YLFlowGraph(props: $0.object!) })
        XCTAssertNil(FlowRun.load("demo-2", "n2", in: d), "another message has its own run")
        FlowRun.clear("demo-1", "n2", in: d)
        XCTAssertNil(FlowRun.load("demo-1", "n2", in: d))
    }

    func testAFlowEventLeavesOutSkippedAndOffPathAnswers() {
        let g = SavedFlows.resolve("first-plan", in: defaults())!.graph
        let answers: [String: YLValue] = ["goal": .string("Not sure"), "days": .array([.string("Mon")]), "time": .string("Skip"),
                                          "gear": .null, "experience": .string("Brand new"), "stray": .string("x")]
        let e = YuiLines.flowEvent(g, answers)
        XCTAssertEqual(e.path, ["goal", "days", "time", "gear", "experience"])
        XCTAssertNil(e.flow["stray"])
        XCTAssertEqual(e.flow["time"], .string("Skip"), "Skip comes back as exactly that word")
    }
}
