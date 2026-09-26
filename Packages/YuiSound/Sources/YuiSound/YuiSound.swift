import AVFoundation
import Foundation
import os
import Synchronization

// The one sound engine for the music presets (yuigui spec/MUSIC.md sections
// 3 to 5): one AVAudioEngine, one AVAudioSourceNode that renders every voice
// from SynthKernel, a small room reverb, then the main mixer.

let soundLog = Logger(subsystem: "com.yuigui.app", category: "sound")

private let hostTicksToSeconds: Double = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(info.numer) / Double(info.denom) / 1_000_000_000
}()

/// The engine graph: source node, reverb, mixer. No session work, so tests
/// can run it offline on macOS.
final class SoundGraph {
    let engine = AVAudioEngine()
    let kernel: SynthKernel
    private(set) var source: AVAudioSourceNode?
    let reverb = AVAudioUnitReverb()
    /// Mono scratch the kernel renders into, sized for the largest buffer.
    private let scratch: UnsafeMutablePointer<Float>
    static let maxFrames = 4096

    init(kernel: SynthKernel) {
        self.kernel = kernel
        scratch = .allocate(capacity: Self.maxFrames)
        scratch.initialize(repeating: 0, count: Self.maxFrames)
        reverb.loadFactoryPreset(.smallRoom)
        reverb.wetDryMix = 12
        engine.attach(reverb)
    }

    deinit { scratch.deallocate() }

    /// The render block, made outside any actor so Swift 6 adds no isolation check.
    nonisolated static func renderBlock(kernel: SynthKernel, scratch: UnsafeMutablePointer<Float>) -> AVAudioSourceNodeRenderBlock {
        { _, timestamp, frameCount, bufferList in
            let abl = UnsafeMutableAudioBufferListPointer(bufferList)
            var done = 0
            let total = Int(frameCount)
            let host = timestamp.pointee.mFlags.contains(.hostTimeValid) ? timestamp.pointee.mHostTime : 0
            while done < total {
                let n = min(total - done, SoundGraph.maxFrames)
                kernel.render(frames: n, into: scratch, hostTime: done == 0 ? host : 0)
                var b = 0
                while b < abl.count {
                    if let data = abl[b].mData?.assumingMemoryBound(to: Float.self) {
                        (data + done).update(from: scratch, count: n)
                    }
                    b += 1
                }
                done += n
            }
            return noErr
        }
    }

    /// Wires the graph at the output's sample rate. Call while stopped.
    func build(sampleRate: Double? = nil) {
        if let source { engine.disconnectNodeOutput(source); engine.detach(source) }
        engine.disconnectNodeOutput(reverb)
        var sr = sampleRate ?? engine.outputNode.outputFormat(forBus: 0).sampleRate
        if sr <= 0 { sr = 48000 }
        kernel.reset(sampleRate: sr)
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let node = AVAudioSourceNode(format: format, renderBlock: Self.renderBlock(kernel: kernel, scratch: scratch))
        engine.attach(node)
        engine.connect(node, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)
        source = node
    }

    func start() throws {
        kernel.dropStaleNotes()
        engine.prepare()
        try engine.start()
    }

    func stop() { engine.stop() }
}

/// The app's one synth: pads, keys and the looper share its clock and voices.
public final class YuiSound: @unchecked Sendable {
    @MainActor public static let shared = YuiSound()

    /// Words the engine knows: the 16 kit words in pad order.
    public static let kit: [String] = Words.kit
    /// The pitched voices.
    public static let pitched: [String] = Words.pitched

    let kernel = SynthKernel()
    @MainActor private lazy var graph = SoundGraph(kernel: kernel)
    @MainActor private var users = 0
    @MainActor private var running = false
    @MainActor private var grace: Task<Void, Never>?
    @MainActor private var observers: [NSObjectProtocol] = []
    private let looping = Atomic<Bool>(false)
    /// Output latency in seconds, as bits, for the render clock math.
    private let latencyBits = Atomic<UInt64>(0)
    private let heardBits = Atomic<UInt64>(0)

    @MainActor private init() {}

    // MARK: Lifetime

    /// Ref-counted: an instrument view calls acquire() on appear, release()
    /// on disappear. The first acquire sets up the session and starts the engine.
    @MainActor public func acquire() {
        users += 1
        grace?.cancel()
        grace = nil
        if !running { start() }
    }

