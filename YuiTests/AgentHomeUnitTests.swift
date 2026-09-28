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

    func testArnoldsHomeFillsChipsPagesAndShelfButNotTheRecord() {
        let store = load("arnold")
        XCTAssertEqual(AgentHome.chips(store).map(\.label), ["Start a workout", "My split"])
        XCTAssertEqual(store.screens, [1, 2, 3])
        XCTAssertTrue(store.shown.isEmpty, "the home shows in the record")
        XCTAssertTrue(store.awaitingYou.isEmpty)
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
        XCTAssertEqual(store.screens, [1, 2, 3, 4])
        XCTAssertEqual(store.onPage(2).flatMap { $0.yl?.onPage(2, style: [:]) ?? [] }.map(\.preset), ["loop"])
        XCTAssertEqual(store.onPage(4).flatMap { $0.yl?.onPage(4, style: [:]) ?? [] }.map(\.preset), ["keys"])
    }

    func testBasilsLogAMealFillsTheField() {
        let store = load("basil")
        let log = AgentHome.chips(store)[0]
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
