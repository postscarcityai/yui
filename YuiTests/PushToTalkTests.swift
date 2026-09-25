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
}
