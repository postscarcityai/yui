import AVFoundation
import QuartzCore
import YuiSound

// What the visual hears (YUI-125, spec yuigui/spec/VISUAL.md section 4). Chris,
// TestFlight AJq7CcQS8fyM: "It would be great if we have stories in there to
// have them be audio responsive." One level feed, a level and three bands, from
// the sound the visual's `react=` names:
//   voice  your voice while you talk (the push-to-talk mic) and the agent's
//          while it speaks (the narrator), whichever is louder
//   music  the music engine's output (YuiSound)
//   mic    the whole room: the mic, opened only while such a visual is on
//          screen, and only if the mic is already allowed (a picture never asks)
//   off    nothing
// Each source keeps four numbers, overwritten a block at a time. Nothing is
// recorded or kept, nothing is sent: the level never leaves the phone.

@MainActor
final class VisualSound {
    static let shared = VisualSound()

    /// The push-to-talk mic, written by its tap on the audio thread.
    nonisolated static let mic = LevelMeter()
    /// The room, for `react=mic`.
    nonisolated static let room = LevelMeter()

    /// The newest reading for what a visual listens to.
    func reading(_ react: String) -> LevelMeter.Reading {
        switch react {
        case "off": .zero
        case "music": YuiSound.shared.meter.reading()
        case "mic": .louder(Self.room.reading(), Self.mic.reading())
        default: .louder(Self.mic.reading(), voice.reading())
        }
    }

    // MARK: The agent's voice

    /// AVSpeechSynthesizer plays its words where no tap can hear them. So the same
    /// line is also written offline, with the same voice and rate, and measured in
    /// 10 ms steps; while it plays, the visual reads the step under the clock from
    /// when the speech began.
    let voice = VoiceTrack()

    /// Visuals on screen: the voice is only measured while someone can see it.
    private(set) var watching = 0
    func watch(_ on: Bool) { watching = max(0, watching + (on ? 1 : -1)) }

    // MARK: The room (react=mic)

    private var roomUsers = 0
    private var roomEngine: AVAudioEngine?
    /// Push-to-talk has the mic: the room waits.
    private var roomPaused = false

    func listenToRoom(_ on: Bool) {
        roomUsers = max(0, roomUsers + (on ? 1 : -1))
        roomUsers > 0 && !roomPaused ? startRoom() : stopRoom()
    }

    /// Push-to-talk takes the mic (its own engine) and gives it back.
    func micTaken(_ taken: Bool) {
        roomPaused = taken
        if taken { stopRoom() } else if roomUsers > 0 { startRoom() }
    }

    private func startRoom() {
        guard roomEngine == nil, AVAudioApplication.shared.recordPermission == .granted else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            if session.category != .playAndRecord {
                try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
            }
            try session.setActive(true)
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            // No usable mic (a call has it, the simulator): installTap would raise.
            guard format.sampleRate > 0, format.channelCount > 0 else { return }
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.meterTap(Self.room))
            engine.prepare()
            try engine.start()
            roomEngine = engine
        } catch {
            stopRoom()
        }
    }

    private func stopRoom() {
        guard let engine = roomEngine else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        roomEngine = nil
        Self.room.clear()
    }

    /// A tap that only measures, on the audio thread. Built outside the main actor
    /// (Swift 6 traps a main-actor closure run off the main thread).
    nonisolated static func meterTap(_ meter: LevelMeter) -> AVAudioNodeTapBlock {
        { buffer, _ in measure(buffer, into: meter) }
    }

    nonisolated static func measure(_ buffer: AVAudioPCMBuffer, into meter: LevelMeter) {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        meter.measure(data, count: Int(buffer.frameLength), sampleRate: buffer.format.sampleRate, stride: buffer.stride)
    }
}

/// The agent's spoken line as levels, 10 ms apart, and when it began to play.
@MainActor
final class VoiceTrack {
    nonisolated static let hop = 0.01
    private(set) var steps: [LevelMeter.Reading] = []
    private(set) var startedAt: CFTimeInterval?
    /// Bumped per line, so a late buffer from the last one is dropped.
    private var line = 0
    private var measuring = false
    private var writer: AVSpeechSynthesizer?

    /// The narrator is about to say `utterance`: measure a copy of it offline.
    func willSpeak(_ utterance: AVSpeechUtterance) {
        stop()
        guard VisualSound.shared.watching > 0, let copy = utterance.copy() as? AVSpeechUtterance else { return }
        measuring = true
        let w = writer ?? AVSpeechSynthesizer()
        writer = w
        w.write(copy, toBufferCallback: Steps(line: line) { [weak self] n, steps in
            guard let self, n == self.line else { return }
            self.steps += steps
        }.take)
    }

    /// The narrator's speech is now playing.
    func began() { if measuring { startedAt = CACurrentMediaTime() } }

    /// The line finished or was cut off.
    func stop() {
        line &+= 1
        if measuring { writer?.stopSpeaking(at: .immediate) }
        measuring = false
        steps = []
        startedAt = nil
    }

    func reading(now: CFTimeInterval = CACurrentMediaTime()) -> LevelMeter.Reading {
        guard let startedAt else { return .zero }
        let i = Int((now - startedAt) / Self.hop)
        return i >= 0 && i < steps.count ? steps[i] : .zero
    }

    #if DEBUG
    /// Tests: a line measured from `samples` that began at `at`.
    func load(_ samples: [Float], sampleRate: Double, at: CFTimeInterval) {
        let s = Steps(line: 0) { _, _ in }
        steps = s.measure(samples, sampleRate: sampleRate)
        measuring = true
        startedAt = at
    }
    #endif

    /// The synthesizer's buffers, on its own queue, cut into 10 ms steps (what is left
    /// over waits for the next buffer, so the steps keep time) and handed to the main actor.
    final class Steps: @unchecked Sendable {
        let line: Int
        let hand: @MainActor @Sendable (Int, [LevelMeter.Reading]) -> Void
        private let meter = LevelMeter()
        private var left: [Float] = []

        nonisolated init(line: Int, _ hand: @escaping @MainActor @Sendable (Int, [LevelMeter.Reading]) -> Void) {
            self.line = line
            self.hand = hand
        }

        nonisolated var take: @Sendable (AVAudioBuffer) -> Void {
            { [self] buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return }
                let n = Int(pcm.frameLength)
                var x: [Float]
                if let f = pcm.floatChannelData?[0] {
                    x = (0..<n).map { f[$0 * pcm.stride] }
                } else if let i = pcm.int16ChannelData?[0] {
                    x = (0..<n).map { Float(i[$0 * pcm.stride]) / 32768 }
                } else { return }
                let steps = measure(x, sampleRate: pcm.format.sampleRate)
                let line = self.line, hand = self.hand
                Task { @MainActor in hand(line, steps) }
            }
        }

        nonisolated func measure(_ x: [Float], sampleRate: Double) -> [LevelMeter.Reading] {
            left += x
            let hop = max(1, Int(sampleRate * VoiceTrack.hop))
            var out: [LevelMeter.Reading] = []
            var i = 0
            left.withUnsafeBufferPointer { p in
                while i + hop <= p.count {
                    out.append(meter.measure(p.baseAddress! + i, count: hop, sampleRate: sampleRate))
                    i += hop
                }
            }
            left.removeFirst(i)
            return out
        }
    }
}
