import AVFoundation
import CoreMIDI
import Foundation
import Synchronization
import Testing
@testable import YuiSound

// Step 5 (yuigui spec/MUSIC.md section 3 and 8): a take records what the
// engine plays to AAC at 48 kHz plus a MIDI file of the same notes; MIDI in
// plays the engine; MIDI clock goes out 24 a beat.

/// A Standard MIDI File read back: (track name, [(tick, status, d1, d2)]), plus ppq and tempo.
struct ReadMIDI {
    var format = 0
    var ppq = 0
    var tempo = 0 // microseconds per beat
    var tracks: [(name: String, events: [(tick: Int, status: UInt8, d1: UInt8, d2: UInt8)])] = []

    init(_ data: Data) throws {
        let b = [UInt8](data)
        func be(_ i: Int, _ n: Int) -> Int { (0..<n).reduce(0) { $0 << 8 | Int(b[i + $1]) } }
        guard String(bytes: b[0..<4], encoding: .ascii) == "MThd" else { throw CocoaError(.fileReadCorruptFile) }
        format = be(8, 2)
        let count = be(10, 2)
        ppq = be(12, 2)
        var i = 14
        for _ in 0..<count {
            guard String(bytes: b[i..<(i + 4)], encoding: .ascii) == "MTrk" else { throw CocoaError(.fileReadCorruptFile) }
            let len = be(i + 4, 4)
            var p = i + 8
            let end = p + len
            var tick = 0
            var name = ""
            var events: [(Int, UInt8, UInt8, UInt8)] = []
            func vlq() -> Int { var v = 0; while true { let c = b[p]; p += 1; v = v << 7 | Int(c & 0x7F); if c & 0x80 == 0 { return v } } }
            while p < end {
                tick += vlq()
                let st = b[p]; p += 1
                if st == 0xFF {
                    let type = b[p]; p += 1
                    let n = vlq()
                    if type == 0x03 { name = String(bytes: b[p..<(p + n)], encoding: .utf8) ?? "" }
                    if type == 0x51 { tempo = be(p, 3) }
                    p += n
                } else if st & 0xF0 == 0xC0 {
                    events.append((tick, st, b[p], 0)); p += 1
                } else {
                    events.append((tick, st, b[p], b[p + 1])); p += 2
                }
            }
            tracks.append((name, events.map { (tick: $0.0, status: $0.1, d1: $0.2, d2: $0.3) }))
            i = end
        }
    }

    /// Note-ons (velocity > 0) across tracks: (tick, channel, note).
    var ons: [(tick: Int, channel: Int, note: Int)] {
        var out: [(tick: Int, channel: Int, note: Int)] = []
        for t in tracks {
            for e in t.events where e.status & 0xF0 == 0x90 && e.d2 > 0 {
                out.append((tick: e.tick, channel: Int(e.status & 0x0F), note: Int(e.d1)))
            }
        }
        out.sort { a, b in a.tick != b.tick ? a.tick < b.tick : a.note < b.note }
        return out
    }
}

/// Renders the kernel into stereo buffers and hands them to the writer, as the mixer tap does.
func feed(_ w: TakeWriter, _ k: SynthKernel, seconds: Double, block: Int = 1024) {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    var left = Int(seconds * rate)
    while left > 0 {
        let n = min(block, left)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        k.render(frames: n, into: buf.floatChannelData![0])
        buf.floatChannelData![1].update(from: buf.floatChannelData![0], count: n)
        w.append(buf)
        left -= n
    }
}

@Suite(.serialized)
struct TakeTests {
    @Test("the MIDI file reads back: header, tempo, one named track per sound, notes on the grid")
    func midiFile() throws {
        let notes = [
            TakeNote(start: 0, length: 0.1, note: 36, velocity: 115, channel: 9),
            TakeNote(start: 0.5, length: 0.1, note: 38, velocity: 100, channel: 9),
            TakeNote(start: 0.25, length: 0.5, note: 60, velocity: 90, channel: 0),
            TakeNote(start: 0.25, length: 0.5, note: 64, velocity: 90, channel: 0),
        ]
        let m = try ReadMIDI(MIDIFile.data(notes, bpm: 120))
        #expect(m.format == 1 && m.ppq == 480)
        #expect(m.tempo == 500_000) // 120 BPM
        #expect(m.tracks.map(\.name) == ["Yui take", "Keys", "Drums"])
        // 120 BPM: a beat is 0.5 s is 480 ticks.
        #expect(m.ons.map(\.tick) == [0, 240, 240, 480])
        #expect(m.ons.map(\.note) == [36, 60, 64, 38])
        #expect(m.ons.first { $0.note == 38 }?.channel == 9)
        // Keys carry their GM program (electric piano), drums none.
        #expect(m.tracks[1].events.first { $0.status == 0xC0 }?.d1 == 4)
        #expect(m.tracks[2].events.allSatisfy { $0.status & 0xF0 != 0xC0 })
        // Every note-on has its note-off, after it.
        for t in m.tracks.dropFirst() {
            let on = t.events.filter { $0.status & 0xF0 == 0x90 }.count
            let off = t.events.filter { $0.status & 0xF0 == 0x80 }.count
            #expect(on == off)
        }
        #expect(MIDIFile.vlq(0) == [0] && MIDIFile.vlq(127) == [0x7F] && MIDIFile.vlq(128) == [0x81, 0x00] && MIDIFile.vlq(0x0FFF_FFFF) == [0xFF, 0xFF, 0xFF, 0x7F])
    }

