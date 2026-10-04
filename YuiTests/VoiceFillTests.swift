import XCTest
import YuiLines
@testable import Yui

/// Speak to fill a form (feedback AKNFDrNVFCY4IO44-4fjAnc: "I should be able to just speak in my
/// answers and it fills it out for me"). The fields are the Client website intake flow's.
final class VoiceFillTests: XCTestCase {
    private func field(_ key: String, _ label: String, _ type: String = "text", options: [String] = [], required: Bool = false) -> FormField {
        var o: [String: YLValue] = ["key": .string(key), "label": .string(label), "type": .string(type), "required": .bool(required)]
        if !options.isEmpty { o["options"] = .array(options.map(YLValue.string)) }
        return FormField(.object(o))!
    }

    private var intake: [FormField] {
        [field("business_name", "Business name", required: true), field("what_you_do", "What you do", "long"),
         field("who_it_is_for", "Who it is for")]
    }

    func testEachAnswerLandsInItsField() {
        let got = VoiceFill.fill("Business name is Acme Bakery. What you do, we bake sourdough and pastries. Who it's for, people in the neighborhood.",
                                 into: intake)
        XCTAssertEqual(got["business_name"], .string("Acme Bakery"))
        XCTAssertEqual(got["what_you_do"], .string("We bake sourdough and pastries."))
        XCTAssertEqual(got["who_it_is_for"], .string("People in the neighborhood"))
    }

    func testAFieldLeftOutIsLeftAlone() {
        let got = VoiceFill.fill("business name Acme Bakery", into: intake)
        XCTAssertEqual(got, ["business_name": .string("Acme Bakery")])
    }

    func testWordsBeforeTheFirstNameGoToTheFirstEmptyField() {
        let got = VoiceFill.fill("Acme Bakery. What you do is bake bread.", into: intake)
        XCTAssertEqual(got["business_name"], .string("Acme Bakery"))
        XCTAssertEqual(got["what_you_do"], .string("Bake bread."))
    }

    func testNoFieldNameFillsTheFirstEmptyTextField() {
        var held: [String: YLValue] = ["business_name": .string("Acme")]
        let got = VoiceFill.fill("we bake bread", into: intake, current: held)
        XCTAssertEqual(got, ["what_you_do": .string("We bake bread")])
        held = [:]
        XCTAssertEqual(VoiceFill.fill("we bake bread", into: intake, current: held), ["business_name": .string("We bake bread")])
    }

    func testChoiceYesNumberAndEmail() {
        let fields = [field("kind", "What are we building", "choice", options: ["New site", "Redesign", "Shop", "Landing page"]),
                      field("logo", "Logo", "yes"), field("budget", "Budget", "range"), field("email", "Email", "email")]
        let got = VoiceFill.fill("I want a landing page. No logo. Budget is 12. Email is ann at acme dot com", into: fields)
        XCTAssertEqual(got["kind"], .string("Landing page"))
        XCTAssertEqual(got["logo"], .bool(false))
        XCTAssertEqual(got["budget"], .number(5))
        XCTAssertEqual(got["email"], .string("ann@acme.com"))
        XCTAssertEqual(VoiceFill.fill("we have a logo", into: [field("logo", "Logo", "yes")])["logo"], .bool(true))
    }

    func testNothingHeardFillsNothing() {
        XCTAssertTrue(VoiceFill.fill("   ", into: intake).isEmpty)
        XCTAssertFalse(VoiceFill.canFill([field("p", "Photo", "photo")]))
        XCTAssertTrue(VoiceFill.canFill(intake))
    }
}
