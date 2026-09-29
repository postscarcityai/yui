import AVFoundation
import Speech
import XCTest
@testable import Yui

/// Hold to talk crashed the first time (TestFlight crash ANv4a2bHdXMMaEjjhTva5ZA, build 57):
/// the speech permission answer comes back on a system thread, and a main-actor closure
/// running there is a Swift 6 trap. Run with speech + mic granted to com.yuigui.app
/// (`xcrun simctl privacy <sim> grant speech-recognition|microphone com.yuigui.app`) so
/// start() gets past the ask and installs the tap and the recognizer as on the phone.
@MainActor
final class PushToTalkTests: XCTestCase {
    func testHoldingTheMicDoesNotCrash() async {
        let ptt = PushToTalk()
        await ptt.start()
        // The simulator may have no usable mic or recognizer; any phase is fine, a trap is not.
        XCTAssertNotEqual(ptt.phase, .denied, "grant speech + mic to the simulator first")
        try? await Task.sleep(for: .milliseconds(800))  // let the tap and the recognizer call back
        _ = await ptt.stop()
        XCTAssertNotEqual(ptt.phase, .listening)
    }

    /// On a phone the tap runs on the audio thread and results on the recognizer's queue.
    /// Call both from a background thread; they must hand their values to the main actor.
    func testCallbacksFromAudioThreadsReachTheMainActor() async throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        nonisolated(unsafe) let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        let levelHeard = expectation(description: "level on main")
        let wordsHeard = expectation(description: "words on main")
        nonisolated(unsafe) let tap = PushToTalk.tap(SFSpeechAudioBufferRecognitionRequest()) { _ in
            MainActor.assertIsolated(); levelHeard.fulfill()
        }
        nonisolated(unsafe) let heard = PushToTalk.heard { text, done in
            MainActor.assertIsolated()
            XCTAssertNil(text); XCTAssertTrue(done)
            wordsHeard.fulfill()
        }
        DispatchQueue.global().async {
            tap(buffer, AVAudioTime(sampleTime: 0, atRate: 44_100))
            heard(nil, NSError(domain: "test", code: 1))
        }
        await fulfillment(of: [levelHeard, wordsHeard], timeout: 5)
    }

    /// The waveform keeps the loudest peak per bar, one bar per `barEvery`, and only the last `bars`.
    func testWaveformKeepsPeaksAndCaps() {
        let ptt = PushToTalk()
        let t0 = Date(timeIntervalSince1970: 1_000)
        ptt.take(level: 0.2, at: t0)
        ptt.take(level: 0.9, at: t0.addingTimeInterval(0.02))
        ptt.take(level: 0.1, at: t0.addingTimeInterval(0.04))
        XCTAssertEqual(ptt.levels, [0.2], "a bar too soon")
        ptt.take(level: 0.3, at: t0.addingTimeInterval(PushToTalk.barEvery))
        XCTAssertEqual(ptt.levels, [0.2, 0.9], "the new bar lost the peak in between")
        for i in 0..<(PushToTalk.bars * 2) {
            ptt.take(level: 0.5, at: t0.addingTimeInterval(PushToTalk.barEvery * Double(i + 2)))
        }
        XCTAssertEqual(ptt.levels.count, PushToTalk.bars)
        XCTAssertEqual(ptt.level, 0.5)
    }

    /// Slide to the trash: the words are thrown away and the next hold starts clean.
    func testCancelDiscards() async {
        let ptt = PushToTalk()
        ptt.demo("never mind")
        XCTAssertTrue(ptt.listening)
        ptt.cancel()
        XCTAssertEqual(ptt.phase, .idle)
        XCTAssertEqual(ptt.transcript, "")
        XCTAssertTrue(ptt.levels.isEmpty)
        XCTAssertNil(ptt.startedAt)
        let words = await ptt.stop()
        XCTAssertEqual(words, "", "stop after cancel still returned words")
    }

    /// YUI-209: the classic recognizer starts over after a pause. Nothing said before it is lost.
    func testClassicRestartKeepsEarlierWords() {
        var w = PushToTalk.Transcript()
        w.takeRestarting("one", final: false)
        w.takeRestarting("one two three", final: false)
        w.takeRestarting("four", final: false)
        w.takeRestarting("four five", final: false)
        XCTAssertEqual(w.text, "one two three four five")
        w.takeRestarting("six", final: false)
        w.takeRestarting("six seven eight", final: false)
        w.takeRestarting("nine", final: true)
        XCTAssertEqual(w.text, "one two three four five six seven eight nine")
    }

    /// A revision of the same sentence is not a restart, even when the first word is recased.
    func testClassicRevisionDoesNotDuplicate() {
        var w = PushToTalk.Transcript()
        w.takeRestarting("hello there wor", final: false)
        w.takeRestarting("Hello there world", final: false)
        w.takeRestarting("Hello there world", final: true)
        XCTAssertEqual(w.text, "Hello there world")
        w.takeRestarting("", final: true)
        XCTAssertEqual(w.text, "Hello there world")
    }

    /// Analyzer: a settled segment is never dropped, and a newer volatile that beats an
    /// older final to the screen survives it.
    func testAnalyzerKeepsSettledAndNewerVolatile() {
        var w = PushToTalk.Transcript()
        w.take("one two", final: false, at: 0, end: 2)
        w.take("one two three", final: true, at: 0, end: 3)
        w.take("four", final: false, at: 3, end: 4)
        w.take("four five", final: true, at: 3, end: 5)
        XCTAssertEqual(w.text, "one two three four five")
        w.take("six", final: false, at: 8, end: 9)     // newer volatile arrives first
        w.take("five and", final: true, at: 5, end: 6) // late final for an older range
        XCTAssertEqual(w.text, "one two three four five five and six")
    }

    /// A 60 s prompt with pauses: every segment, in order.
    func testLongPromptWithPausesKeepsEverything() {
        var w = PushToTalk.Transcript()
        var expected: [String] = []
        for seg in 0..<12 {
            let words = (0..<8).map { "w\(seg)x\($0)" }
            expected += words
            for n in 1...words.count { w.takeRestarting(words[0..<n].joined(separator: " "), final: false) }
        }
        XCTAssertEqual(w.text, expected.joined(separator: " "))
    }
}