    @Test("a take of a playing loop: the .m4a is AAC at 48 kHz, as long as the take, not silent; the .mid has the loop's hits on its grid")
    func loopTake() throws {
        let k = SynthKernel(sampleRate: rate)
        // kick on 1 and 5, snare on 3 and 7, a hat every step: 8 steps of 8ths at 120 BPM (a step is 0.25 s).
        let grid: [[Bool]] = ["x...x...", "..x...x.", "xxxxxxxx"].map { $0.map { $0 == "x" } }
        let rows = Words.loop(["kick", "snare", "hat"], sound: "pluck")
        k.setLoop(rows: rows, masks: grid.map { r in r.enumerated().reduce(UInt32(0)) { $1.element ? $0 | 1 << UInt32($1.offset) : $0 } },
                  steps: 8, bpm: 120, swing: 0)
        k.startLoop()
        let w = try TakeWriter(kernel: k, sampleRate: rate)
        feed(w, k, seconds: 4)
        let take = try #require(w.finish(bpm: 120))
        defer { try? FileManager.default.removeItem(at: take.audio); try? FileManager.default.removeItem(at: take.midi) }

        #expect(abs(take.seconds - 4) < 0.001)
        let file = try AVAudioFile(forReading: take.audio)
        #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(file.fileFormat.sampleRate == 48000)
        #expect(file.fileFormat.channelCount == 2)
        let secs = Double(file.length) / file.fileFormat.sampleRate
        #expect(abs(secs - 4) < 0.1, "file is \(secs) s")
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buf)
        let x = buf.floatChannelData![0]
        let peak = (0..<Int(buf.frameLength)).reduce(Float(0)) { max($0, abs(x[$1])) }
        #expect(peak > 0.1, "peak \(peak)")
        let size = try FileManager.default.attributesOfItem(atPath: take.audio.path)[.size] as? Int ?? 0
        print("take: \(String(format: "%.2f", take.seconds)) s, \(size) bytes AAC, peak \(peak), \(take.notes.count) notes")

