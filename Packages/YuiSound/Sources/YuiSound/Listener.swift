import AVFoundation
import Foundation
import os

// The tuner's ears (yuigui spec/MUSIC.md section 6). A second AVAudioEngine
// taps the microphone only while the tuner listens; the synth engine keeps
// playing reference tones. Each window is read for pitch and dropped at once:
// nothing is recorded, kept or sent (the purpose string says so).

@MainActor
public final class PitchListener {
    public enum State: Equatable, Sendable { case idle, asking, on, denied }

    public private(set) var state = State.idle
    /// A reading, or nil for "nothing clear", about 30 times a second.
    public var onReading: ((Pitch.Reading?) -> Void)?

    private var engine: AVAudioEngine?
    private var fakeTask: Task<Void, Never>?
    private var feed: Feed?

    public init() {}

    /// Asks for the mic the first time (never at launch), then listens.
    /// Returns the state it ends in: `.on`, or `.denied` when the person said
    /// no or there is no mic.
    @discardableResult
    public func start(_ tuning: Tuning) async -> State {
        guard state == .idle || state == .denied else { return state }
        state = .asking
        guard await Self.permission() else { state = .denied; return state }
        guard state == .asking else { return state } // stopped while asking
        YuiSound.shared.listening = true
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            YuiSound.shared.listening = false
            state = .denied
            return state
        }
        let feed = Feed(tuning: tuning, sampleRate: format.sampleRate) { [weak self] r in
            Task { @MainActor in self?.deliver(r) }
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let ch = buffer.floatChannelData?[0] else { return }
            feed.append(ch, count: Int(buffer.frameLength))
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            soundLog.error("mic start failed: \(error.localizedDescription, privacy: .public)")
            input.removeTap(onBus: 0)
            YuiSound.shared.listening = false
            state = .denied
            return state
        }
        self.engine = engine
        self.feed = feed
        state = .on
        return state
    }

    /// Listens to a made-up string instead of the mic (UI tests and demos):
    /// each step is a pitch held for some seconds, then the last one holds.
    public func startFake(_ steps: [(hz: Double, seconds: Double)], tuning: Tuning) {
        stop()
        let rate = 48000.0
        let feed = Feed(tuning: tuning, sampleRate: rate) { [weak self] r in
            Task { @MainActor in self?.deliver(r) }
        }
        self.feed = feed
        state = .on
        fakeTask = Task.detached(priority: .userInitiated) {
            let block = 1024
            var buf = [Float](repeating: 0, count: block)
            var phase = 0.0
            var t = 0.0
            let total = steps.reduce(0) { $0 + $1.seconds }
            while !Task.isCancelled {
                var at = 0.0
                var hz = steps.last?.hz ?? 440
                for s in steps { if t < at + s.seconds { hz = s.hz; break }; at += s.seconds }
                if t >= total { hz = steps.last?.hz ?? hz }
                for i in 0..<block {
                    phase += hz / rate
                    if phase >= 1 { phase -= 1 }
                    var x = 0.0
                    for h in 1...5 { x += sin(2 * .pi * phase * Double(h)) / Double(h) }
                    buf[i] = Float(0.3 * x)
                }
                buf.withUnsafeBufferPointer { feed.append($0.baseAddress!, count: block) }
                t += Double(block) / rate
                try? await Task.sleep(for: .seconds(Double(block) / rate))
            }
        }
    }

    public func stop() {
        fakeTask?.cancel()
        fakeTask = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        feed = nil
        if state == .on || state == .asking { state = .idle }
        if YuiSound.shared.listening { YuiSound.shared.listening = false }
    }

    private var lastSent = Date.distantPast

    private func deliver(_ r: Pitch.Reading?) {
        guard state == .on else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSent) >= 0.03 else { return }
        lastSent = now
        onReading?(r)
    }

    static func permission() async -> Bool {
        #if os(iOS)
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
        #else
        return true
        #endif
    }
}

/// Collects mic samples and reads a window every quarter window (75%
/// overlap) off the audio thread.
final class Feed: @unchecked Sendable {
    private let window: Int
    private let hop: Int
    private let sampleRate: Double
    private let range: (minHz: Double, maxHz: Double)
    private let queue = DispatchQueue(label: "com.yuigui.tuner", qos: .userInitiated)
    private let lock = OSAllocatedUnfairLock()
    private var ring: [Float]
    private var filled = 0
    private var sinceRead = 0
    private var busy = false
    private let out: (Pitch.Reading?) -> Void

    init(tuning: Tuning, sampleRate: Double, out: @escaping (Pitch.Reading?) -> Void) {
        // The table's windows are for 48 kHz; keep the same span at other rates.
        let w = Double(tuning.window) * sampleRate / 48000
        window = 1 << Int(log2(w).rounded())
        hop = window / 4
        self.sampleRate = sampleRate
        range = tuning.range
        ring = [Float](repeating: 0, count: window)
        self.out = out
    }

    func append(_ p: UnsafePointer<Float>, count: Int) {
        var snapshot: [Float]?
        lock.withLockUnchecked {
            // Shift left and append: windows are small, this is cheap.
            let n = min(count, window)
            if n < window { ring.withUnsafeMutableBufferPointer { b in
                b.baseAddress!.update(from: b.baseAddress! + n, count: window - n)
            } }
            ring.withUnsafeMutableBufferPointer { b in
                (b.baseAddress! + window - n).update(from: p + (count - n), count: n)
            }
            filled = min(window, filled + n)
            sinceRead += count
            if filled == window, sinceRead >= hop, !busy {
                sinceRead = 0
                busy = true
                snapshot = ring
            }
        }
        guard let snapshot else { return }
        queue.async { [self] in
            let r = Pitch.detect(snapshot, sampleRate: sampleRate, minHz: range.minHz, maxHz: range.maxHz)
            lock.withLockUnchecked { busy = false }
            out(r)
        }
    }
}
