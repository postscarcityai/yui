// YUI-14 step 1: how fast speech turns into final text, old recognizer vs new.
// The simulator has no on-device recognizer, so this runs on the Mac (Apple silicon,
// the same Speech framework as iOS 26). A spoken clip is fed at real time in 1024-frame
// buffers, the way the mic tap feeds it; per engine it prints the first words after the
// voice starts and the final words after the audio ends (let go, or hands-free's quiet).
//
//   swiftc -O scripts/voice_timing.swift -o build/voice_timing \
//     -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker scripts/voice_timing.plist
//   build/voice_timing YuiTests/Resources/voice-calendar.wav [runs]
import AVFoundation
import Foundation
import Speech

struct Timing { var first: Double?; var final: Double?; var text = "" }

func buffers(_ url: URL) throws -> [AVAudioPCMBuffer] {
    let file = try AVAudioFile(forReading: url)
    var out: [AVAudioPCMBuffer] = []
    while file.framePosition < file.length {
        let b = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024)!
        try file.read(into: b, frameCount: 1024)
        out.append(b)
    }
    return out
}

func ms(_ from: CFTimeInterval) -> Double { (CACurrentMediaTime() - from) * 1000 }
func pace(_ b: AVAudioPCMBuffer) async { try? await Task.sleep(for: .milliseconds(Int(1000 * Double(b.frameLength) / b.format.sampleRate))) }

final class Box<T>: @unchecked Sendable { var v: T; init(_ v: T) { self.v = v } }

func classic(_ bufs: [AVAudioPCMBuffer]) async -> Timing {
    let r = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    let req = SFSpeechAudioBufferRecognitionRequest()
    req.shouldReportPartialResults = true
    req.requiresOnDeviceRecognition = r.supportsOnDeviceRecognition
    let t = Box(Timing()), start = CACurrentMediaTime(), ended = Box(CFTimeInterval.infinity)
    let done = Box<CheckedContinuation<Void, Never>?>(nil)
    let task = r.recognitionTask(with: req) { res, err in
        if let s = res?.bestTranscription.formattedString, !s.isEmpty { t.v.text = s; if t.v.first == nil { t.v.first = ms(start) } }
        if err != nil || res?.isFinal == true, t.v.final == nil { t.v.final = ms(ended.v); done.v?.resume(); done.v = nil }
    }
    for b in bufs { req.append(b); await pace(b) }
    ended.v = CACurrentMediaTime()
    await withCheckedContinuation { c in
        done.v = c
        req.endAudio()
        if t.v.final != nil { c.resume(); done.v = nil }
    }
    task.cancel()
    return t.v
}

func analyzer(_ bufs: [AVAudioPCMBuffer]) async throws -> Timing {
    let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))!
    let tr = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
    if await AssetInventory.status(forModules: [tr]) != .installed {
        try await AssetInventory.assetInstallationRequest(supporting: [tr])?.downloadAndInstall()
    }
    let from = bufs[0].format
    let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [tr], considering: from) ?? from
    let conv = from == target ? nil : AVAudioConverter(from: from, to: target)
    let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()
    let an = SpeechAnalyzer(modules: [tr])
    try await an.prepareToAnalyze(in: target)
    try await an.start(inputSequence: stream)
    let t = Box(Timing()), start = CACurrentMediaTime(), ended = Box(CFTimeInterval.infinity)
    let reading = Task {
        var settled = "", volatile = ""
        for try await r in tr.results {
            let s = String(r.text.characters).trimmingCharacters(in: .whitespaces)
            if r.isFinal { settled = [settled, s].filter { !$0.isEmpty }.joined(separator: " "); volatile = "" } else { volatile = s }
            let text = [settled, volatile].filter { !$0.isEmpty }.joined(separator: " ")
            if t.v.first == nil, !text.isEmpty { t.v.first = ms(start) }
            t.v.text = text
        }
        t.v.final = ms(ended.v)
    }
    for b in bufs {
        var out = b
        if let conv {
            out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(b.frameLength) * target.sampleRate / from.sampleRate + 1))!
            var fed = false
            var e: NSError?
            conv.convert(to: out, error: &e) { _, st in if fed { st.pointee = .noDataNow; return nil }; fed = true; st.pointee = .haveData; return b }
        }
        feed.yield(AnalyzerInput(buffer: out))
        await pace(b)
    }
    ended.v = CACurrentMediaTime()
    feed.finish()
    try await an.finalizeAndFinishThroughEndOfInput()
    try await reading.value
    return t.v
}

let args = CommandLine.arguments
let url = URL(fileURLWithPath: args.count > 1 ? args[1] : "YuiTests/Resources/voice-calendar.wav")
let runs = args.count > 2 ? Int(args[2]) ?? 3 : 3
// No ask: a command-line tool can't show the prompt and would wait forever.
let auth = SFSpeechRecognizer.authorizationStatus()
print("speech authorization: \(auth.rawValue) (3 = authorized; classic runs only then)")
let bufs = try buffers(url)
func show(_ name: String, _ t: Timing) {
    let f = { (v: Double?) in v.map { String(format: "%.0f", $0) } ?? "-" }
    print("YUI14-TIMING engine=\(name) first_words_ms=\(f(t.first)) final_after_end_ms=\(f(t.final)) text=\"\(t.text)\"")
}
for _ in 0..<runs {
    if auth == .authorized { show("classic", await classic(bufs)) }
    do { show("analyzer", try await analyzer(bufs)) } catch { print("analyzer failed: \(error)") }
}
