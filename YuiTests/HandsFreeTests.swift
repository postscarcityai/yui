import XCTest
@testable import Yui

/// Hands-free (YUI-14): the loop's rules, turn by turn, with no audio.
final class HandsFreeTests: XCTestCase {
    func testAFullTurnComesBackToListening() {
        var hf = HandsFree()
        XCTAssertEqual(hf.handle(.tap), .openMic)
        XCTAssertEqual(hf.state, .starting)
        XCTAssertNil(hf.handle(.micOpen))
        XCTAssertEqual(hf.state, .listening)
        XCTAssertEqual(hf.handle(.endOfSpeech), .finishMic)
        XCTAssertEqual(hf.handle(.heard("  Book a table for two  ")), .send("Book a table for two"))
        XCTAssertEqual(hf.state, .sending)
        XCTAssertNil(hf.handle(.sent))
        XCTAssertEqual(hf.state, .waiting)
        XCTAssertFalse(hf.micOpen, "the mic is open while the agent works")
        XCTAssertEqual(hf.handle(.replyLanded), .readBeat)
        XCTAssertEqual(hf.state, .reading)
        XCTAssertEqual(hf.handle(.readDone), .openMic, "the mic did not reopen after the reply")
        XCTAssertEqual(hf.handle(.micOpen), nil)
        XCTAssertEqual(hf.state, .listening)
    }

    func testNothingHeardListensAgainWithoutSending() {
        var hf = HandsFree()
        for e in [HandsFree.Event.tap, .micOpen, .endOfSpeech] { hf.handle(e) }
        XCTAssertEqual(hf.handle(.heard("   ")), .openMic)
        XCTAssertEqual(hf.state, .starting)
    }

    func testAFastReplyWhileSendingStillReads() {
        var hf = HandsFree()
        for e in [HandsFree.Event.tap, .micOpen, .endOfSpeech, .heard("hi")] { hf.handle(e) }
        XCTAssertEqual(hf.handle(.replyLanded), .readBeat)
    }

    func testStopClosesTheMicFromAnywhere() {
        var hf = HandsFree()
        hf.handle(.tap); hf.handle(.micOpen)
        XCTAssertEqual(hf.handle(.stop), .closeMic)
        XCTAssertEqual(hf.state, .off)
        hf.handle(.tap); hf.handle(.micOpen); hf.handle(.endOfSpeech); hf.handle(.heard("x")); hf.handle(.sent)
        XCTAssertNil(hf.handle(.stop), "the mic was already closed while waiting")
        XCTAssertFalse(hf.on)
        XCTAssertNil(hf.handle(.replyLanded), "a reply after stop reopened the mic")
        XCTAssertEqual(hf.state, .off)
    }

    func testInterruptionPausesAndResumes() {
        var hf = HandsFree()
        hf.handle(.tap); hf.handle(.micOpen)
        XCTAssertEqual(hf.handle(.interrupted), .closeMic)
        XCTAssertEqual(hf.state, .paused(.interrupted))
        XCTAssertEqual(hf.handle(.interruptionEnded), .openMic)
        // Waiting on a reply: the words are out, nothing to close.
        hf.handle(.micOpen); hf.handle(.endOfSpeech); hf.handle(.heard("x")); hf.handle(.sent)
        XCTAssertNil(hf.handle(.interrupted))
        XCTAssertEqual(hf.state, .paused(.interrupted))
        XCTAssertNil(hf.handle(.replyLanded), "a paused mic reopened on a reply")
    }

    func testQuietAndFailuresPauseAndATapResumes() {
        var hf = HandsFree()
        hf.handle(.tap); hf.handle(.micOpen)
        XCTAssertEqual(hf.handle(.quietTooLong), .closeMic)
        XCTAssertEqual(hf.state, .paused(.quiet))
        XCTAssertEqual(hf.handle(.tap), .openMic)
        XCTAssertNil(hf.handle(.micFailed(denied: true)))
        XCTAssertEqual(hf.state, .paused(.denied))
        XCTAssertEqual(hf.handle(.tap), .openMic)
        hf.handle(.micOpen); hf.handle(.endOfSpeech); hf.handle(.heard("x"))
        XCTAssertNil(hf.handle(.sendFailed))
        XCTAssertEqual(hf.state, .paused(.failed))
    }

