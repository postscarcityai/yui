import AVFoundation
import Observation
import Speech

/// Hold to talk (TestFlight feedback ABEd9FQg0MUy5hNiDKEy13Q): hold the mic,
/// speak, let go and the words send as text. Recognition runs on the phone
/// when it can, so no audio leaves it. First slice of YUI-14 (voice in, text out).
/// Let go sends, slide left cancels, and a waveform follows your voice while it listens
/// (TestFlight feedback AFxu7cyMxK1BmzLnKcwsPzw).
@Observable @MainActor
final class PushToTalk {
    enum Phase: Equatable { case idle, listening, denied, failed }

    private(set) var phase: Phase = .idle
    /// What it has heard so far.
    private(set) var transcript = ""
    /// 0...1, the mic's loudness right now.
    private(set) var level: Double = 0
    /// The last `bars` loudness peaks, oldest first, one every `barEvery` seconds: the waveform.
    private(set) var levels: [Double] = []
    /// When it started listening, for the clock.
    private(set) var startedAt: Date?
    static let bars = 36
    static let barEvery: TimeInterval = 0.08
    private var peak: Double = 0
    private var lastBar = Date.distantPast

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finish: CheckedContinuation<Void, Never>?

    var listening: Bool { phase == .listening }

    #if DEBUG
    /// `-yuiPTTFake "words"`: start() listens to nothing and hears these words, so UI tests
    /// can drive the real hold, slide and let-go on a simulator with no mic.
    var fakeWords: String?

    /// `-yuiPTTDemo "words"`: the listening state with those words, for screenshots (the simulator has no mic).
    func demo(_ words: String) {
        transcript = words
        startedAt = .now.addingTimeInterval(-4)
        phase = .listening
        for i in 0..<Self.bars { levels.append(Self.fakeLevel(i)) }
        Task {
            var i = Self.bars
            while phase == .listening, request == nil {
                take(level: Self.fakeLevel(i)); i += 1
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    private static func fakeLevel(_ i: Int) -> Double {
        let t = Double(i)
        return min(max(0.45 + 0.3 * sin(t * 0.55) + 0.2 * sin(t * 1.9 + 1), 0.05), 1)
    }
    #endif

    /// A new loudness from the mic. Keeps the loudest since the last bar and adds a bar every `barEvery`.
    func take(level l: Double, at now: Date = .now) {
        level = l
        peak = max(peak, l)
        guard now.timeIntervalSince(lastBar) >= Self.barEvery else { return }
        levels.append(peak)
        if levels.count > Self.bars { levels.removeFirst(levels.count - Self.bars) }
        peak = 0
        lastBar = now
    }

    /// Starts listening. Asks for the mic and speech the first time.
    func start() async {
        guard phase != .listening else { return }
        transcript = ""
        resetMeters()
        #if DEBUG
        if let fakeWords { demo(fakeWords); return }
        #endif
        guard await Self.authorized() else { phase = .denied; return }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { phase = .failed; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            request = req
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            // No usable mic (a call has it, a route is changing, the simulator): a 0 Hz
            // format makes installTap raise an exception Swift can't catch.
            guard format.sampleRate > 0, format.channelCount > 0 else {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                request = nil
                phase = .failed
                return
            }
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format,
                             block: Self.tap(req) { [weak self] level in self?.take(level: level) })
            engine.prepare()
            try engine.start()
            task = recognizer.recognitionTask(with: req, resultHandler: Self.heard { [weak self] text, done in
                guard let self else { return }
                if let text { self.transcript = text }
                if done { self.finish?.resume(); self.finish = nil }
            })
            startedAt = .now
            phase = .listening
        } catch {
            stopEngine()
            phase = .failed
        }
    }

    /// Stops and returns what it heard, after the recognizer's last word (at most ~1.5 s).
    func stop() async -> String {
        guard phase == .listening else { return "" }
        #if DEBUG
        if request == nil { phase = .idle; resetMeters(); return transcript }  // demo
        #endif
        stopEngine()
        request?.endAudio()
        await withCheckedContinuation { c in
            finish = c
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1500))
                self.finish?.resume(); self.finish = nil
            }
        }
        task?.cancel()
        task = nil
        request = nil
        phase = .idle
        resetMeters()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Slid to the trash: stop at once and throw the words away.
    func cancel() {
        guard phase == .listening else { return }
        if request != nil {
            stopEngine()
            request?.endAudio()
            task?.cancel()
            task = nil
            request = nil
            finish?.resume(); finish = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        transcript = ""
        resetMeters()
        phase = .idle
    }

    private func resetMeters() {
        level = 0; peak = 0; levels = []; startedAt = nil; lastBar = .distantPast
    }

    /// Let go of the "can't listen" note.
    func reset() { if phase != .listening { phase = .idle } }

    private func stopEngine() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    // The system calls these back on its own threads. A closure written inside this
    // @MainActor class is main-actor isolated, and Swift 6 traps when one runs off the
    // main thread (TestFlight crash ANv4a2bHdXMMaEjjhTva5ZA, build 57: hold the mic the
    // first time). So they are built in nonisolated code and hop to the main actor.

    nonisolated private static func authorized() async -> Bool {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    /// The mic tap, on the audio thread: feeds the recognizer and reports loudness.
    nonisolated static func tap(_ req: SFSpeechAudioBufferRecognitionRequest,
                                level: @escaping @MainActor @Sendable (Double) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            req.append(buffer)
            let l = Self.level(buffer)
            Task { @MainActor in level(l) }
        }
    }

    /// The recognizer's results, on its queue: the words so far, and whether it is done.
    nonisolated static func heard(_ update: @escaping @MainActor @Sendable (String?, Bool) -> Void)
        -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let done = error != nil || result?.isFinal == true
            Task { @MainActor in update(text, done) }
        }
    }

    nonisolated private static func level(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        return Double(min(max((20 * log10(max(rms, 1e-6)) + 50) / 50, 0), 1))
    }
}
