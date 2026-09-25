import XCTest
@testable import Yui

/// Presence per agent (YUI-64): the list's `presence` decodes to a liveness,
/// not_listening included, and the step left is the exact command for its profile.
final class PresenceTests: XCTestCase {
    func agent(_ json: String) throws -> YuiAgent {
        try JSONDecoder().decode(YuiAgent.self, from: Data("""
        {"id": "a1", "name": "Bravo", "handle": "bravo", "color": "mint", "kind": "hermes",
         "is_default": false, "sort": 0, \(json)}
        """.utf8))
    }

    func testNotListeningDecodes() throws {
        let a = try agent(#""status": "connected", "presence": "not_listening", "remote_ref": "bravo""#)
        XCTAssertEqual(a.liveness, .notListening)
        XCTAssertEqual(a.liveness.spoken, "not listening yet")
        XCTAssertEqual(Mentions.presence(a), "Not listening yet")
    }

    /// A server that doesn't send presence, or a value this build doesn't know,
    /// falls back to the per-computer status.
    func testFallsBackToStatus() throws {
        XCTAssertEqual(try agent(#""status": "connected""#).liveness, .online)
        XCTAssertEqual(try agent(#""status": "connected", "presence": "dreaming""#).liveness, .online)
        XCTAssertEqual(try agent(#""status": "pending""#).liveness.spoken, "offline")
        XCTAssertEqual(try agent(#""status": "offline", "presence": "asleep""#).liveness.spoken, "asleep")
    }

    func testRestartCommandNamesTheProfile() throws {
        XCTAssertEqual(try agent(#""status": "connected", "remote_ref": "bravo""#).restartCommand,
                       "hermes -p bravo gateway restart")
        XCTAssertEqual(try agent(#""status": "connected", "remote_ref": "default""#).restartCommand,
                       "hermes gateway restart")
        XCTAssertEqual(try agent(#""status": "pending""#).restartCommand, "hermes gateway restart")
    }
}
