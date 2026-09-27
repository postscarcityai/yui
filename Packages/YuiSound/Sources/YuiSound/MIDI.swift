import CoreMIDI
import Foundation
import Observation
import Synchronization

// MIDI (yuigui spec/MUSIC.md section 5, step 5). In: any MIDI keyboard the
// phone sees, over USB or Bluetooth (paired in Apple's own screen), plays the
// `keys` on screen. Out: MIDI clock (24 a beat, with start and stop) from
// the looper or the metronome, to every destination and to a virtual source
// named "Yui", so a drum machine or a DAW follows Yui's tempo.

let midiLog = Logger(subsystem: "com.yuigui.app", category: "midi")

import os

/// One MIDI 1.0 channel message.
public struct MIDIMessage: Equatable, Sendable {
    public var status: UInt8
    public var data1: UInt8
    public var data2: UInt8
}

enum UMP {
    /// Words in a Universal MIDI Packet by its type (the top 4 bits).
    static let size: [Int] = [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4]

    /// The MIDI 1.0 channel voice messages (UMP type 2) in a run of words.
    /// Everything else (clock, sysex, MIDI 2.0) is skipped.
    static func messages(_ words: UnsafeBufferPointer<UInt32>) -> [MIDIMessage] {
        var out: [MIDIMessage] = []
        var i = 0
        while i < words.count {
            let w = words[i]
            let type = Int(w >> 28)
            if type == 2 {
                out.append(MIDIMessage(status: UInt8(w >> 16 & 0xFF), data1: UInt8(w >> 8 & 0x7F), data2: UInt8(w & 0x7F)))
            }
            i += size[type]
        }
        return out
    }

    static func messages(_ words: [UInt32]) -> [MIDIMessage] { words.withUnsafeBufferPointer { messages($0) } }

    /// A system real-time message (clock, start, stop) as a UMP type 1 word.
    static func realtime(_ status: UInt8) -> UInt32 { 0x1000_0000 | UInt32(status) << 16 }
}

/// The CoreMIDI side, shared by input and clock: one client, made on first use.
final class MIDIHub: @unchecked Sendable {
    static let shared = MIDIHub()

    private(set) var client = MIDIClientRef()
    private(set) var input = MIDIPortRef()
    private(set) var output = MIDIPortRef()
    private(set) var virtualSource = MIDIEndpointRef()
    private let ready = Mutex(false)
    /// Called on CoreMIDI's thread for every channel message from any source.
    let onMessage = Mutex<(@Sendable (MIDIMessage) -> Void)?>(nil)
    /// Called when sources come or go.
    let onSetup = Mutex<(@Sendable () -> Void)?>(nil)

    /// Makes the client and ports. Safe to call often. false when CoreMIDI said no.
    @discardableResult func start() -> Bool {
        ready.withLock { done in
            if done { return true }
            var c = MIDIClientRef()
            var st = MIDIClientCreateWithBlock("Yui" as CFString, &c) { [weak self] note in
                if note.pointee.messageID == .msgSetupChanged { self?.setupChanged() }
            }
            guard st == noErr else { midiLog.error("client \(st)"); return false }
            client = c
            var inPort = MIDIPortRef()
            st = MIDIInputPortCreateWithProtocol(c, "Yui in" as CFString, ._1_0, &inPort) { [weak self] list, _ in
                self?.received(list)
            }
            guard st == noErr else { midiLog.error("in port \(st)"); return false }
            input = inPort
            var outPort = MIDIPortRef()
            st = MIDIOutputPortCreate(c, "Yui out" as CFString, &outPort)
            if st == noErr { output = outPort }
            var src = MIDIEndpointRef()
            st = MIDISourceCreateWithProtocol(c, "Yui" as CFString, ._1_0, &src)
            if st == noErr { virtualSource = src } else { midiLog.error("virtual source \(st)") }
            done = true
            connectAll()
            return true
        }
    }

