import XCTest
@testable import Yui

/// The Add agent sheet's wait for a gateway (YUI-192).
final class GatewayWaitTests: XCTestCase {
    func testListeningTheMomentPresenceSaysAnythingElse() {
        for l in [YuiAgent.Liveness.online, .offline, .asleep] {
            XCTAssertEqual(GatewayWait.phase(l, waited: 0), .listening)
            XCTAssertEqual(GatewayWait.phase(l, waited: 500), .listening, "late is still listening")
        }
    }

    func testWaitingThenGivingUpAfterAMinute() {
        XCTAssertEqual(GatewayWait.phase(.notListening, waited: 0), .waiting)
        XCTAssertEqual(GatewayWait.phase(.notListening, waited: 59), .waiting)
        XCTAssertEqual(GatewayWait.phase(.notListening, waited: 60), .gaveUp)
    }

    func testAskedEveryFewSeconds() {
        XCTAssertLessThanOrEqual(GatewayWait.pollEvery, .seconds(3))
    }
}