        // 4 s is two bars of 8 steps: 4 kicks, 4 snares, 16 hats.
        let m = try ReadMIDI(Data(contentsOf: take.midi))
        let ons = m.ons
        #expect(ons.filter { $0.note == 36 }.map(\.tick) == [0, 960, 1920, 2880])
        #expect(ons.filter { $0.note == 38 }.map(\.tick) == [480, 1440, 2400, 3360])
        #expect(ons.filter { $0.note == 42 }.map(\.tick) == (0..<16).map { $0 * 240 })
        #expect(ons.allSatisfy { $0.channel == 9 })
    }

    @Test("keys held by a finger end at the noteOff; a strum's notes land 25 ms apart; the metronome is not written")
    func keysAndStrum() throws {
        let k = SynthKernel(sampleRate: rate)
        k.setMetronome(bpm: 120, beats: 4, sub: 1)
        k.startMetronome()
        let w = try TakeWriter(kernel: k, sampleRate: rate)
        k.noteOn(.keys, midi: 60, velocity: 1, tag: 11)
        feed(w, k, seconds: 0.5)
        k.noteOff(tag: 11)
        k.noteOn(.pluck, midi: 55, velocity: 0.75, hold: -1, delay: 0)
        k.noteOn(.pluck, midi: 59, velocity: 0.75, hold: -1, delay: 0.025)
        k.noteOn(.pluck, midi: 62, velocity: 0.75, hold: -1, delay: 0.05)
        feed(w, k, seconds: 1)
        let take = try #require(w.finish(bpm: 120))
        defer { try? FileManager.default.removeItem(at: take.audio); try? FileManager.default.removeItem(at: take.midi) }
        let keys = take.notes.filter { $0.channel == 0 }
        #expect(keys.count == 1)
        #expect(abs((keys.first?.length ?? 0) - 0.5) < 0.03, "held \(keys.first?.length ?? 0)")
        let pluck = take.notes.filter { $0.channel == 1 }.sorted { $0.start < $1.start }
        #expect(pluck.map(\.note) == [55, 59, 62])
        if pluck.count == 3 {
            #expect(abs(pluck[1].start - pluck[0].start - 0.025) < 0.002)
            #expect(abs(pluck[2].start - pluck[1].start - 0.025) < 0.002)
        }
        #expect(take.notes.allSatisfy { $0.channel != 9 }, "a metronome click went into the MIDI file")
    }

    @Test("nothing is logged when no take records, and an empty take leaves no file")
    func quiet() throws {
        let k = SynthKernel(sampleRate: rate)
        k.noteOn(.kick, midi: -1, velocity: 1)
        _ = renderAll(k, seconds: 0.1)
        #expect(k.notes.drain().isEmpty)
        let w = try TakeWriter(kernel: k, sampleRate: rate)
        #expect(w.finish(bpm: 120) == nil)
        #expect(!FileManager.default.fileExists(atPath: w.audioURL.path))
        let logging = k.notes.on.load(ordering: .relaxed)
        #expect(!logging)
    }

    @Test("the render thread still allocates nothing while a take records")
    func noAllocation() throws {
        let k = SynthKernel(sampleRate: rate)
        let rows = Words.loop(["kick", "snare", "hat", "C4"], sound: "pluck")
        k.setLoop(rows: rows, masks: [0xFF, 0xFF, 0xFF, 0xFF], steps: 8, bpm: 240, swing: 0)
        k.startLoop()
        k.notes.on.store(true, ordering: .relaxed)
        let out = UnsafeMutablePointer<Float>.allocate(capacity: 256)
        defer { out.deallocate() }
        _ = renderAll(k, seconds: 0.5)
        let count = withAllocationCount {
            var i = 0
            while i < 400 { k.render(frames: 256, into: out); i += 1 }
        }
        k.notes.on.store(false, ordering: .relaxed)
        if let count { #expect(count == 0, "render allocated \(count) times while logging notes") }
        #expect(k.notes.drain().count > 50)
    }

    @Test("the whole engine records through the mixer tap (offline rendering)")
    @MainActor
    func graphTap() throws {
        let graph = SoundGraph(kernel: SynthKernel(sampleRate: rate))
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        do {
            try graph.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        } catch {
            print("offline rendering unavailable: \(error)")
            return
        }
        graph.build(sampleRate: rate)
        try graph.start()
        let mixer = graph.engine.mainMixerNode.outputFormat(forBus: 0)
        let w = try TakeWriter(kernel: graph.kernel, sampleRate: mixer.sampleRate, channels: mixer.channelCount)
        graph.tap(w)
        graph.kernel.noteOn(.snare, midi: -1, velocity: 1)
        let buffer = AVAudioPCMBuffer(pcmFormat: graph.engine.manualRenderingFormat, frameCapacity: 1024)!
        for _ in 0..<94 { _ = try graph.engine.renderOffline(1024, to: buffer) } // about 2 s
        graph.tap(nil)
        graph.stop()
        guard let take = w.finish(bpm: 120) else {
            print("the tap did not run in offline rendering; the writer is covered by loopTake")
            return
        }
        defer { try? FileManager.default.removeItem(at: take.audio); try? FileManager.default.removeItem(at: take.midi) }
        print("graph take \(take.seconds) s, notes \(take.notes.map(\.note))")
        #expect(take.seconds > 1)
        #expect(take.notes.map(\.note) == [38])
    }
}

