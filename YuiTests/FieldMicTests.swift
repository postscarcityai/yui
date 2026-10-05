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

    /// A name, a title or a search (the naming mic): what is said is the field, with no closing period.
    func testANameReplacesWhatWasThere() {
        XCTAssertEqual(FieldMic.fill("Old name", "Weekend long run.", replaces: true), "Weekend long run")
        XCTAssertEqual(FieldMic.fill("", " Nova! ", replaces: true), "Nova")
        XCTAssertEqual(FieldMic.fill("Old name", "  ", replaces: true), "Old name", "nothing heard keeps the name")
        XCTAssertEqual(FieldMic.fill("Oat milk", "and eggs", replaces: false), "Oat milk. And eggs", "a field of words still appends")
    }
}
