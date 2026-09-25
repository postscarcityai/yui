import XCTest
@testable import Yui

/// Slash commands (YUI-61): what the composer suggests for a draft, what a tap
/// leaves in it, and the agent list's `commands` field. Spec: yuigui/spec/AGENTS.md.
final class SlashCommandFormatTests: XCTestCase {
    static let hermes: [AgentCommand] = [
        AgentCommand(name: "new", description: "Start a new session (fresh session ID + history)", args: "[name]"),
        AgentCommand(name: "retry", description: "Retry the last message (resend to agent)"),
        AgentCommand(name: "stop", description: "Kill all running background processes"),
        AgentCommand(name: "model", description: "Switch model (persists by default)", args: "[model]"),
        AgentCommand(name: "reload-mcp", description: "Reload MCP servers from config"),
        AgentCommand(name: "humanizer", description: "Humanize text: strip AI-isms and add real voice."),
    ]

    func testASlashAloneShowsEverything() {
        XCTAssertEqual(SlashCommands.matches("/", in: Self.hermes).map(\.name), Self.hermes.map(\.name))
    }

    func testTypingFiltersPrefixFirstThenInside() {
        XCTAssertEqual(SlashCommands.matches("/re", in: Self.hermes).map(\.name), ["retry", "reload-mcp"])
        XCTAssertEqual(SlashCommands.matches("/M", in: Self.hermes).map(\.name), ["model", "reload-mcp", "humanizer"],
                       "case-insensitive; `model` starts with m, the others contain it")
        XCTAssertEqual(SlashCommands.matches("/zzz", in: Self.hermes), [])
    }

    func testNoSuggestionsOnceTheNameIsDone() {
        XCTAssertEqual(SlashCommands.matches("/new ", in: Self.hermes), [], "a space: the person is typing arguments")
        XCTAssertEqual(SlashCommands.matches("/stop", in: Self.hermes), [], "the only fit is already typed")
        XCTAssertEqual(SlashCommands.matches("/ne", in: Self.hermes).map(\.name), ["new"])
    }

    func testOnlyAtTheStartOfTheComposer() {
        XCTAssertEqual(SlashCommands.matches("hi /new", in: Self.hermes), [])
        XCTAssertEqual(SlashCommands.matches(" /new", in: Self.hermes), [])
        XCTAssertEqual(SlashCommands.matches("/usr/bin", in: Self.hermes), [], "a path is not a command")
    }

    func testAgentsWithoutARegistryShowNothing() {
        XCTAssertEqual(SlashCommands.matches("/", in: nil), [], "MCP, OpenClaw and demo agents")
        XCTAssertEqual(SlashCommands.matches("/", in: []), [])
    }

    func testATapFillsTheCommandAndASpaceWhenItTakesArguments() {
        XCTAssertEqual(SlashCommands.fill(Self.hermes[0]), "/new ")
        XCTAssertEqual(SlashCommands.fill(Self.hermes[1]), "/retry")
        let s = SlashCommands.suggestions("/mo", in: Self.hermes)
        XCTAssertEqual(s.first?.title, "/model")
        XCTAssertEqual(s.first?.hint, "[model]")
        XCTAssertEqual(s.first?.detail, "Switch model (persists by default)")
        XCTAssertEqual(s.first?.fill, "/model ")
    }

    func testTheAgentListCarriesCommands() throws {
        let json = #"""
        {"id":"a1","name":"Yui","handle":"yui","color":"brand","avatar":"yui","kind":"hermes","connector_id":"c1",
         "connector_name":"Mac mini","remote_ref":"yui","status":"connected","last_seen_at":null,"is_default":true,"sort":0,
         "commands":[{"name":"new","description":"Start a new session","args":"[name]"},{"name":"stop","description":"Stop"}]}
        """#
        let a = try JSONDecoder().decode(YuiAgent.self, from: Data(json.utf8))
        XCTAssertEqual(a.commands, [AgentCommand(name: "new", description: "Start a new session", args: "[name]"),
                                    AgentCommand(name: "stop", description: "Stop")])
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        dict["commands"] = nil
        let older = try JSONSerialization.data(withJSONObject: dict)
        XCTAssertNil(try JSONDecoder().decode(YuiAgent.self, from: older).commands, "an older server: no suggestions")
    }
}
