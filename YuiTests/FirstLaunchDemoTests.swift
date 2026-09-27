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
}
