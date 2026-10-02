import XCTest
@testable import Yui

/// Speak to fill a form (NOTE-40679): what a field's mic heard goes after what the field held.
@MainActor
final class FieldMicTests: XCTestCase {
    func testHeardWordsFillAnEmptyField() {
        XCTAssertEqual(FieldMic.join("", "  Chris Johnston "), "Chris Johnston")
    }

    func testHeardWordsGoAfterWhatWasThere() {
        XCTAssertEqual(FieldMic.join("Oat milk", "and eggs"), "Oat milk. And eggs")
        XCTAssertEqual(FieldMic.join("Oat milk,", "eggs"), "Oat milk, eggs")
        XCTAssertEqual(FieldMic.join("Call the dentist.", "Pay the water bill"), "Call the dentist. Pay the water bill")
    }

    func testNothingHeardLeavesTheFieldAlone() {
        XCTAssertEqual(FieldMic.join("Oat milk", "   "), "Oat milk")
        XCTAssertEqual(FieldMic.join("", ""), "")
    }
}
