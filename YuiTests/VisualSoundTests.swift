import AVFoundation
import XCTest
import YuiLines
import YuiSound
@testable import Yui

/// What the visual hears (YUI-125): one feed, routed by `react=`, and the agent's
/// voice measured offline and read back on the clock.
@MainActor
final class VisualSoundTests: XCTestCase {
    override func tearDown() async throws {
        VisualSound.mic.clear()
        VisualSound.room.clear()
        VisualSound.shared.voice.stop()
        try await super.tearDown()
    }

    func testReactPicksTheSource() {
        let feed = VisualSound.shared
        VisualSound.mic.publish(.init(level: 0.6, low: 0.5, mid: 0.6, high: 0.3))
        XCTAssertEqual(feed.reading("voice").level, 0.6, accuracy: 0.001, "voice hears you while you talk")
        XCTAssertEqual(feed.reading("mic").level, 0.6, accuracy: 0.001, "the room includes you")
        XCTAssertEqual(feed.reading("off"), .zero)
        // The engine is not running in tests: music is silent, whatever the mic hears.
        XCTAssertEqual(feed.reading("music"), .zero)
        // Unknown words read like the default, voice.
        XCTAssertEqual(feed.reading("anything").level, 0.6, accuracy: 0.001)
        VisualSound.room.publish(.flat(0.9))
        XCTAssertEqual(feed.reading("mic").level, 0.9, accuracy: 0.001, "the room is louder")
        XCTAssertEqual(feed.reading("voice").level, 0.6, accuracy: 0.001, "voice never hears the room")
    }

    func testTheAgentsVoiceIsReadOnItsClock() {
        // One second of a line: quiet 0.3 s, a word 0.4 s, quiet again.
        let sr = 22_050.0
        let x: [Float] = (0..<Int(sr)).map { i in
            let t = Double(i) / sr
            return t > 0.3 && t < 0.7 ? Float(0.3 * sin(2 * .pi * 220 * t)) : 0
        }
        let track = VisualSound.shared.voice
        let start = CACurrentMediaTime()
        track.load(x, sampleRate: sr, at: start)
        XCTAssertEqual(track.steps.count, 100, "10 ms steps")
        XCTAssertEqual(track.reading(now: start + 0.1).level, 0)
        XCTAssertGreaterThan(track.reading(now: start + 0.5).level, 0.8)
        XCTAssertGreaterThan(track.reading(now: start + 0.5).low, track.reading(now: start + 0.5).high, "220 Hz sits low")
        XCTAssertEqual(track.reading(now: start + 1.5), .zero, "after the line: silence")
        // The voice route takes the louder of you and the agent.
        VisualSound.mic.publish(.flat(0.2))
        XCTAssertEqual(VisualSound.shared.reading("voice").level, VisualSound.mic.reading().level, accuracy: 0.001,
                       "now is before the word: the mic is louder")
        track.stop()
        XCTAssertEqual(track.reading(now: start + 0.5), .zero, "a stopped line is silent")
    }

    func testStepsKeepTimeAcrossBuffers() {
        // Buffers that are not a whole number of steps: the leftovers wait, nothing is lost.
        let steps = VoiceTrack.Steps(line: 0) { _, _ in }
        var n = 0
        for _ in 0..<10 { n += steps.measure([Float](repeating: 0.1, count: 333), sampleRate: 22_050).count }
        XCTAssertEqual(n, 3330 / 220)
    }

    func testTheAgentsRealVoiceMeasures() async throws {
        // AVSpeechSynthesizer.write on the simulator: the same path the narrator's copy takes.
        VisualSound.shared.watch(true)
        defer { VisualSound.shared.watch(false) }
        let u = AVSpeechUtterance(string: "The orb listens while I talk.")
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        let track = VisualSound.shared.voice
        track.willSpeak(u)
        let end = Date().addingTimeInterval(10)
        while track.steps.count < 50, Date() < end { try await Task.sleep(for: .milliseconds(100)) }
        try XCTSkipIf(track.steps.isEmpty, "no speech voice on this simulator")
        let loud = track.steps.map(\.level).max() ?? 0
        print("voice: \(track.steps.count) steps, loudest \(loud)")
        XCTAssertGreaterThan(loud, 0.5, "speech measures like a voice")
        XCTAssertEqual(track.reading(), .zero, "nothing plays until the narrator begins")
        track.began()
        XCTAssertNotNil(track.startedAt)
    }

    func testEveryLookSaysWhatItDoesWithTheSound() {
        for look in YuiLines.visualLooks {
            XCTAssertNotNil(VisualPlan.listens[look], look)
        }
        let v = YuiLines.visual(of: YuiLines.parse("visual orb"))
        let plan = VisualPlan(v, accent: "#FF7E8A", ground: "#FFF9F0", ink: "#3A3340", motion: MotionLook(character: "bouncy", reduced: false))
        XCTAssertEqual(plan?.hint, "Orb pulses with the lows, ripples with the mids and glows with the highs.")
        let grain = VisualPlan(YuiLines.visual(of: YuiLines.parse("visual grain react=music")), accent: "#FF7E8A",
                               ground: "#FFF9F0", ink: "#3A3340", motion: MotionLook(character: "bouncy", reduced: false))
        XCTAssertEqual(grain?.hint, "Grain spreads with the lows and sparkles with the highs.")
        let off = VisualPlan(YuiLines.visual(of: YuiLines.parse("visual bloom react=off")), accent: "#FF7E8A",
                             ground: "#FFF9F0", ink: "#3A3340", motion: MotionLook(character: "bouncy", reduced: false))
        XCTAssertNil(off?.hint)
    }
}
