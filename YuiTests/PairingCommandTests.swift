import XCTest
@testable import Yui

/// The pairing sheet's one command (YUI-229): install, pair with the code, restart, joined so one paste does all three.
final class PairingCommandTests: XCTestCase {
    func testOneCommandHasAllThreeStepsAndTheCode() {
        XCTAssertEqual(PairingStep.command("123456"),
                       "hermes plugins install postscarcityai/yui/hermes-plugin/yui --enable && hermes yui pair 123456 && hermes gateway restart")
    }
}
