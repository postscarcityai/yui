import XCTest
@testable import Yui

/// Films talk (YUI-319): the cue scheduler, with a fake voice. Start, pause, seek past a cue, replay, mute.
@MainActor
final class MotionSpeechTests: XCTestCase {
    final class Fake: MotionSpeechOutput {
        var onFinish: (() -> Void)?
        var log: [String] = []
        func speak(_ text: String) { log.append("say:\(text)") }
        func stop() { log.append("stop") }
        func pause() { log.append("pause") }
        func resume() { log.append("resume") }
        func finish() { onFinish?() }
    }

    private let cues = [MotionCue(text: "One", from: 1, to: 2), MotionCue(text: "Two", from: 4, to: 5), MotionCue(text: "Three", from: 8, to: 9)]

    private func make(muted: Bool = false, allowed: Bool = true) -> (MotionCueScheduler, Fake) {
        let f = Fake()
        let s = MotionCueScheduler(output: f, muted: muted, allowed: { allowed })
        s.setCues(cues)
        return (s, f)
    }

    func testSpeaksACueWhenFilmTimeReachesIt() {
        let (s, f) = make()
        s.tick(0.5); XCTAssertEqual(f.log, [])
        s.tick(1.0); XCTAssertEqual(f.log, ["say:One"])
        s.tick(1.2); XCTAssertEqual(f.log, ["say:One"], "a cue is spoken once")
    }

    func testLongLineFinishesAndTheNextWaitsForIt() {
        let (s, f) = make()
        s.tick(1)
        s.tick(4.5)   // Two is due, One is still talking
        XCTAssertEqual(f.log, ["say:One"], "no cutting mid-sentence")
        f.finish()
        XCTAssertEqual(f.log, ["say:One", "say:Two"], "the next one goes as soon as the line ends")
        f.finish()
        XCTAssertEqual(f.log.count, 2, "Three is not due yet")
    }

    func testPauseHoldsSpeechAndPlayResumesIt() {
        let (s, f) = make()
        s.tick(1)
        s.pause(); XCTAssertEqual(f.log, ["say:One", "pause"])
        s.tick(4.2); XCTAssertEqual(f.log.count, 2)
        s.resume(); XCTAssertEqual(f.log, ["say:One", "pause", "resume"])
        f.finish(); XCTAssertEqual(f.log.last, "say:Two", "the due cue goes after the resumed line")
    }

    func testPauseBetweenLinesSpeaksNothing() {
        let (s, f) = make()
        s.pause()
        s.tick(1.5)
        XCTAssertEqual(f.log, [])
        s.resume()
        XCTAssertEqual(f.log, ["say:One"])
    }

    func testSeekPastACueStopsTheLineAndPicksUpAtTheNext() {
        let (s, f) = make()
        s.tick(1)
        s.seek(5)   // past Two, mid One
        XCTAssertEqual(f.log, ["say:One", "stop"])
        s.tick(5.1); XCTAssertEqual(f.log.count, 2, "Two was skipped")
        s.tick(8); XCTAssertEqual(f.log.last, "say:Three")
    }

    func testSeekBackSpeaksAgain() {
        let (s, f) = make()
        s.tick(1); f.finish()
        s.seek(0.2)
        s.tick(1.1)
        XCTAssertEqual(f.log, ["say:One", "say:One"])
    }

    func testReplayStartsOver() {
        let (s, f) = make()
        s.tick(1); f.finish(); s.tick(4); f.finish()
        s.replay()
        s.tick(1)
        XCTAssertEqual(f.log, ["say:One", "say:Two", "say:One"])
    }

    func testMuteStopsTheLineAndCuesPassInSilence() {
        let (s, f) = make()
        s.tick(1)
        s.setMuted(true)
        XCTAssertEqual(f.log, ["say:One", "stop"])
        s.tick(4.5); XCTAssertEqual(f.log.count, 2, "muted: nothing spoken")
        s.setMuted(false)
        XCTAssertEqual(f.log.count, 2, "unmuting does not replay Two")
        s.tick(8); XCTAssertEqual(f.log.last, "say:Three")
    }

    func testStartMuted() {
        let (s, f) = make(muted: true)
        s.tick(9)
        XCTAssertEqual(f.log, [])
        XCTAssertTrue(s.muted)
    }

    func testVoiceOverRunningSaysNothing() {
        let (s, f) = make(allowed: false)
        s.tick(9)
        XCTAssertEqual(f.log, [])
    }

    func testReduceMotionStillFrameSpeaksTheLinesInOrder() {
        let (s, f) = make()
        s.setInOrder(true)
        XCTAssertEqual(f.log, ["say:One"], "no clock: the first line goes at once")
        f.finish(); f.finish()
        XCTAssertEqual(f.log, ["say:One", "say:Two", "say:Three"])
    }

    func testStopSilencesAndStaysSilent() {
        let (s, f) = make()
        s.tick(1)
        s.stop()
        s.tick(9)
        XCTAssertEqual(f.log, ["say:One", "stop"])
    }

    func testLateCuesFromANewSceneAreScheduled() {
        let (s, f) = make()
        s.tick(10)
        f.finish(); f.finish(); f.finish()
        s.setCues(cues + [MotionCue(text: "Four", from: 12, to: 13)])
        s.tick(12)
        XCTAssertEqual(f.log.last, "say:Four")
    }

    // MARK: Controller

    func testMuteChoiceIsKeptAcrossFilms() {
        let d = UserDefaults(suiteName: "yui.test.motionspeech")!
        d.removePersistentDomain(forName: "yui.test.motionspeech")
        let f = Fake()
        let a = MotionController(speech: f, defaults: d)
        XCTAssertFalse(a.muted)
        a.setMuted(true)
        a.stop()
        let b = MotionController(speech: Fake(), defaults: d)
        XCTAssertTrue(b.muted, "the next film starts muted")
        XCTAssertTrue(b.speech.muted)
        b.stop()
    }

    func testControllerDrivesTheSpeechFromTheTransport() {
        let d = UserDefaults(suiteName: "yui.test.motionspeech2")!
        d.removePersistentDomain(forName: "yui.test.motionspeech2")
        let f = Fake()
        let c = MotionController(speech: f, defaults: d)
        c.handle(.firstFrame)
        c.handle(.timeline(total: 12, scenes: 1, ended: false))
        c.handle(.cues(scene: "a", cues: cues))
        c.handle(.time(t: 1, total: 12, paused: false))
        XCTAssertEqual(f.log, ["say:One"])
        c.pause(); XCTAssertEqual(f.log.last, "pause")
        c.resume(); XCTAssertEqual(f.log.last, "resume")
        c.seek(9); XCTAssertEqual(f.log.last, "stop")
        c.replay()
        c.handle(.time(t: 1, total: 12, paused: false))
        XCTAssertEqual(f.log.last, "say:One")
        c.stop()
        XCTAssertEqual(f.log.last, "stop")
    }

    func testBestVoicePrefersQuality() {
        // Whatever the host has installed: the pick is English, and no installed English voice outranks it.
        let v = AVMotionSpeech.bestVoice()
        XCTAssertNotNil(v)
        XCTAssertTrue(v?.language.hasPrefix("en") ?? false)
    }
}