    /// The last release stops the loop and the engine after about 2 s and lets
    /// other apps' audio come back.
    @MainActor public func release() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        grace?.cancel()
        grace = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, self.users == 0 else { return }
            self.shutDown()
        }
    }

    /// true (default): .playback with .mixWithOthers, so a beat plays with the
    /// ringer on silent and still mixes with other apps' audio. Chris pressed
    /// Play on a silenced phone and heard nothing (feedback AGhvH8tM, Sep 26).
    /// false: .ambient (mixes, the silent switch mutes).
    @MainActor public var playsOnSilent = true {
        didSet { if running, oldValue != playsOnSilent { configureSession() } }
    }

    @MainActor private func start() {
        configureSession()
        observe()
        graph.build()
        do {
            try graph.start()
            running = true
        } catch {
            soundLog.error("engine start failed: \(error.localizedDescription, privacy: .public)")
            running = false
        }
        updateLatency()
    }

    @MainActor private func shutDown() {
        stopLoop()
        graph.stop()
        running = false
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    @MainActor private func configureSession() {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        do {
            if playsOnSilent {
                try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            } else {
                try s.setCategory(.ambient, mode: .default, options: [])
            }
            try s.setPreferredSampleRate(48000)
            try s.setPreferredIOBufferDuration(0.005)
            try s.setActive(true)
        } catch {
            soundLog.error("session: \(error.localizedDescription, privacy: .public)")
        }
        #if DEBUG
        soundLog.debug("session io \(s.ioBufferDuration, privacy: .public) s, rate \(s.sampleRate, privacy: .public), out latency \(s.outputLatency, privacy: .public) s")
        #endif
        #endif
    }

    @MainActor private func observe() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: graph.engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        })
        #if os(iOS)
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let ended = raw.flatMap { AVAudioSession.InterruptionType(rawValue: $0) } == .ended
            MainActor.assumeIsolated {
                guard let self else { return }
                if ended { self.restart() } else { self.graph.stop() }
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateLatency() }
        })
        #endif
    }

    /// After a route change or an interruption: rebuild at the new rate and go on.
    @MainActor private func restart() {
        guard users > 0 || grace != nil else { return }
        graph.stop()
        configureSession()
        graph.build()
        do { try graph.start() } catch {
            soundLog.error("engine restart failed: \(error.localizedDescription, privacy: .public)")
        }
        updateLatency()
    }

    @MainActor private func updateLatency() {
        latencyBits.store(outputLatency.bitPattern, ordering: .relaxed)
    }

    // MARK: Playing

    /// Play now (touch down). `word` is a kit word, a pitched voice word, or a
    /// note name like "C4", "F#3", "Bb2" (then `sound` picks the pitched voice).
    /// Unknown words play the family default. Held voices let go after 0.5 s.
    public func play(_ word: String, sound: String = "pluck", velocity: Float = 1) {
        let (recipe, midi) = Words.resolve(word, sound: sound)
        kernel.noteOn(recipe, midi: midi, velocity: max(0, min(velocity, 1)), hold: recipe.isHeld ? 0.5 : -1)
    }

    private let tags = Atomic<UInt32>(0)

    /// Starts a note that sounds until noteOff (touch down on a key). Held
    /// voices (pad, bass, lead) sustain; the others decay on their own and
    /// fade faster once let go. Returns the tag noteOff takes.
    @discardableResult
    public func noteOn(_ midi: Int, sound: String = "keys", velocity: Float = 1) -> UInt32 {
        var tag = tags.add(1, ordering: .relaxed).newValue
        if tag == 0 { tag = tags.add(1, ordering: .relaxed).newValue }
        kernel.noteOn(Words.sound(sound, pitched: true), midi: midi, velocity: max(0, min(velocity, 1)), tag: tag)
        return tag
    }

    /// The finger lifted (or slid to another key).
    public func noteOff(_ tag: UInt32) {
        guard tag != 0 else { return }
        kernel.noteOff(tag: tag)
    }

    /// How a chord's notes go out: low to high, high to low, or all at once.
    public enum Strum: String, CaseIterable, Sendable { case down, up, off }

    /// Strums MIDI notes, low first (down), high first (up) or together (off),
    /// `spacing` seconds apart on the engine's clock. Held voices ring for `hold` s.
    public func strum(_ notes: [Int], sound: String = "pluck", direction: Strum = .down, spacing: Double = 0.025,
                      hold: Double = 1.4, velocity: Float = 0.75) {
        let recipe = Words.sound(sound, pitched: true)
        let order = direction == .up ? Array(notes.reversed()) : notes
        for (k, m) in order.enumerated() {
            let delay = direction == .off ? 0 : Float(Double(k) * spacing)
            kernel.noteOn(recipe, midi: m, velocity: max(0, min(velocity, 1)), hold: recipe.isHeld ? Float(hold) : -1, delay: delay)
        }
    }

    /// The looper. rows: words (kit words or note names); pattern: one [Bool]
    /// per row (missing rows empty). Applies on the next step while playing.
    public func setLoop(rows: [String], sound: String, steps: Int, bpm: Double, swing: Double, pattern: [[Bool]]) {
        let resolved = rows.map { Words.resolve($0, sound: sound) }
        let masks: [UInt32] = rows.indices.map { r in
            guard r < pattern.count else { return 0 }
            var m: UInt32 = 0
            for (k, on) in pattern[r].prefix(32).enumerated() where on { m |= 1 << UInt32(k) }
            return m
        }
        kernel.setLoop(rows: resolved, masks: masks, steps: steps, bpm: bpm, swing: swing)
    }

    public func startLoop() {
        looping.store(true, ordering: .relaxed)
        kernel.startLoop()
    }

    public func stopLoop() {
        looping.store(false, ordering: .relaxed)
        kernel.stopLoop()
    }

    public var isLooping: Bool { looping.load(ordering: .relaxed) }

    // MARK: Clock

    /// The sample being heard now: the last render's first sample, moved on by
    /// host time since then, less the output latency. Never goes backwards.
    private func heardSample() -> Double {
        let sr = kernel.sampleRate
        let latency = Double(bitPattern: latencyBits.load(ordering: .relaxed))
        var host: UInt64 = 0
        var sample: Int64 = 0
        for _ in 0..<4 {
            host = kernel.lastHost.load(ordering: .acquiring)
            sample = kernel.lastSample.load(ordering: .acquiring)
            if kernel.lastHost.load(ordering: .acquiring) == host { break }
        }
        var heard: Double
        if host != 0 {
            let elapsed = (Double(mach_absolute_time()) - Double(host)) * hostTicksToSeconds
            heard = Double(sample) + max(0, min(elapsed, 0.2)) * sr - latency * sr
        } else {
            heard = Double(kernel.rendered.load(ordering: .relaxed)) - latency * sr
        }
        heard = max(heard, 0)
        // Keep it monotonic across callers.
        var old = heardBits.load(ordering: .relaxed)
        while true {
            let prev = Double(bitPattern: old)
            if heard <= prev { return prev }
            let (ok, now) = heardBits.compareExchange(expected: old, desired: heard.bitPattern, ordering: .relaxed)
            if ok { return heard }
            old = now
        }
    }

    /// The step you can hear now (shifted by output latency), nil when stopped.
    /// Safe to call every frame from the main thread.
    public var audibleStep: Int? {
        guard isLooping, let start = kernel.loopStartSample else { return nil }
        let heard = Int64(heardSample())
        guard heard >= start else { return nil }
        return kernel.step(at: heard)
    }

    /// Seconds since the engine clock started, as heard (for drum take recording).
    public var audibleTime: Double { heardSample() / kernel.sampleRate }

    /// When step 0 of the current loop run is (or was) heard, on the
    /// `audibleTime` clock. nil when the loop is stopped.
    public var loopStartTime: Double? {
        guard isLooping, let start = kernel.loopStartSample else { return nil }
        return Double(start) / kernel.sampleRate
    }

    // MARK: Route and timing

    /// True when output goes to Bluetooth (pads will feel late).
    @MainActor public var isBluetooth: Bool {
        #if os(iOS)
        let bt: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { bt.contains($0.portType) }
        #else
        return false
        #endif
    }

    /// The IO buffer the hardware gave (the preferred 5 ms is a hint).
    @MainActor public var ioBufferDuration: TimeInterval {
        #if os(iOS)
        return AVAudioSession.sharedInstance().ioBufferDuration
        #else
        return 0.005
        #endif
    }

    /// Output latency of the current route.
    @MainActor public var outputLatency: TimeInterval {
        #if os(iOS)
        return AVAudioSession.sharedInstance().outputLatency
        #else
        return graph.engine.outputNode.presentationLatency
        #endif
    }
}