    /// Listens to every source there is (a keyboard plugged in or paired later
    /// arrives through setupChanged). Never to our own virtual source.
    func connectAll() {
        guard input != 0 else { return }
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            if src == virtualSource { continue }
            MIDIPortConnectSource(input, src, nil)
        }
    }

    private func setupChanged() {
        connectAll()
        onSetup.withLock { $0 }?()
    }

    private func received(_ list: UnsafePointer<MIDIEventList>) {
        guard let handler = onMessage.withLock({ $0 }) else { return }
        for packet in list.unsafeSequence() {
            let count = Int(packet.pointee.wordCount)
            let words = UnsafeRawPointer(packet).advanced(by: MemoryLayout<MIDIEventPacket>.offset(of: \.words)!)
                .assumingMemoryBound(to: UInt32.self)
            for m in UMP.messages(UnsafeBufferPointer(start: words, count: min(count, 64))) { handler(m) }
        }
    }

    /// Names of the sources we listen to (keyboards), without our own.
    func sourceNames() -> [String] {
        (0..<MIDIGetNumberOfSources()).compactMap { i in
            let src = MIDIGetSource(i)
            guard src != virtualSource else { return nil }
            var name: Unmanaged<CFString>?
            guard MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &name) == noErr, let n = name?.takeRetainedValue() else { return nil }
            return n as String
        }
    }

    /// Sends real-time words at host times to every destination and out of
    /// the virtual source.
    func send(_ events: [(status: UInt8, host: MIDITimeStamp)]) {
        guard !events.isEmpty, client != 0 else { return }
        // A MIDIEventList holds 64 words; one word a packet at its own time is
        // 4 words of room each, so go in lists of 8.
        var i = 0
        while i < events.count {
            var list = MIDIEventList()
            var packet: UnsafeMutablePointer<MIDIEventPacket>? = MIDIEventListInit(&list, ._1_0)
            for e in events[i..<min(i + 8, events.count)] {
                guard let p = packet else { break }
                var word = UMP.realtime(e.status)
                packet = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, p, e.host, 1, &word)
            }
            if output != 0 {
                for d in 0..<MIDIGetNumberOfDestinations() { MIDISendEventList(output, MIDIGetDestination(d), &list) }
            }
            if virtualSource != 0 { MIDIReceivedEventList(virtualSource, &list) }
            i += 8
        }
    }
}

// MARK: - In

/// A MIDI keyboard plays the `keys` on screen. The keys view attaches while
/// it shows and names its sound; notes play on the engine like a finger on
/// a key, and `held` lights them.
@MainActor @Observable
public final class MIDIKeyboard {
    public static let shared = MIDIKeyboard()

    /// Notes held on a MIDI keyboard now.
    public private(set) var held: Set<Int> = []
    /// The MIDI inputs the phone sees (a USB or paired Bluetooth keyboard).
    public private(set) var inputs: [String] = []
    /// Notes that came in, newest last (the last 64), and how many ever did,
    /// so a view can take each new one even when two land together.
    public private(set) var notes: [Int] = []
    public private(set) var hits = 0

    @ObservationIgnored private let router = Router()
    @ObservationIgnored private var users = 0

    private init() {}

    /// A keys view appeared: MIDI notes play `sound` until detach.
    public func attach(sound: String) {
        users += 1
        router.sound.withLock { $0 = sound }
        guard users == 1 else { return }
        router.engine = YuiSound.shared
        router.onChange = { [weak self] note, on in
            Task { @MainActor in self?.update(note, on) }
        }
        let hub = MIDIHub.shared
        hub.onMessage.withLock { $0 = { [router] m in router.handle(m) } }
        hub.onSetup.withLock { $0 = { Task { @MainActor in MIDIKeyboard.shared.refresh() } } }
        hub.start()
        hub.connectAll()
        refresh()
    }

    /// The keys view's sound changed.
    public func use(sound: String) { router.sound.withLock { $0 = sound } }

    public func detach() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        MIDIHub.shared.onMessage.withLock { $0 = nil }
        router.allOff()
        held = []
    }

    public func refresh() { inputs = MIDIHub.shared.sourceNames() }

    private func update(_ note: Int, _ on: Bool) {
        if on {
            held.insert(note)
            notes = Array((notes + [note]).suffix(64))
            hits += 1
        } else {
            held.remove(note)
        }
    }

    /// Note on and off from CoreMIDI's thread to the engine.
    final class Router: @unchecked Sendable {
        let sound = Mutex("keys")
        nonisolated(unsafe) var engine: YuiSound?
        nonisolated(unsafe) var onChange: (@Sendable (Int, Bool) -> Void)?
        /// The engine tag for each sounding note, by channel and note.
        private let tags = Mutex([UInt32](repeating: 0, count: 16 * 128))

        func handle(_ m: MIDIMessage) {
            let kind = m.status & 0xF0
            let slot = Int(m.status & 0x0F) * 128 + Int(m.data1)
            if kind == 0x90, m.data2 > 0 {
                guard let engine else { return }
                let old = tags.withLock { t in let o = t[slot]; t[slot] = 0; return o }
                if old != 0 { engine.noteOff(old) }
                let tag = engine.noteOn(Int(m.data1), sound: sound.withLock { $0 }, velocity: Float(m.data2) / 127)
                tags.withLock { $0[slot] = tag }
                onChange?(Int(m.data1), true)
            } else if kind == 0x80 || kind == 0x90 {
                let tag = tags.withLock { t in let o = t[slot]; t[slot] = 0; return o }
                if tag != 0 { engine?.noteOff(tag) }
                onChange?(Int(m.data1), false)
            } else if kind == 0xB0, m.data1 == 123 || m.data1 == 120 {
                allOff() // all notes off, all sound off
            }
        }

        func allOff() {
            let all = tags.withLock { t in let o = t.filter { $0 != 0 }; t = [UInt32](repeating: 0, count: 16 * 128); return o }
            for tag in all { engine?.noteOff(tag) }
        }
    }
}

