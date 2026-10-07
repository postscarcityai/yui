import XCTest
@testable import Yui

/// What the agent hears when a film ends and the person taps Another take (YUI-320).
final class MotionEndLineTests: XCTestCase {
    func testAnotherTakeLineNamesTheFilmAndTheAsk() {
        let e = MotionEnd.again(film: "m7", title: "How a heart pumps blood")
        XCTAssertEqual(e.line, "[yui] m7 motion again note=\"make this film again, a different take, same ask\" title=\"How a heart pumps blood\"")
        XCTAssertEqual(e.echo, "Another take")
        XCTAssertTrue(e.relays, "the tap goes to the agent as a turn")
    }
}
