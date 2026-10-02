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
        var back = try XCTUnwrap(FlowRun.load("demo-1", "n2", in: d))
        // Saving stamps the run (feedback NOTE-19357); the rest is as it was.
        XCTAssertNotNil(back.at)
        back.at = nil
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

/// My flows, the list model (YUI-238): variants nested under their base, what a Remove takes.
@MainActor
final class MyFlowsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "yui-my-flows-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func keep(_ name: String, base: String, in d: UserDefaults) {
        let changes = YuiLines.parse("flow \(base) as=\(name)\ndrop pages\nend").first { $0.op == .patch }?.props?["changes"]?.array ?? []
        SavedFlows.keep(KeptVariant(name: name, title: SavedFlows.title(ofName: name), base: base, changes: changes), in: d)
    }

    func testEveryStarterIsListedWithItsStepCount() {
        let rows = MyFlows.rows(in: defaults())
        for f in StarterFlows.all {
            let r = rows.first { $0.name == f.name }
            XCTAssertEqual(r?.starter, true, f.name)
            XCTAssertEqual(r?.depth, 0)
            XCTAssertEqual(r?.steps, SavedFlows.starter(f).nodes.filter { $0.preset != nil }.count, f.name)
            XCTAssertGreaterThan(r?.steps ?? 0, 0)
        }
    }

    func testVariantsSitUnderTheirBase() {
        let d = defaults()
        keep("cafe-intake", base: "website-intake", in: d)
        keep("tiny-cafe", base: "cafe-intake", in: d)
        let rows = MyFlows.rows(in: d)
        let at = rows.firstIndex { $0.name == "website-intake" }!
        // The base, then its variants, each with its own under it.
        XCTAssertEqual(rows.dropFirst(at + 1).prefix(3).map(\.name), ["restaurant-intake", "cafe-intake", "tiny-cafe"])
        XCTAssertEqual(rows.dropFirst(at + 1).prefix(3).map(\.depth), [1, 1, 2])
        XCTAssertEqual(rows.first { $0.name == "tiny-cafe" }?.from, "Cafe intake")
        XCTAssertEqual(rows[at].variants, 3)
        XCTAssertGreaterThan(rows.first { $0.name == "cafe-intake" }!.steps, 0)
    }

    func testAStarterCannotBeRemoved() {
        let d = defaults()
        XCTAssertTrue(MyFlows.removal(of: "website-intake", in: d).isEmpty)
        XCTAssertTrue(MyFlows.remove("first-plan", in: d).isEmpty)
        XCTAssertNotNil(SavedFlows.resolve("first-plan", in: d))
        XCTAssertNotNil(SavedFlows.resolve("website-intake", in: d))
    }

    func testAVariantGoesAlone() {
        let d = defaults()
        keep("cafe-intake", base: "website-intake", in: d)
        XCTAssertEqual(MyFlows.remove("cafe-intake", in: d), ["cafe-intake"])
        XCTAssertNil(SavedFlows.resolve("cafe-intake", in: d))
        XCTAssertNotNil(SavedFlows.resolve("restaurant-intake", in: d), "its sibling stays")
        XCTAssertNotNil(SavedFlows.resolve("website-intake", in: d), "the base stays")
    }

    func testTheHubsOwnVariantCanBeRemovedAndComesBackWhenSentAgain() {
        let d = defaults()
        XCTAssertEqual(MyFlows.remove("restaurant-intake", in: d), ["restaurant-intake"])
        XCTAssertNil(SavedFlows.resolve("restaurant-intake", in: d))
        XCTAssertFalse(MyFlows.rows(in: d).contains { $0.name == "restaurant-intake" })
        keep("restaurant-intake", base: "website-intake", in: d)
        XCTAssertNotNil(SavedFlows.resolve("restaurant-intake", in: d))
        XCTAssertTrue(MyFlows.rows(in: d).contains { $0.name == "restaurant-intake" })
    }

    func testRemovingAVariantWithVariantsTakesThemAlong() {
        let d = defaults()
        keep("cafe-intake", base: "website-intake", in: d)
        keep("tiny-cafe", base: "cafe-intake", in: d)
        keep("cafe-two", base: "cafe-intake", in: d)
        XCTAssertEqual(MyFlows.rows(in: d).first { $0.name == "cafe-intake" }?.variants, 2)
        XCTAssertEqual(Set(MyFlows.removal(of: "cafe-intake", in: d)), ["cafe-intake", "tiny-cafe", "cafe-two"])
        MyFlows.remove("cafe-intake", in: d)
        XCTAssertTrue(SavedFlows.kept(in: d).isEmpty)
        XCTAssertNotNil(SavedFlows.resolve("restaurant-intake", in: d))
    }

    func testAVariantWhoseBaseIsGoneIsListedButCannotRun() {
        let d = defaults()
        keep("lost", base: "no-such-flow", in: d)
        let r = MyFlows.rows(in: d).first { $0.name == "lost" }
        XCTAssertEqual(r?.steps, 0)
        XCTAssertEqual(MyFlows.remove("lost", in: d), ["lost"])
    }
}
