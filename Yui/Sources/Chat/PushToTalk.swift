import AVFoundation
import Observation
import Speech

/// Hold to talk (TestFlight feedback ABEd9FQg0MUy5hNiDKEy13Q): hold the mic,
/// speak, let go and the words send as text. Let go sends, slide left cancels, and a
/// waveform follows your voice while it listens (TestFlight feedback AFxu7cyMxK1BmzLnKcwsPzw).
///
/// Voice in, text out (YUI-14): the words come from iOS 26's SpeechAnalyzer with a
/// SpeechTranscriber, on the phone. Words show as you say them (volatile results) and
/// settle as you go (final results), so letting go only waits for the last few. When the
/// transcriber's model isn't on the phone yet, it downloads in the background and this
/// time uses the older recognizer, on-device only. Audio never leaves the phone; only
/// the text is sent. Hands-free (HandsFree.swift) drives the same listener.
@Observable @MainActor
final class PushToTalk {
    enum Phase: Equatable { case idle, listening, denied, failed }
    /// Which recognizer is listening: `analyzer` is SpeechAnalyzer, `classic` SFSpeechRecognizer.
    enum Engine: Equatable { case none, analyzer, classic }

    private(set) var phase: Phase = .idle
    private(set) var engineKind: Engine = .none
    /// What it has heard so far.
    private(set) var transcript = ""
    /// 0...1, the mic's loudness right now.
    private(set) var level: Double = 0
    /// The last `bars` loudness peaks, oldest first, one every `barEvery` seconds: the waveform.
    private(set) var levels: [Double] = []
    /// When it started listening, for the clock.
    private(set) var startedAt: Date?
    /// When the words or the voice last changed: hands-free ends a turn after a quiet spell.
    private(set) var lastSound: Date?
    /// The last stop, from the end of the audio to the final words, in ms (voice_final).
    private(set) var lastFinalMs: Double?
    /// The audio session was interrupted (a call, Siri, an alarm). Hands-free pauses on it.
    private(set) var interrupted = false
    static let bars = 36
    static let barEvery: TimeInterval = 0.08
    /// Louder than this counts as talking (about -30 dB).
    static let speaking = 0.4
    private var peak: Double = 0
    private var lastBar = Date.distantPast

    private let engine = AVAudioEngine()
    // Classic.
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    // Analyzer.
    private var analyzer: SpeechAnalyzer?
    private var feed: AsyncStream<AnalyzerInput>.Continuation?
    private var reading: Task<Void, Never>?
    private var finish: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var interruptions: NSObjectProtocol?

    var listening: Bool { phase == .listening }

