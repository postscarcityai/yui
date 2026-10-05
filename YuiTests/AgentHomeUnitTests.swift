import XCTest
import YuiLines
@testable import Yui

/// An agent's home (YUI-168, yuigui spec/HOME.md): the row yui-agents writes fills the chips,
/// the pages and the shelf, stays out of the record, and never pulls a page forward.
@MainActor final class AgentHomeUnitTests: XCTestCase {
    private let profiles = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appending(path: "runtime/profiles")

    /// The demo homes are the profiles' home.yui as the server writes them.
    func testDemoHomesMatchTheProfiles() throws {
        for a in AgentStore.demoStarters {
            let text = try String(contentsOf: profiles.appending(path: "\(a.handle)/home.yui"), encoding: .utf8)
            let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("# ") && $0 != "#" }
                .map { $0.replacingOccurrences(of: #"\{([a-z0-9-]+)\}"#, with: "demo-$1", options: .regularExpression) }
            XCTAssertEqual(AgentStore.demoHome[a.handle], "```yui\n" + lines.joined(separator: "\n") + "\n```",
                           "\(a.handle): home.yui changed, copy it into AgentStore.demoHome")
        }
    }

    private func load(_ handle: String, _ more: [ThreadRow] = []) -> ChatStore {
        let at = ISO8601DateFormatter().string(from: .now)
        let store = ChatStore()
        store.load([ThreadRow(id: "home-\(handle)", sender: "agent", body: AgentStore.demoHome[handle]!, kind: "text",
                              meta: .object(["native": .string("home")]), createdAt: at)] + more)
        return store
    }

    /// Yui's home is two chips and the chat, no page (t_5b44f121, Chris: "Remove this screen").
    func testYuisHomeIsChipsOnly() {
        let store = load("yui")
        XCTAssertEqual(AgentHome.chips(store).map(\.label), ["Add an agent", "What's new"])
        XCTAssertEqual(store.screens, [1])
        XCTAssertNil(store.shelf["your crew"])
    }

    /// The home Yui wrote before then: its crew page never forms, its chips stay.
    func testAnOldYuiHomeLosesOnlyItsCrewPage() {
        let old = "```yui\nmenu shortcut@new \"What's new\" say=\"What's new in Yui?\"\nmenu shortcut@add \"Add an agent\" say=\"Make me a new agent: \"\n>2\n"
            + "card@crew-arnold Arnold \"Workouts built around your week and body\" sub=Trainer url=yui://agent/demo-arnold/thread cta=Open\n"
            + "card@crew-basil Basil \"Eat better without counting everything\" sub=Nutritionist url=yui://agent/demo-basil/thread cta=Open\n"
            + "save your crew\n```"
        let store = ChatStore()
        store.load([ThreadRow(id: "home-yui", sender: "agent", body: old, kind: "text",
                              meta: .object(["native": .string("home")]), createdAt: "2026-09-28T10:00:00Z")])
        XCTAssertEqual(AgentHome.chips(store).map(\.label), ["Add an agent", "What's new"])
        XCTAssertEqual(store.screens, [1], "the crew page is still there")
        XCTAssertNil(store.shelf["your crew"], "the crew page is still on the shelf")
    }

    /// Only the crew lines go: a route with something else under it, and every other agent's home, stay whole.
    func testWithoutRosterKeepsEverythingElse() {
        XCTAssertEqual(ChatStore.withoutRoster(">2\ncard@crew-a A\n>3\nlist@x \"One\"\nsave your crew"), ">3\nlist@x \"One\"")
        XCTAssertEqual(ChatStore.withoutRoster(">2\nstat@s 1 One\ncard@crew-a A"), ">2\nstat@s 1 One")
        for a in AgentStore.demoStarters where a.handle != "yui" {
            let y = String(AgentStore.demoHome[a.handle]!.dropFirst(7).dropLast(4))
            XCTAssertEqual(ChatStore.withoutRoster(y), y, a.handle)
        }
    }

    /// A phone that kept the old crew page on its shelf drops it once; a "your crew" of something else stays.
    func testTheShelfDropsTheOldCrewPageOnly() {
        func shelf(_ yl: String) -> Shelf {
            let store = ChatStore()
            store.load([ThreadRow(id: "r1", sender: "agent", body: "```yui\n\(yl)\n```", kind: "text", meta: nil, createdAt: "2026-09-28T10:00:00Z")])
            return store.shelf
        }
        var crew = shelf(">2\ncard@crew-arnold Arnold \"Trains\" cta=Open\ncard@crew-basil Basil \"Feeds\" cta=Open\nsave your crew")
        XCTAssertNotNil(crew["your crew"])
        XCTAssertTrue(crew.dropRoster())
        XCTAssertNil(crew["your crew"])
        XCTAssertFalse(crew.dropRoster(), "it drops once")
        var mine = shelf(">2\nlist@team \"Sam\" \"Ana\"\nsave your crew")
        XCTAssertFalse(mine.dropRoster())
        XCTAssertNotNil(mine["your crew"])
    }

    func testArnoldsHomeFillsChipsPagesAndShelfButNotTheRecord() {
        let store = load("arnold")
        XCTAssertEqual(AgentHome.chips(store).map(\.label), ["Start a workout", "My split", "Log a workout", "Progress"])
        XCTAssertEqual(store.screens, [1, 2, 3, 4])
        XCTAssertTrue(store.shown.isEmpty, "the home shows in the record")
        XCTAssertTrue(store.awaitingYou.isEmpty, "Change a day is a tool on the home, not an ask")
        XCTAssertEqual(store.page, 1, "loading the home moved the person")
        XCTAssertNotNil(store.shelf["this week"])
        // My split goes to the live page it was saved from; Start a workout talks.
        let split = AgentHome.chips(store)[1]
        XCTAssertEqual(AgentHome.page(for: split, in: store), 2)
        XCTAssertNil(AgentHome.page(for: AgentHome.chips(store)[0], in: store))
        var went: Int?
        AgentHome.tap(split, store: store, goPage: { went = $0 }, compose: { _ in XCTFail("My split composed") })
        XCTAssertEqual(went, 2)
    }

    func testGoudasInstrumentsSitOnTheirPages() {
        let store = load("gouda")
        XCTAssertEqual(store.screens, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(store.onPage(2).flatMap { $0.yl?.onPage(2, style: [:]) ?? [] }.map(\.preset), ["loop", "choose"])
        XCTAssertEqual(store.onPage(4).flatMap { $0.yl?.onPage(4, style: [:]) ?? [] }.map(\.preset), ["keys", "choose"])
    }

    func testBasilsLogAMealFillsTheField() {
        let store = load("basil")
        let log = AgentHome.chips(store)[1]
        XCTAssertEqual(log.label, "Log a meal")
        var words: String?
        AgentHome.tap(log, store: store, goPage: { _ in XCTFail("Log a meal paged") }, compose: { words = $0 })
        XCTAssertEqual(words, "Log a meal: ")
    }

    /// Waiting on you: the thread's open asks, then the agent's review items.
    func testWaitingIsAsksThenReviewItems() {
        let at = ISO8601DateFormatter().string(from: .now)
        let store = load("arnold", [
            ThreadRow(id: "r1", sender: "agent", body: "```yui\nmenu review@max \"New squat max?\" sub=\"Easy sets\"\n```",
                      kind: "text", meta: nil, createdAt: at),
            ThreadRow(id: "r2", sender: "agent", body: "Saturday?\n```yui\n>2 choose@sat \"Legs or rest?\" Legs|Rest\n```",
                      kind: "text", meta: nil, createdAt: at),
        ])
        XCTAssertEqual(AgentHome.waiting(store).map(\.title), ["Legs or rest?", "New squat max?"])
        XCTAssertEqual(store.shown.count, 2, "only the home stays out of the record")
    }

    /// A home that lands after the person talked is not part of their answer.
    func testTheHomeIsNeverPartOfAnAnswer() {
        let at = ISO8601DateFormatter().string(from: .now)
        let store = ChatStore()
        store.load([
            ThreadRow(id: "u1", sender: "user", body: "Hi", kind: "text", meta: nil, createdAt: at),
            ThreadRow(id: "home-arnold", sender: "agent", body: AgentStore.demoHome["arnold"]!, kind: "text",
                      meta: .object(["native": .string("home")]), createdAt: at),
        ])
        XCTAssertEqual(StageChunks.turn(store.messages, ask: nil).pages, 0)
    }

    /// Yui's crew cards open an agent's thread; other app links are still dropped.
    func testAgentLinks() {
        XCTAssertEqual(PushCenter.agentTarget(URL(string: "yui://agent/demo-gouda/thread")!), "demo-gouda")
        XCTAssertEqual(PushCenter.agentTarget(URL(string: "yui://agent/a1")!), "a1")
        XCTAssertNil(PushCenter.agentTarget(URL(string: "yui://settings/search")!))
        XCTAssertNil(PushCenter.agentTarget(URL(string: "https://www.yuigui.com/agent/a1")!))
        // The crew page's links open an agent; only a hand-off jumps on arrival (YUI-144).
        XCTAssertFalse(PushCenter.isHandOff(URL(string: "yui://agent/demo-gouda/thread")!))
        XCTAssertTrue(PushCenter.isHandOff(URL(string: "yui://agent/basil")!))
    }
}
