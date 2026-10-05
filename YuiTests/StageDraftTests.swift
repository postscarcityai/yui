import XCTest
import YuiLines
@testable import Yui

/// The stage's questions screen keeps typed answers (t_7e89c333): by question id, across a relaunch
/// and a thread switch, gone on Send, and never a secret.
@MainActor
final class StageDraftTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "StageDraftTests.\(UUID().uuidString)")!
        return d
    }

    private func form(_ fields: [String: YLValue]) -> YLEvent {
        YLEvent(id: "about", preset: "form", value: ["form": .object(fields)])
    }

    func testRoundTrip() {
        let d = defaults()
        StageDraft.keep("m1#3", form(["name": .string("Basil Bakery"), "what": .string("Bread")]), in: d)
        // A second read stands for the relaunch: nothing in memory, only the defaults.
        let back = StageDraft.value("m1#3", in: d)
        XCTAssertEqual(back?["form"]?.object?["name"]?.string, "Basil Bakery")
        XCTAssertEqual(back?["form"]?.object?["what"]?.string, "Bread")
        XCTAssertNil(StageDraft.value("m2#3", in: d), "another message's question must not read it")
    }

    func testClearOnSend() {
        let d = defaults()
        StageDraft.keep("m1#1", form(["name": .string("a")]), in: d)
        StageDraft.keep("m1#2", form(["name": .string("b")]), in: d)
        StageDraft.clear(["m1#1", "m1#2"], in: d)
        XCTAssertNil(StageDraft.value("m1#1", in: d))
        XCTAssertNil(StageDraft.value("m1#2", in: d))
    }

    func testEmptiedAnswerTakesTheDraftAway() {
        let d = defaults()
        StageDraft.keep("m1#1", form(["name": .string("a")]), in: d)
        StageDraft.keep("m1#1", YLEvent(id: "about", preset: "form", value: [:]), in: d)
        XCTAssertNil(StageDraft.value("m1#1", in: d))
    }

    func testSecretFieldsAreNeverStored() {
        let d = defaults()
        StageDraft.keep("m1#1", form(["name": .string("Basil"), "api_key": .string("hunter2"), "Password": .string("x"),
                                      "pin": .string("1234"), "verificationCode": .string("998877"),
                                      "note": .string("sk-or-v1-abcdefghijklmnopqrstuvwxyz123456")]), in: d)
        let f = StageDraft.value("m1#1", in: d)?["form"]?.object
        XCTAssertEqual(f?["name"]?.string, "Basil")
        XCTAssertEqual(Set(f?.keys.map { $0 } ?? []), ["name"], "a secret-looking field was written: \(f?.keys.sorted() ?? [])")
        XCTAssertFalse((d.data(forKey: StageDraft.key).map { String(decoding: $0, as: UTF8.self) } ?? "").contains("hunter2"))
    }

    func testOnlySecretsLeavesNothing() {
        let d = defaults()
        StageDraft.keep("m1#1", form(["pin": .string("1234")]), in: d)
        XCTAssertNil(StageDraft.value("m1#1", in: d))
    }

    func testNamesThatAreNotSecrets() {
        XCTAssertFalse(StageDraft.isSecretName("keyboard"))
        XCTAssertFalse(StageDraft.isSecretName("pinterest"))
        XCTAssertFalse(StageDraft.isSecretName("postcode_area"))
        XCTAssertTrue(StageDraft.isSecretName("apiKey"))
        XCTAssertTrue(StageDraft.isSecretName("zip code"))
        XCTAssertTrue(StageDraft.isSecretName("PIN"))
    }

    func testCapDropsTheOldest() {
        let d = defaults()
        for i in 0..<(StageDraft.cap + 5) { StageDraft.keep("m#\(i)", form(["name": .string("n\(i)")]), in: d) }
        XCTAssertEqual(StageDraft.load(in: d).entries.count, StageDraft.cap)
        XCTAssertNotNil(StageDraft.value("m#\(StageDraft.cap + 4)", in: d))
    }
}
