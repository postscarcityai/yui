import XCTest
import YuiLines
@testable import Yui

/// Long turns (TestFlight: "assume it's always going to take a little while",
/// and no telling it to restart every time). The chat says the agent is
/// working and for how long, resumes that on reopen, and has no time limit.
@MainActor
final class WorkingNoteTests: XCTestCase {
    static func ts(_ ago: TimeInterval) -> String { Date.now.addingTimeInterval(-ago).formatted(.iso8601) }

    static func user(_ id: String, sent: TimeInterval, pickedUp: TimeInterval? = nil, done: TimeInterval? = nil) -> ThreadRow {
        ThreadRow(id: id, sender: "user", body: "OK, show me my weight chart", kind: "text", meta: nil,
                  createdAt: ts(sent), deliveredAt: pickedUp.map(ts), handledAt: done.map(ts))
    }

    static let reply = ThreadRow(id: "a1", sender: "agent", body: "Quick one on Yui itself.", kind: "text", meta: nil,
                                 createdAt: ts(600))

    func testLabelCountsUp() {
        let now = Date.now
        XCTAssertEqual(WorkingNote.label(since: now.addingTimeInterval(-9), pickedUp: nil, now: now), "On its way · 9s")
        XCTAssertEqual(WorkingNote.label(since: now.addingTimeInterval(-14), pickedUp: now.addingTimeInterval(-2), now: now),
                       "Pondering · 2s")
        XCTAssertEqual(WorkingNote.label(since: nil, pickedUp: nil, now: now), "On its way")
        XCTAssertEqual(WorkingNote.elapsed(3 * 3600 + 7 * 60 + 5), "3h 7m")
        XCTAssertEqual(WorkingNote.elapsed(-2), "0s")
    }

    /// One row, one line: a working word that changes every few seconds, then the time.
    func testWordRotatesAfterPickup() {
        let now = Date.now
        let picked = now.addingTimeInterval(-84)
        let word = WorkingNote.word(pickedUp: picked, now: now)
        XCTAssertEqual(WorkingNote.label(since: now.addingTimeInterval(-90), pickedUp: picked, now: now), "\(word) · 1m 24s")
        let seen = Set((0..<WorkingNote.words.count).map {
            WorkingNote.word(pickedUp: picked, now: picked.addingTimeInterval(Double($0) * WorkingNote.wordEvery + 1))
        })
        XCTAssertEqual(seen.count, WorkingNote.words.count, "the word does not rotate through the list")
        XCTAssertEqual(WorkingNote.word(pickedUp: picked, now: picked.addingTimeInterval(1)),
                       WorkingNote.word(pickedUp: picked, now: picked.addingTimeInterval(WorkingNote.wordEvery - 1)),
                       "the word flickers inside its few seconds")
        XCTAssertEqual(WorkingNote.word(pickedUp: nil, now: now), "On its way")
        for w in WorkingNote.words {
            XCTAssertFalse(w.contains("—"), w)
            XCTAssertLessThanOrEqual(w.count, 20, "keep the words short: \(w)")
        }
        XCTAssertEqual(WorkingNote.accessibility(name: "Yui", label: "Pondering · 2s", long: false), "Yui: Pondering · 2s")
    }

    func testReopenedMidTurnKeepsWorking() {
        let store = ChatStore()
        store.load([Self.reply, Self.user("u1", sent: 100, pickedUp: 95)])
        XCTAssertTrue(store.waiting, "a thread reopened mid-turn shows no working note")
        let picked = try! XCTUnwrap(store.pickedUpAt)
        XCTAssertEqual(Date.now.timeIntervalSince(picked), 95, accuracy: 2)
    }

    func testLongTurnHasNoTimeLimit() {
        let store = ChatStore()
        store.load([Self.reply, Self.user("u1", sent: 20 * 60, pickedUp: 20 * 60 - 3)])
        XCTAssertTrue(store.waiting, "a 20 minute turn stopped showing as working")
    }

    func testFinishedOrStaleTurnsDoNotWait() {
        let done = ChatStore()
        done.load([Self.reply, Self.user("u1", sent: 100, pickedUp: 95, done: 40)])
        XCTAssertFalse(done.waiting, "a finished turn still shows as working")

        let stale = ChatStore()
        stale.load([Self.reply, Self.user("u1", sent: 2 * 3600)])
        XCTAssertFalse(stale.waiting, "a two hour old unanswered row reads as working")

        let answered = ChatStore()
        answered.load([Self.user("u1", sent: 700, pickedUp: 699), ThreadRow(id: "a2", sender: "agent", body: "Here.", kind: "text",
                                                                           meta: nil, createdAt: Self.ts(650))])
        XCTAssertFalse(answered.waiting)
    }

    /// YUI-63 step 2: the agent's `doing` takes the working word's place, the
    /// seconds keep counting, and VoiceOver reads the step.
    func testDoingWordsAndStep() {
        let now = Date.now
        let picked = now.addingTimeInterval(-12)
        let d = YLDoing(text: "Reading your calendar", step: 2, of: 5)
        XCTAssertEqual(WorkingNote.label(since: now.addingTimeInterval(-14), pickedUp: picked, now: now, doing: d),
                       "Reading your calendar, step 2 of 5 · 12s")
        XCTAssertEqual(WorkingNote.accessibility(name: "Yui", label: WorkingNote.label(since: nil, pickedUp: picked, now: now,
                                                                                         doing: d), long: false),
                       "Yui: Reading your calendar, step 2 of 5 · 12s")
        // A step alone keeps the working word.
        let word = WorkingNote.word(pickedUp: picked, now: now)
        XCTAssertEqual(WorkingNote.label(since: nil, pickedUp: picked, now: now, doing: YLDoing(step: 1, of: 4)),
                       "\(word), step 1 of 4 · 12s")
        XCTAssertEqual(YLDoing(step: 1, of: 4).progress, 0.25)
        XCTAssertNil(YLDoing(text: "Looking").progress)
    }

    /// The host writes `doing` onto the person's row; the store reads it while
    /// it waits, ignores anything malformed, and the reply clears it.
    func testDoingFromTheRow() {
        XCTAssertEqual(ChatStore.doing(.object(["text": .string("Drafting the plan"), "step": .number(3), "of": .number(3)])),
                       YLDoing(text: "Drafting the plan", step: 3, of: 3))
        XCTAssertEqual(ChatStore.doing(.object(["text": .string("Looking"), "step": .number(6), "of": .number(5)])),
                       YLDoing(text: "Looking"), "a step past the end drops the bar, keeps the words")
        XCTAssertNil(ChatStore.doing(.object(["text": .string("  ")])))
        XCTAssertNil(ChatStore.doing(.null))
        XCTAssertNil(ChatStore.doing(nil))

        var row = Self.user("u1", sent: 30, pickedUp: 28)
        row.doing = .object(["text": .string("Reading your notes"), "step": .number(1), "of": .number(2)])
        let store = ChatStore()
        store.load([Self.reply, row])
        XCTAssertTrue(store.waiting)
        XCTAssertEqual(store.doing, YLDoing(text: "Reading your notes", step: 1, of: 2), "reopened mid-turn: the words are gone")

        var queued = Self.user("u2", sent: 5)
        queued.doing = .object(["text": .string("Old words")])
        let waiting = ChatStore()
        waiting.load([Self.reply, queued])
        XCTAssertNil(waiting.doing, "a row the host has not picked up shows no words")
    }
}
