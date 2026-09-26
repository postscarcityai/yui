import AVFoundation
import Speech
import XCTest
@testable import Yui

/// YUI-14 step 1, measured: a spoken clip (Resources/voice-calendar.wav, macOS `say`,
/// 2.85 s) fed at real time into each recognizer the way the mic feeds it. Two numbers per
/// engine: the first words on screen after the voice starts, and the final words after the
/// audio ends (let go, or hands-free's quiet). Prints `YUI14-TIMING` lines; fails only if
/// nothing was heard. Needs speech granted (TCC row) or it skips rather than hang on the ask.
@MainActor
final class VoiceTimingTests: XCTestCase {
    struct Timing { var firstWords: Double?; var final: Double?; var text = "" }

    private func clip() throws -> AVAudioFile {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "voice-calendar", withExtension: "wav"))
        return try AVAudioFile(forReading: url)
    }

    private func buffers(_ file: AVAudioFile) throws -> [AVAudioPCMBuffer] {
        var out: [AVAudioPCMBuffer] = []
        while file.framePosition < file.length {
            let b = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024))
            try file.read(into: b, frameCount: 1024)
            out.append(b)
        }
        return out
    }

    private func requireSpeech() throws {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw XCTSkip("speech recognition is not granted on this simulator (see the TCC.db note)")
        }
    }

    /// Before YUI-14: SFSpeechRecognizer as hold to talk shipped it (partials, on-device when it can).
    func testClassicRecognizer() async throws {
        try requireSpeech()
        let file = try clip()
        let recognizer = try XCTUnwrap(SFSpeechRecognizer(locale: Locale(identifier: "en-US")))
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        var t = Timing()
        let start = CACurrentMediaTime()
        var ended: CFTimeInterval = .infinity
        let done = expectation(description: "final")
        let task = recognizer.recognitionTask(with: req, resultHandler: PushToTalk.heard { text, fin in
            let now = CACurrentMediaTime()
            if let text, !text.isEmpty { t.text = text; if t.firstWords == nil { t.firstWords = (now - start) * 1000 } }
            if fin, t.final == nil { t.final = (now - ended) * 1000; done.fulfill() }
        })
        for b in try buffers(file) {
            req.append(b)
            try await Task.sleep(for: .milliseconds(Int(1000 * Double(b.frameLength) / b.format.sampleRate)))
        }
        ended = CACurrentMediaTime()
        req.endAudio()
        await fulfillment(of: [done], timeout: 10)
        task.cancel()
        report("classic on-device=\(req.requiresOnDeviceRecognition)", t)
        // The simulator has no on-device recognizer: it errors at once. scripts/voice_timing.swift runs this on the Mac.
        if t.text.isEmpty { throw XCTSkip("no on-device recognizer here") }
    }

    /// After YUI-14: SpeechAnalyzer + SpeechTranscriber (volatile + fast results), as PushToTalk runs it.
    func testSpeechAnalyzer() async throws {
        try requireSpeech()
        var transcriber = await PushToTalk.transcriber()
        if transcriber == nil, SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) {
            // First run on this simulator: install the model, then go.
            let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
            try await AssetInventory.assetInstallationRequest(supporting: [t])?.downloadAndInstall()
            transcriber = await PushToTalk.transcriber()
        }
        guard let transcriber_ = transcriber else { throw XCTSkip("no SpeechTranscriber on this device (the simulator has none)") }
        let file = try clip()
        let from = file.processingFormat
        let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber_], considering: from) ?? from
        let converter = from == target ? nil : AVAudioConverter(from: from, to: target)
        let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber_])
        try await analyzer.prepareToAnalyze(in: target)
        try await analyzer.start(inputSequence: stream)
        var t = Timing()
        let start = CACurrentMediaTime()
        var ended: CFTimeInterval = .infinity
        let reading = Task { @MainActor in
            var words = PushToTalk.Transcript()
            for try await r in transcriber_.results {
                words.take(String(r.text.characters), final: r.isFinal)
                if t.firstWords == nil, !words.text.isEmpty { t.firstWords = (CACurrentMediaTime() - start) * 1000 }
                t.text = words.text
            }
            t.final = (CACurrentMediaTime() - ended) * 1000
        }
        for b in try buffers(file) {
            if let out = PushToTalk.convert(b, with: converter, to: target) { feed.yield(AnalyzerInput(buffer: out)) }
            try await Task.sleep(for: .milliseconds(Int(1000 * Double(b.frameLength) / b.format.sampleRate)))
        }
        ended = CACurrentMediaTime()
        feed.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await reading.value
        report("analyzer", t)
        XCTAssertFalse(t.text.isEmpty, "the analyzer heard nothing")
    }

    private func report(_ engine: String, _ t: Timing) {
        let f = { (v: Double?) in v.map { String(format: "%.0f", $0) } ?? "-" }
        print("YUI14-TIMING engine=\(engine) first_words_ms=\(f(t.firstWords)) final_after_end_ms=\(f(t.final)) text=\"\(t.text)\"")
    }
}