    init() {
        interruptions = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main,
            using: Self.interruption { [weak self] began in self?.interrupt(began) })
    }

    #if DEBUG
    /// `-yuiPTTFake "words"`: start() listens to nothing and hears these words, so UI tests
    /// can drive the real hold, slide and let-go on a simulator with no mic. The voice goes
    /// quiet after `fakeTalk` seconds, so hands-free hears the end of the turn.
    var fakeWords: String?
    var fakeTalk: TimeInterval = 1.2
    private var fake = false

    /// `-yuiPTTDemo "words"`: the listening state with those words, for screenshots (the simulator has no mic).
    func demo(_ words: String, talkFor: TimeInterval = .infinity) {
        transcript = words
        startedAt = .now.addingTimeInterval(-4)
        lastSound = .now
        phase = .listening
        engineKind = .none
        fake = true
        for i in 0..<Self.bars { levels.append(Self.fakeLevel(i)) }
        let quietAt = Date.now.addingTimeInterval(talkFor)
        Task {
            var i = Self.bars
            while phase == .listening, fake {
                take(level: Date.now < quietAt ? Self.fakeLevel(i) : 0.03); i += 1
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
        if l >= Self.speaking { lastSound = now }
        guard now.timeIntervalSince(lastBar) >= Self.barEvery else { return }
        levels.append(peak)
        if levels.count > Self.bars { levels.removeFirst(levels.count - Self.bars) }
        peak = 0
        lastBar = now
    }

    /// New words: they count as sound, so a quiet talker isn't cut off mid-sentence.
    private func hear(_ text: String) {
        if text != transcript { lastSound = .now }
        transcript = text
    }

    /// Starts listening. Asks for the mic and speech the first time.
    func start() async {
        guard phase != .listening else { return }
        transcript = ""
        lastFinalMs = nil
        resetMeters()
        #if DEBUG
        if let fakeWords { demo(fakeWords, talkFor: fakeTalk); return }
        #endif
        guard await Self.authorized() else { phase = .denied; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            // No usable mic (a call has it, a route is changing, the simulator): a 0 Hz
            // format makes installTap raise an exception Swift can't catch.
            guard format.sampleRate > 0, format.channelCount > 0 else {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                phase = .failed
                return
            }
            input.removeTap(onBus: 0)
            if let transcriber = await Self.transcriber() {
                try await startAnalyzer(transcriber, input: input, format: format)
            } else {
                guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable,
                      recognizer.supportsOnDeviceRecognition else {
                    try? session.setActive(false, options: .notifyOthersOnDeactivation)
                    phase = .failed
                    return
                }
                startClassic(recognizer, input: input, format: format)
            }
            engine.prepare()
            try engine.start()
            startedAt = .now
            lastSound = .now
            interrupted = false
            phase = .listening
        } catch {
            stopEngine()
            teardown()
            phase = .failed
        }
    }

    private func startAnalyzer(_ transcriber: SpeechTranscriber, input: AVAudioInputNode, format: AVAudioFormat) async throws {
        let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: format) ?? format
        let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: target)
        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer
        self.feed = feed
        engineKind = .analyzer
        reading = Task { [weak self] in
            var words = Transcript()
            do {
                for try await r in transcriber.results {
                    words.take(String(r.text.characters), final: r.isFinal)
                    self?.hear(words.text)
                }
            } catch {}
            self?.finish?.resume(); self?.finish = nil
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format,
                         block: Self.analyzerTap(feed, from: format, to: target) { [weak self] level in self?.take(level: level) })
    }

    private func startClassic(_ recognizer: SFSpeechRecognizer, input: AVAudioInputNode, format: AVAudioFormat) {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // Audio never leaves the phone (YUI-14): no server recognition, ever.
        req.requiresOnDeviceRecognition = true
        request = req
        engineKind = .classic
        input.installTap(onBus: 0, bufferSize: 1024, format: format,
                         block: Self.tap(req) { [weak self] level in self?.take(level: level) })
        task = recognizer.recognitionTask(with: req, resultHandler: Self.heard { [weak self] text, done in
            guard let self else { return }
            if let text { self.hear(text) }
            if done { self.finish?.resume(); self.finish = nil }
        })
    }

    /// Stops and returns what it heard, after the recognizer's last word (at most ~1.5 s).
    func stop() async -> String {
        guard phase == .listening else { return "" }
        #if DEBUG
        if fake { fake = false; phase = .idle; resetMeters(); return transcript }  // demo
        #endif
        let ended = CACurrentMediaTime()
        stopEngine()
        let analyzer = self.analyzer
        feed?.finish()
        request?.endAudio()
        await withCheckedContinuation { c in
            finish = c
            if let analyzer { Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() } }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1500))
                self.finish?.resume(); self.finish = nil
            }
        }
        lastFinalMs = (CACurrentMediaTime() - ended) * 1000
        Perf.shared.span(.voiceFinal, from: ended)
        teardown()
        phase = .idle
        resetMeters()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Slid to the trash, or hands-free stopped: stop at once and throw the words away.
    func cancel() {
        guard phase == .listening else { return }
        #if DEBUG
        fake = false
        #endif
        if engineKind != .none {
            stopEngine()
            feed?.finish()
            request?.endAudio()
            if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
            teardown()
            finish?.resume(); finish = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        transcript = ""
        resetMeters()
        phase = .idle
    }

    private func teardown() {
        task?.cancel(); task = nil; request = nil
        reading?.cancel(); reading = nil; analyzer = nil; feed = nil
        engineKind = .none
    }

    private func resetMeters() {
        level = 0; peak = 0; levels = []; startedAt = nil; lastBar = .distantPast; lastSound = nil
    }

    /// Let go of the "can't listen" note.
    func reset() { if phase != .listening { phase = .idle } }

    private func interrupt(_ began: Bool) {
        interrupted = began
        if began { cancel() }
    }

    private func stopEngine() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    /// The words so far: the settled ones, then the ones still changing.
    struct Transcript: Equatable {
        private(set) var settled = ""
        private(set) var volatile = ""
        var text: String { Self.join(settled, volatile) }

        mutating func take(_ words: String, final: Bool) {
            if final { settled = Self.join(settled, words); volatile = "" } else { volatile = words }
        }

        private static func join(_ a: String, _ b: String) -> String {
            let a = a.trimmingCharacters(in: .whitespaces), b = b.trimmingCharacters(in: .whitespaces)
            return a.isEmpty ? b : b.isEmpty ? a : a + " " + b
        }
    }

    /// The on-device transcriber for this phone's language, if its model is installed.
    /// Not yet: asks for the download and returns nil, so this turn uses the classic recognizer.
    nonisolated static func transcriber() async -> SpeechTranscriber? {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else { return nil }
        let t = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                  reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        switch await AssetInventory.status(forModules: [t]) {
        case .installed: return t
        case .supported, .downloading:
            Task.detached(priority: .utility) { try? await AssetInventory.assetInstallationRequest(supporting: [t])?.downloadAndInstall() }
            return nil
        default: return nil
        }
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

    /// Mic and speech are already allowed: an agent set to Talk can open the mic without a prompt.
    nonisolated static var allowed: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized && AVAudioApplication.shared.recordPermission == .granted
    }

    nonisolated private static func interruption(_ began: @escaping @MainActor @Sendable (Bool) -> Void)
        -> @Sendable (Notification) -> Void {
        { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            Task { @MainActor in began(type == .began) }
        }
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

    /// The analyzer's tap, on the audio thread: converts to the transcriber's format and feeds it.
    nonisolated static func analyzerTap(_ feed: AsyncStream<AnalyzerInput>.Continuation,
                                        from: AVAudioFormat, to: AVAudioFormat,
                                        level: @escaping @MainActor @Sendable (Double) -> Void) -> AVAudioNodeTapBlock {
        nonisolated(unsafe) let converter = from == to ? nil : AVAudioConverter(from: from, to: to)
        return { buffer, _ in
            if let out = Self.convert(buffer, with: converter, to: to) { feed.yield(AnalyzerInput(buffer: out)) }
            let l = Self.level(buffer)
            Task { @MainActor in level(l) }
        }
    }

    nonisolated static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter?,
                                    to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate + 1)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? out : nil
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

    nonisolated static func level(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        return Double(min(max((20 * log10(max(rms, 1e-6)) + 50) / 50, 0), 1))
    }
}
