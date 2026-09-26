import Observation
import XCTest
@testable import Yui

/// YUI-99: the send button reads only `hasWords`, so it must change on the first word and
/// the last delete, never per key; suggestions look only at the last word.
@MainActor
final class ComposerModelTests: XCTestCase {
    func testLastWord() {
        XCTAssertEqual(ComposerModel.lastWord(""), "")
        XCTAssertEqual(ComposerModel.lastWord("hi"), "hi")
        XCTAssertEqual(ComposerModel.lastWord("ask @co"), "@co")
        XCTAssertEqual(ComposerModel.lastWord("ask @coach "), "")
        XCTAssertEqual(ComposerModel.lastWord("line one\n@w"), "@w")
        XCTAssertEqual(ComposerModel.lastWord("me@example.com"), "me@example.com")
    }

    func testHasWordsFollowsTheDraft() {
        let m = ComposerModel()
        XCTAssertFalse(m.hasWords)
        m.draft = "   "
        XCTAssertFalse(m.hasWords, "spaces are nothing to send")
        m.draft = "  a"
        XCTAssertTrue(m.hasWords)
        m.draft = ""
        XCTAssertFalse(m.hasWords)
    }

    /// A reader of `hasWords` (the send button) is told once when it flips on, not
    /// again for every key after, and once when the last character goes.
    func testHasWordsChangesOnlyWhenItFlips() {
        let m = ComposerModel()
        let told = Count()
        func watch() {
            withObservationTracking { _ = m.hasWords } onChange: { told.n += 1 }
        }
        watch()
        m.draft = "H"
        XCTAssertEqual(told.n, 1)
        watch()
        for word in ["He", "Hel", "Hell", "Hello", "Hello ", "Hello  ", "Hello. "] { m.draft = word }
        XCTAssertEqual(told.n, 1, "typing more words told the button again")
        for word in ["Hello.", "Hello", "Hell", "Hel", "He", "H"] { m.draft = word }
        XCTAssertEqual(told.n, 1, "deleting told the button again before the field was empty")
        m.draft = ""
        XCTAssertEqual(told.n, 2, "the last delete did not tell the button")
    }

    /// A reader of `draft` alone (the field) is told on every key.
    func testDraftTellsTheFieldEveryKey() {
        let m = ComposerModel()
        let told = Count()
        for word in ["a", "ab", "abc"] {
            withObservationTracking { _ = m.draft } onChange: { told.n += 1 }
            m.draft = word
        }
        XCTAssertEqual(told.n, 3)
    }
}

/// onChange fires synchronously on the setter here; the box only satisfies Sendable.
private final class Count: @unchecked Sendable {
    var n = 0
}