@Suite(.serialized)
struct MIDITests {
    @Test("MIDI 1.0 channel messages come out of UMP words; clock and longer packets are skipped")
    func ump() {
        let words: [UInt32] = [
            0x2090_3C64, // note on C4 vel 100, ch 1
            0x10F8_0000, // clock (system, 1 word)
            0x4090_3C00, 0x1234_5678, // a MIDI 2.0 note on (2 words), skipped
            0x2080_3C00, // note off
            0x2099_2470, // note on, ch 10, kick
        ]
        let m = UMP.messages(words)
        #expect(m == [MIDIMessage(status: 0x90, data1: 60, data2: 100), MIDIMessage(status: 0x80, data1: 60, data2: 0),
                      MIDIMessage(status: 0x99, data1: 36, data2: 112)])
        #expect(UMP.realtime(0xF8) == 0x10F8_0000)
    }

    @Test("clock: 24 ticks a beat from the start, and a tempo change lands on the next tick")
    func clockPlan() {
        var p = ClockPlan(start: 1000, bpm: 120, sampleRate: rate)
        let beat = rate * 60 / 120
        let ticks = p.due(before: 1000 + beat)
        #expect(ticks.count == 24)
        #expect(ticks.first == 1000)
        #expect(abs(ticks[1] - ticks[0] - beat / 24) < 1e-9)
        // 4 minutes on: still on the grid (no drift from rounding).
        _ = p.due(before: 1000 + beat * 480)
        #expect(p.next == 24 * 480)
        #expect(abs(p.time(p.next) - (1000 + beat * 480)) < 1e-6)
        // 90 BPM from the next tick: that tick stays, the one after is a 90 BPM tick later.
        let next = p.time(p.next)
        p.set(bpm: 90, sampleRate: rate)
        #expect(p.time(p.next) == next)
        #expect(abs(p.time(p.next + 1) - next - rate * 60 / 90 / 24) < 1e-6)
    }

    @Test("a MIDI keyboard's note on and off play and release the engine; velocity 0 is an off")
    @MainActor
    func keyboardRouter() {
        let r = MIDIKeyboard.Router()
        r.engine = YuiSound.shared
        let k = YuiSound.shared.kernel
        var c = Command()
        while k.ring.pop(&c) {}
        r.sound.withLock { $0 = "pad" }
        r.handle(MIDIMessage(status: 0x90, data1: 64, data2: 127))
        var seen: [Command] = []
        while k.ring.pop(&c) { seen.append(c) }
        #expect(seen.count == 1 && seen[0].kind == .noteOn && seen[0].midi == 64 && seen[0].recipe == Recipe.pad.rawValue)
        #expect(seen.first?.velocity == 1)
        let tag = seen.first?.tag ?? 0
        r.handle(MIDIMessage(status: 0x90, data1: 64, data2: 0))
        seen = []
        while k.ring.pop(&c) { seen.append(c) }
        #expect(seen.count == 1 && seen[0].kind == .noteOff && seen[0].tag == tag)
        // An off for a note that is not down does nothing.
        r.handle(MIDIMessage(status: 0x80, data1: 64, data2: 0))
        #expect(!k.ring.pop(&c))
    }

    @Test("CoreMIDI round trip: a virtual keyboard's notes reach the hub; the clock reaches a destination with rising timestamps")
    func coreMIDI() async throws {
        let hub = MIDIHub.shared
        guard hub.start() else {
            print("CoreMIDI unavailable here")
            return
        }
        let got = Mutex<[MIDIMessage]>([])
        hub.onMessage.withLock { $0 = { m in got.withLock { $0.append(m) } } }
        defer { hub.onMessage.withLock { $0 = nil } }

        var client = MIDIClientRef()
        #expect(MIDIClientCreateWithBlock("YuiTest" as CFString, &client, nil) == noErr)
        var keyboard = MIDIEndpointRef()
        #expect(MIDISourceCreateWithProtocol(client, "Test Keyboard" as CFString, ._1_0, &keyboard) == noErr)
        let clock = Mutex<[(UInt32, MIDITimeStamp)]>([])
        var dest = MIDIEndpointRef()
        #expect(MIDIDestinationCreateWithProtocol(client, "Test Clock" as CFString, ._1_0, &dest) { list, _ in
            for packet in list.unsafeSequence() {
                let w = UnsafeRawPointer(packet).advanced(by: MemoryLayout<MIDIEventPacket>.offset(of: \.words)!).assumingMemoryBound(to: UInt32.self)
                for i in 0..<Int(packet.pointee.wordCount) { clock.withLock { $0.append((w[i], packet.pointee.timeStamp)) } }
            }
        } == noErr)
        defer { MIDIEndpointDispose(keyboard); MIDIEndpointDispose(dest); MIDIClientDispose(client) }
        try await Task.sleep(for: .milliseconds(300)) // the hub hears about the new source
        hub.connectAll()
        #expect(hub.sourceNames().contains("Test Keyboard"))

        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        var on: UInt32 = 0x2090_4064
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &on)
        #expect(MIDIReceivedEventList(keyboard, &list) == noErr)

        let now = mach_absolute_time()
        hub.send([(0xFA, now), (0xF8, now), (0xF8, now + 1000), (0xFC, now + 2000)])
        for _ in 0..<40 where got.withLock({ $0.isEmpty }) || clock.withLock({ $0.count < 4 }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(got.withLock { $0 } == [MIDIMessage(status: 0x90, data1: 0x40, data2: 0x64)])
        let c = clock.withLock { $0 }
        #expect(c.map { $0.0 >> 16 & 0xFF } == [0xFA, 0xF8, 0xF8, 0xFC])
        #expect(zip(c, c.dropFirst()).allSatisfy { pair in pair.1.1 >= pair.0.1 }, "timestamps go backwards")
    }
}