// MARK: - Clock out

/// Clock ticks on the engine's sample clock: 24 a beat from an anchor, and
/// a tempo change lands on the next tick, like the looper's.
struct ClockPlan: Equatable {
    static let perBeat = 24.0
    var anchor: Double
    var anchorTick: Int64 = 0
    var samplesPerTick: Double
    /// The next tick to send.
    var next: Int64 = 0

    init(start: Double, bpm: Double, sampleRate: Double) {
        anchor = start
        samplesPerTick = sampleRate * 60 / bpm / Self.perBeat
    }

    func time(_ tick: Int64) -> Double { anchor + Double(tick - anchorTick) * samplesPerTick }

    /// A new tempo from the next tick on.
    mutating func set(bpm: Double, sampleRate: Double) {
        let spt = sampleRate * 60 / bpm / Self.perBeat
        guard abs(spt - samplesPerTick) > 1e-9 else { return }
        anchor = time(next)
        anchorTick = next
        samplesPerTick = spt
    }

    /// Ticks due before `sample`, with their sample times; moves `next` on.
    mutating func due(before sample: Double) -> [Double] {
        var out: [Double] = []
        while time(next) < sample {
            out.append(time(next))
            next += 1
        }
        return out
    }
}

/// Sends the clock while the looper or the metronome plays: Start on its
/// first beat, 24 ticks a beat stamped for when the beat is heard, Stop when
/// it stops. A 5 ms timer schedules 30 ms ahead; CoreMIDI sends each at its time.
final class MIDIClockOut: @unchecked Sendable {
    struct Source: Equatable {
        var start: Int64
        var bpm: Double
    }

    private let queue = DispatchQueue(label: "com.yuigui.midi-clock", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var plan: ClockPlan?
    private var playing: Source?
    let lookahead = 0.03

    /// What should drive the clock now (nil: nothing plays).
    let source: @Sendable () -> Source?
    /// Sample time to host time (with output latency), nil before the engine renders.
    let hostTime: @Sendable (Double) -> MIDITimeStamp?
    let now: @Sendable () -> Double
    let sampleRate: @Sendable () -> Double

    init(source: @escaping @Sendable () -> Source?, now: @escaping @Sendable () -> Double,
         sampleRate: @escaping @Sendable () -> Double, hostTime: @escaping @Sendable (Double) -> MIDITimeStamp?) {
        self.source = source
        self.now = now
        self.sampleRate = sampleRate
        self.hostTime = hostTime
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            MIDIHub.shared.start()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.fire() }
            t.resume()
            timer = t
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            if playing != nil { MIDIHub.shared.send([(0xFC, 0)]) }
            playing = nil
            plan = nil
        }
    }

    private func fire() {
        let sr = sampleRate()
        let src = source()
        var out: [(status: UInt8, host: MIDITimeStamp)] = []
        if src?.start != playing?.start {
            if playing != nil { out.append((0xFC, 0)) }
            plan = src.map { ClockPlan(start: Double($0.start), bpm: $0.bpm, sampleRate: sr) }
            if let src, let h = hostTime(Double(src.start)) { out.append((0xFA, h)) }
        } else if let src, src.bpm != playing?.bpm {
            plan?.set(bpm: src.bpm, sampleRate: sr)
        }
        playing = src
        if var p = plan {
            // Ticks already more than 20 ms late (the app was away) are skipped, not sent in a burst.
            let late = now() - 0.02 * sr
            for t in p.due(before: now() + lookahead * sr) where t >= late {
                if let h = hostTime(t) { out.append((0xF8, h)) }
            }
            plan = p
        }
        MIDIHub.shared.send(out)
    }
}
