import XCTest
@testable import Yui

/// `yui://settings/search` (YUI-142): the button on "Free web searches used"
/// opens Settings at Web search, where a person adds their own Firecrawl key.
@MainActor
final class SettingsLinkTests: XCTestCase {
    func section(_ s: String) -> String? { PushCenter.settingsSection(URL(string: s)!) }

    func testSettingsLinks() {
        XCTAssertEqual(section("yui://settings/search"), "search")
        XCTAssertEqual(section("yui://settings/key"), "key", "the limit card's button opens the key section")
        XCTAssertEqual(section("yui://settings"), "")
        XCTAssertEqual(section("yui://settings/"), "")
        XCTAssertEqual(section("yui://settings/nowhere"), "", "an unknown section opens Settings at the top")
    }

    func testOtherLinksAreNotSettings() {
        XCTAssertNil(section("https://www.yuigui.com/settings/search"))
        XCTAssertNil(section("yui://agent/7c9e6679-7425-40de-944b-e07fc1f90ae7"))
        XCTAssertNil(section("yui://invite/ABCDE-FGHJK"))
    }

    func testOpeningALinkLeavesItForTheChat() {
        let push = PushCenter.shared
        XCTAssertTrue(push.open(URL(string: "yui://settings/search")!))
        XCTAssertEqual(push.pendingSettings, "search")
        XCTAssertNil(push.pendingAgentID)
        push.pendingSettings = nil
    }

    func testFreeSearchesLeftReadsPlain() {
        let left = NativeStatus.Search(used: 12, limit: 50, key: nil)
        XCTAssertEqual(SearchKeyWords.left(left), "Your crew has 38 of 50 free web searches left this month. Add your own Firecrawl key for no limit.")
        let none = NativeStatus.Search(used: 50, limit: 50, key: nil)
        XCTAssertTrue(SearchKeyWords.left(none).hasPrefix("Your 50 free web searches are used up this month."))
    }

    func testStatusDecodesSearch() throws {
        let json = #"{"key":null,"providers":[],"turns":{"used":3,"limit":100},"search":{"used":4,"limit":50,"key":{"hint":"a1b2"}}}"#
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let s = try d.decode(NativeStatus.self, from: Data(json.utf8))
        XCTAssertEqual(s.search, NativeStatus.Search(used: 4, limit: 50, key: .init(hint: "a1b2")))
        let old = try d.decode(NativeStatus.self, from: Data(#"{"key":null,"providers":[],"turns":{"used":0,"limit":100}}"#.utf8))
        XCTAssertNil(old.search, "an older server leaves search out")
    }

    func testProvidersCarryTheKeyLinkAndPlanLine() throws {
        let json = #"{"key":null,"providers":[{"id":"anthropic","label":"Claude","needsModel":false,"keyUrl":"https://console.anthropic.com/settings/keys","plan":"A Claude Pro or Max plan can't pay for another app. Only an API key can."},{"id":"openrouter","label":"OpenRouter","needsModel":false}],"turns":{"used":100,"limit":100}}"#
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let s = try d.decode(NativeStatus.self, from: Data(json.utf8))
        XCTAssertEqual(s.providers[0].keyUrl, "https://console.anthropic.com/settings/keys")
        XCTAssertEqual(ModelKeyWords.plan(s.providers[0]), "A Claude Pro or Max plan can't pay for another app. Only an API key can.")
        XCTAssertNil(ModelKeyWords.plan(s.providers[1]), "a provider with no plan gets no plan line")
        XCTAssertEqual(ModelKeyWords.left(s.turns), "Yui and your crew have 0 of 100 free turns left this month. Add your own key to keep going with no limit.")
    }

    func testKeyWordsHaveNoDeveloperWords() {
        for line in [ModelKeyWords.otherRoad, ModelKeyWords.locked] {
            XCTAssertNil(line.range(of: "base url|endpoint|token|json", options: [.regularExpression, .caseInsensitive]), line)
        }
    }
}

/// Per-agent model key (YUI-139 step 2g): the payloads yui-native takes, and who the pick offers.
final class AgentKeyTests: XCTestCase {
    @MainActor func testOpPayloadsMatchTheServer() {
        let id = "9f2c7d1e-0000-4000-8000-000000000001"
        XCTAssertEqual(AgentStore.agentKeyBody(agentID: id, use: "anthropic") as NSDictionary,
                       ["action": "agent_key", "agent_id": id, "use": "anthropic"] as NSDictionary)
        XCTAssertEqual(AgentStore.agentKeyBody(agentID: id, use: "yui")["use"] as? String, "yui")
        let one = AgentStore.keySetBody(provider: "openai", key: "sk-1234", model: nil, baseURL: nil, agentID: id)
        XCTAssertEqual(one as NSDictionary, ["action": "key_set", "provider": "openai", "key": "sk-1234", "agent_id": id] as NSDictionary)
        let all = AgentStore.keySetBody(provider: "openai", key: "sk-1234", model: "", baseURL: "")
        XCTAssertNil(all["agent_id"], "a key for everyone names no agent")
        XCTAssertNil(all["model"])
        XCTAssertEqual(AgentStore.keyRemoveBody() as NSDictionary, ["action": "key_remove"] as NSDictionary)
        XCTAssertEqual(AgentStore.keyRemoveBody(provider: "anthropic") as NSDictionary,
                       ["action": "key_remove", "provider": "anthropic"] as NSDictionary)
    }

    private func status(_ json: String) throws -> NativeStatus {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(NativeStatus.self, from: Data(json.utf8))
    }

    func testStatusReadsKeysAndEachAgentsPick() throws {
        let s = try status(#"{"key":{"provider":"anthropic","hint":"ab12"},"keys":[{"provider":"anthropic","hint":"ab12","base_url":null},{"provider":"groq","hint":"zz99"}],"agent_keys":{"a1":"openai","a2":"default","a3":"yui"},"providers":[{"id":"anthropic","label":"Claude","needsModel":false},{"id":"openai","label":"ChatGPT","needsModel":false},{"id":"groq","label":"Groq","needsModel":false}],"turns":{"used":1,"limit":100}}"#)
        XCTAssertEqual(s.runsOn("a1"), "openai")
        XCTAssertEqual(s.runsOn("a2"), "anthropic", "default follows the person's default key")
        XCTAssertEqual(s.runsOn("a3"), "yui")
        XCTAssertEqual(s.runsOn("new", reported: "yui"), "yui", "no pick in status uses the Controls answer")
        let ids = KeyChoice.choices(s).map(\.id)
        XCTAssertEqual(ids, ["yui", "anthropic", "openai", "groq"], "Yui's, Claude, ChatGPT, then any other key they hold")
        XCTAssertEqual(KeyChoice.choices(s).map(\.hint), [nil, "ab12", nil, "zz99"])
        XCTAssertFalse(KeyChoice.choices(s)[2].held, "ChatGPT has no key yet, the tap adds one")
        XCTAssertTrue(KeyChoice.choices(s)[0].held)
    }

    func testAnOlderServerStillGivesTheThreeWayPick() throws {
        let s = try status(#"{"key":null,"providers":[{"id":"anthropic","label":"Claude","needsModel":false}],"turns":{"used":0,"limit":100}}"#)
        XCTAssertEqual(KeyChoice.choices(s).map(\.label), ["Yui's key", "Claude", "ChatGPT"])
        XCTAssertEqual(s.runsOn("any"), "yui")
    }
}
