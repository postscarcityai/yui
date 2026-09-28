import XCTest
@testable import Yui

/// The first-launch demo (YUI-145) plays the crew as yui_native_provision makes it: the
/// same starters, in the same order, each opening on its first.yui word for word.
@MainActor final class FirstLaunchDemoTests: XCTestCase {
    private let profiles = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appending(path: "runtime/profiles")

    func testFirstMessagesMatchTheProfiles() throws {
        for a in AgentStore.demoStarters {
            let dir = profiles.appending(path: a.handle)
            let first = try String(contentsOf: dir.appending(path: "first.yui"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(AgentStore.demoFirst[a.handle], first, "\(a.handle): first.yui changed, copy it into AgentStore.demoFirst")
            let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appending(path: "profile.json"))) as? [String: Any]
            XCTAssertEqual(meta?["name"] as? String, a.name)
            XCTAssertEqual(meta?["role"] as? String, AgentStore.demoRoles[a.handle])
            XCTAssertEqual(meta?["color"] as? String, a.color)
            XCTAssertEqual(meta?["tagline"] as? String, a.tagline, "\(a.handle): tagline changed, copy it into AgentStore.demoSaid")
            XCTAssertEqual(meta?["about"] as? String, a.about, "\(a.handle): about changed, copy it into AgentStore.demoSaid")
            XCTAssertEqual(meta?["can"] as? [String], a.can, "\(a.handle): can changed, copy it into AgentStore.demoSaid")
        }
    }

    func testCrewOfferMarksWhoIsInTheList() {
        let without = AgentStore.demoStarters.filter { $0.handle != "basil" }
        let offer = AgentStore.crewOffer(without)
        XCTAssertEqual(offer.map(\.base), ["yui", "arnold", "basil", "gouda", "penny", "quill"])
        XCTAssertNil(offer.first { $0.base == "basil" }?.agentID)
        XCTAssertEqual(offer.first { $0.base == "yui" }?.agentID, "demo-yui")
        XCTAssertEqual(AgentStore.demoStarters.filter(\.isDefault).map(\.handle), ["yui"], "Yui is the default agent")
    }

    func testCrewDecodesFromTheListReply() throws {
        let json = #"{"base": "basil", "name": "Basil", "role": "Nutritionist", "color": "mint", "agent_id": null}"#
        let s = try JSONDecoder().decode(CrewStarter.self, from: Data(json.utf8))
        XCTAssertEqual(s.name, "Basil")
        XCTAssertNil(s.agentID)
    }

    /// Old builds read the list with the fields they know; the new ones ride along (YUI-165).
    func testCrewStillDecodesWithWhatEachStarterDoes() throws {
        let json = #"{"base": "basil", "name": "Basil", "role": "Nutritionist", "color": "mint", "agent_id": null, "tagline": "Eat better without counting everything", "about": "Meals and swaps.", "can": ["Plan my meals this week", "What should I eat tonight?", "Check a photo of my plate"]}"#
        let s = try JSONDecoder().decode(CrewStarter.self, from: Data(json.utf8))
        XCTAssertEqual(s.name, "Basil")
    }

    /// An agent's hello (Gouda's beat and its pick) is an answer on the stage, never
    /// "1 thing is waiting on you" in Review (YUI-165, Chris on build 244).
    func testTheHelloIsNotWaitingOnYou() {
        let at = ISO8601DateFormatter().string(from: .now)
        let hello = ThreadRow(id: "first-gouda", sender: "agent", body: AgentStore.demoFirst["gouda"]!, kind: "text",
                              meta: .object(["native": .string("first")]), createdAt: at)
        let store = ChatStore()
        store.load([hello])
        XCTAssertTrue(store.messages.contains { $0.yl != nil }, "the beat and the pick are on screen")
        XCTAssertEqual(store.awaitingYou.count, 0)
        XCTAssertEqual(store.waitingCount, 0)
        // A later reply that asks something still counts.
        let ask = ThreadRow(id: "r2", sender: "agent", body: "Which one?\n```yui\nchoose \"Tempo?\" 80|92|110\n```",
                            kind: "text", meta: nil, createdAt: at)
        store.load([hello, ask])
        XCTAssertEqual(store.awaitingYou.map(\.ask.preset), ["choose"])
    }

    /// A native agent's row carries what it does (YUI-167); a paired one without it still decodes.
    func testAgentDecodesWhatItDoes() throws {
        let base = #""id": "a1", "name": "Arnold", "handle": "arnold", "color": "butter", "kind": "hosted", "status": "connected", "is_default": false, "sort": 1"#
        let said = try JSONDecoder().decode(YuiAgent.self, from: Data(("{" + base + #", "tagline": "Workouts built around your week and body", "about": "A week.", "can": ["Build my training week", " ", "Log today's workout", "One", "Two"]}"#).utf8))
        XCTAssertEqual(said.line, "Workouts built around your week and body")
        XCTAssertEqual(said.starters, ["Build my training week", "Log today's workout", "One"])
        let quiet = try JSONDecoder().decode(YuiAgent.self, from: Data(("{" + base + #", "tagline": null, "can": []}"#).utf8))
        XCTAssertNil(quiet.line)
        XCTAssertEqual(quiet.starters, [])
    }

    /// The hello plays on the stage the first time the thread opens (YUI-167, Chris on build 244:
    /// "when I got to his screen for the first time, all it showed me was a blank screen").
    func testTheHelloPlaysOnceOnTheStage() {
        let at = ISO8601DateFormatter().string(from: .now)
        let hello = ThreadRow(id: "first-arnold", sender: "agent", body: AgentStore.demoFirst["arnold"]!, kind: "text",
                              meta: .object(["native": .string("first")]), createdAt: at)
        let store = ChatStore()
        store.load([hello])
        let model = StageFirstModel()
        model.memory = []
        XCTAssertTrue(model.meet(store.messages, agent: "a1"))
        let t = model.turn(store.messages)
        XCTAssertEqual(t?.hello, true)
        XCTAssertNil(t?.ask)
        XCTAssertEqual(t?.chunks.first?.line, "Arnold here. Let's build a week you'll actually do. Anything hurting or any health condition I should plan around? Check with your doctor before starting if so.")
        XCTAssertEqual(t?.plan?.c.preset, "plan", "the plan's questions come last, one Send")
        XCTAssertEqual(t?.questions.count, 5, "days, which days, the split, gear, injuries (YUI-168)")
        // Back to the greeting, then opened again: it has been seen.
        model.home()
        XCTAssertNil(model.turn(store.messages))
        XCTAssertFalse(model.meet(store.messages, agent: "a1"))
        // Something they said: the turn is theirs, and a thread they already talked in never replays it.
        model.follow("u1")
        XCTAssertNotEqual(model.turn(store.messages)?.hello, true)
        let fresh = StageFirstModel()
        fresh.memory = []
        let said = ThreadRow(id: "u1", sender: "user", body: "Hi", kind: "text", meta: nil, createdAt: at)
        store.load([hello, said])
        XCTAssertFalse(fresh.meet(store.messages, agent: "a1"))
        // A thread with no hello has nothing to play.
        store.load([said])
        XCTAssertFalse(fresh.meet(store.messages, agent: "a1"))
    }
}