    func testStrayEventsChangeNothing() {
        var hf = HandsFree()
        for e in [HandsFree.Event.micOpen, .endOfSpeech, .heard("x"), .sent, .replyLanded, .readDone, .quietTooLong] {
            XCTAssertNil(hf.handle(e)); XCTAssertEqual(hf.state, .off)
        }
        hf.handle(.tap); hf.handle(.micOpen)
        XCTAssertNil(hf.handle(.tap), "a second tap while listening did something")
        XCTAssertNil(hf.handle(.replyLanded), "a late reply cut the person off")
        XCTAssertEqual(hf.state, .listening)
    }

    func testEndOfSpeechNeedsWordsThenQuiet() {
        let t = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(EndOfSpeech.ended(words: "", lastSound: t, now: t + 5), "noise with no words ended a turn")
        XCTAssertFalse(EndOfSpeech.ended(words: "hello", lastSound: t, now: t + HandsFree.endQuiet - 0.05))
        XCTAssertTrue(EndOfSpeech.ended(words: "hello", lastSound: t, now: t + HandsFree.endQuiet))
        XCTAssertFalse(EndOfSpeech.tooQuiet(words: "hi", startedAt: t, now: t + 99))
        XCTAssertTrue(EndOfSpeech.tooQuiet(words: " ", startedAt: t, now: t + HandsFree.quietLimit))
    }

    @MainActor
    func testNewWordsAndLoudnessKeepTheTurnOpen() {
        let ptt = PushToTalk()
        let t = Date(timeIntervalSince1970: 1_000)
        ptt.take(level: 0.1, at: t)
        XCTAssertNil(ptt.lastSound, "room noise counted as talking")
        ptt.take(level: 0.8, at: t)
        XCTAssertEqual(ptt.lastSound, t)
    }

    func testTranscriptSettlesAndReplacesVolatileWords() {
        var w = PushToTalk.Transcript()
        w.take("what's on", final: false)
        XCTAssertEqual(w.text, "what's on")
        w.take("what's on my calendar", final: false)
        XCTAssertEqual(w.text, "what's on my calendar", "volatile words piled up instead of replacing")
        w.take("What's on my calendar", final: true)
        w.take("tomorrow", final: false)
        XCTAssertEqual(w.text, "What's on my calendar tomorrow")
        w.take("tomorrow morning?", final: true)
        XCTAssertEqual(w.text, "What's on my calendar tomorrow morning?")
    }

    func testTalkModeIsPerAgentAndDefaultsToTyping() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "yui-talkmode-\(UUID().uuidString)"))
        XCTAssertEqual(TalkMode.of("a", in: d), .type)
        TalkMode.set(.talk, for: "a", in: d)
        XCTAssertEqual(TalkMode.of("a", in: d), .talk)
        XCTAssertEqual(TalkMode.of("b", in: d), .type, "one agent's setting leaked to another")
        TalkMode.set(.type, for: "a", in: d)
        XCTAssertEqual(TalkMode.of("a", in: d), .type)
    }

    func testDemoStatesWalkTheRealEvents() {
        XCTAssertEqual(HandsFree.demo("listening")?.state, .listening)
        XCTAssertEqual(HandsFree.demo("sending")?.state, .sending)
        XCTAssertEqual(HandsFree.demo("waiting")?.state, .waiting)
        XCTAssertEqual(HandsFree.demo("reading")?.state, .reading)
        XCTAssertEqual(HandsFree.demo("paused")?.state, .paused(.quiet))
        XCTAssertNil(HandsFree.demo("nope"))
    }
}
