#if DEBUG
import CoreMIDI
import Foundation

/// UI tests only (Debug builds): `-yuiMIDIFeed <path>` makes a virtual MIDI
/// keyboard ("Test Keyboard") and a virtual destination ("Test Clock") in the
/// simulator's MIDI server, from inside the app, because iOS refuses virtual
/// endpoints to the test runner. The test appends UMP words in hex to <path>,
/// one message a line; they go out of the keyboard through CoreMIDI like a
/// real one. What the clock destination hears is written to <path>.clock as
/// JSON: starts, ticks, stops and the median gap between ticks in seconds.
final class MIDIFeed: @unchecked Sendable {
    nonisolated(unsafe) private static var shared: MIDIFeed?

    @MainActor static func startIfAsked() {
        guard shared == nil, let path = UserDefaults.standard.string(forKey: "yuiMIDIFeed") else { return }
        shared = MIDIFeed(path: path)
    }

    private let path: String
    private var client = MIDIClientRef()
    private var keyboard = MIDIEndpointRef()
    private var clock = MIDIEndpointRef()
    private var done = 0
    private let lock = NSLock()
    private var heard: [(UInt8, MIDITimeStamp)] = []
    private var timer: DispatchSourceTimer?

    private init(path: String) {
        self.path = path
        MIDIClientCreateWithBlock("Yui test feed" as CFString, &client, nil)
        MIDISourceCreateWithProtocol(client, "Test Keyboard" as CFString, ._1_0, &keyboard)
        MIDIDestinationCreateWithProtocol(client, "Test Clock" as CFString, ._1_0, &clock) { [weak self] list, _ in
            self?.take(list)
        }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        t.schedule(deadline: .now(), repeating: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        let lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n")
        while done < lines.count {
            if let w = UInt32(lines[done].trimmingCharacters(in: .whitespaces), radix: 16) {
                var list = MIDIEventList()
                let packet = MIDIEventListInit(&list, ._1_0)
                var word = w
                _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
                MIDIReceivedEventList(keyboard, &list)
            }
            done += 1
        }
        let h = lock.withLock { heard }
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ticks = h.filter { $0.0 == 0xF8 }.map { Double($0.1) * Double(info.numer) / Double(info.denom) / 1e9 }
        let gaps = zip(ticks, ticks.dropFirst()).map { $1 - $0 }.sorted()
        let summary: [String: Any] = ["starts": h.filter { $0.0 == 0xFA }.count, "ticks": ticks.count,
                                      "stops": h.filter { $0.0 == 0xFC }.count, "gap": gaps.isEmpty ? 0 : gaps[gaps.count / 2]]
        if let data = try? JSONSerialization.data(withJSONObject: summary) {
            try? data.write(to: URL(fileURLWithPath: path + ".clock"), options: .atomic)
        }
    }

    private func take(_ list: UnsafePointer<MIDIEventList>) {
        for packet in list.unsafeSequence() {
            let w = UnsafeRawPointer(packet).advanced(by: MemoryLayout<MIDIEventPacket>.offset(of: \.words)!).assumingMemoryBound(to: UInt32.self)
            for i in 0..<Int(packet.pointee.wordCount) where w[i] >> 28 == 1 {
                let status = UInt8(w[i] >> 16 & 0xFF)
                let stamp = packet.pointee.timeStamp
                lock.withLock { heard.append((status, stamp)) }
            }
        }
    }
}
#endif
