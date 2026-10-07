import AVFoundation
import UIKit

// Films talk (YUI-319, first slice of YUI-310). The `api.say` cues of a film are spoken on the phone with
// AVSpeechSynthesizer: on device, nothing leaves it. The scheduler below decides WHEN a line starts; the
// output does the speaking. MotionController feeds the scheduler the film's clock and its transport.

/// Speaks one line at a time. The real one is AVSpeechSynthesizer; tests use a fake.
@MainActor
protocol MotionSpeechOutput: AnyObject {
    /// Called when a line has been spoken to the end (not when it was stopped).
    var onFinish: (() -> Void)? { get set }
    func speak(_ text: String)
    func stop()
    func pause()
    func resume()
}

/// Decides which `say` cue to speak, and when, from film time and the transport (pause, seek, replay, mute).
/// A line longer than its cue window finishes; the next one waits for it.
@MainActor
final class MotionCueScheduler {
    private let output: MotionSpeechOutput
    private let allowed: () -> Bool
    private(set) var cues: [MotionCue] = []
    private(set) var time: Double = 0
    private(set) var muted: Bool
    private(set) var paused = false
    /// Reduce Motion shows the last frame, still: the clock does not run, so the lines go out in order.
    private(set) var inOrder = false
    private(set) var speaking = false
    /// Cues that start before this film time are behind us (after a seek). A cue played once is remembered.
    private var floor: Double = 0
    private var done: Set<String> = []

    /// `allowed` is false while VoiceOver runs: it already reads the film's label, so we say nothing.
    init(output: MotionSpeechOutput, muted: Bool = false, allowed: @escaping () -> Bool = { !UIAccessibility.isVoiceOverRunning }) {
        self.output = output
        self.muted = muted
        self.allowed = allowed
        output.onFinish = { [weak self] in self?.finished() }
    }

    private func key(_ c: MotionCue) -> String { "\(c.from)|\(c.text)" }

    func setCues(_ new: [MotionCue]) {
        cues = new.sorted { $0.from < $1.from }
        advance()
    }

    /// The film clock moved (the harness reports it as it plays).
    func tick(_ t: Double) {
        time = t
        advance()
    }

    func pause() {
        guard !paused else { return }
        paused = true
        if speaking { output.pause() }
    }

    func resume() {
        guard paused else { return }
        paused = false
        if speaking { output.resume() }
        advance()
    }

    /// Scrub or seek: the current line stops and the next cue at or after `t` is the next to speak.
    func seek(_ t: Double) {
        time = t
        floor = t
        done = []
        silence()
        advance()
    }

    /// Replay from the top.
    func replay() {
        time = 0
        floor = 0
        done = []
        silence()
        advance()
    }

    func setMuted(_ on: Bool) {
        guard on != muted else { return }
        muted = on
        if on { silence() } else { advance() }
    }

    func setInOrder(_ on: Bool) {
        guard on != inOrder else { return }
        inOrder = on
        advance()
    }

    /// The player left the screen.
    func stop() {
        silence()
        paused = true
    }

    private func silence() {
        guard speaking else { return }
        speaking = false
        output.stop()
    }

    private func finished() {
        speaking = false
        advance()
    }

    /// Start the next pending cue if its time has come and nothing is being spoken.
    private func advance() {
        guard !speaking, !paused else { return }
        for c in cues where c.from >= floor && !done.contains(key(c)) {
            if !inOrder && c.from > time { return }
            done.insert(key(c))
            // Muted, or VoiceOver is reading it: the cue passes in silence, so unmuting does not replay it.
            guard !muted, allowed() else { continue }
            speaking = true
            output.speak(c.text)
            return
        }
    }
}

/// The real thing: AVSpeechSynthesizer with the best English voice installed.
@MainActor
final class AVMotionSpeech: NSObject, MotionSpeechOutput, AVSpeechSynthesizerDelegate {
    var onFinish: (() -> Void)?
    private let synth = AVSpeechSynthesizer()
    private var current: AVSpeechUtterance?

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Premium, then enhanced, then the default voice; a voice for the phone's own region first.
    static func bestVoice(from voices: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices(), region: String? = Locale.current.region?.identifier) -> AVSpeechSynthesisVoice? {
        let english = voices.filter { $0.language.hasPrefix("en") }
        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            let q: Int
            switch v.quality {
            case .premium: q = 2
            case .enhanced: q = 1
            default: q = 0
            }
            let local = (region.map { v.language.hasSuffix("-\($0)") } ?? false) ? 1 : 0
            return q * 2 + local
        }
        return english.max { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    func speak(_ text: String) {
        // Ambient + mixWithOthers: the silent switch mutes us, and music from other apps keeps playing under.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.bestVoice()
        current = u
        synth.speak(u)
    }

    func stop() {
        current = nil
        synth.stopSpeaking(at: .immediate)
    }

    func pause() { synth.pauseSpeaking(at: .immediate) }
    func resume() { synth.continueSpeaking() }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        MainActor.assumeIsolated {
            guard let current, ObjectIdentifier(current) == id else { return }
            self.current = nil
            onFinish?()
        }
    }
}
