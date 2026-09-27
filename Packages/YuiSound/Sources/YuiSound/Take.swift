import AVFoundation
import Foundation
import Synchronization

// Recording (yuigui spec/MUSIC.md section 3, step 5): what comes out of the
// engine, not the mic, to AAC (.m4a) at the engine's rate (48 kHz asked
// for), and the same take's notes as a MIDI file. The app uploads both the
// way it sends a camera photo.

/// A finished take on disk (in the temporary folder).
public struct Take: Sendable {
    public let audio: URL
    public let midi: URL
    public let seconds: Double
    public let notes: [TakeNote]
    public let sampleRate: Double
}

/// Writes one take. `append` runs on the tap's thread (not the render
/// thread), so it may allocate and write to disk.
final class TakeWriter: @unchecked Sendable {
    let audioURL: URL
    let midiURL: URL
    let sampleRate: Double
    private let kernel: SynthKernel
    private let startSample: Int64
    private struct State {
        var file: AVAudioFile?
        var frames: Int64 = 0
        var events: [NoteEvent] = []
    }
    private let state: Mutex<State>

    /// The longest take, in seconds (about 2 MB of audio).
    static let maxSeconds = 120.0

    init(kernel: SynthKernel, sampleRate: Double, channels: AVAudioChannelCount = 2, folder: URL = FileManager.default.temporaryDirectory) throws {
        let id = UUID().uuidString.lowercased()
        audioURL = folder.appending(path: "take-\(id).m4a")
        midiURL = folder.appending(path: "take-\(id).mid")
        self.sampleRate = sampleRate
        self.kernel = kernel
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 160_000,
        ]
        let file = try AVAudioFile(forWriting: audioURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        state = Mutex(State(file: file))
        _ = kernel.notes.drain() // anything left from before
        kernel.notes.dropped.store(0, ordering: .relaxed)
        startSample = kernel.rendered.load(ordering: .acquiring)
        kernel.notes.on.store(true, ordering: .releasing)
    }

    /// Seconds written so far.
    var seconds: Double { state.withLock { Double($0.frames) / sampleRate } }

    /// A buffer of engine output. Buffers at another rate or width (a route
    /// changed mid-take) are skipped rather than written wrong.
    func append(_ buffer: AVAudioPCMBuffer) {
        let fresh = kernel.notes.drain()
        state.withLock { s in
            s.events += fresh
            guard let file = s.file, buffer.frameLength > 0,
                  buffer.format.sampleRate == file.processingFormat.sampleRate,
                  buffer.format.channelCount == file.processingFormat.channelCount else { return }
            let room = Int64(Self.maxSeconds * sampleRate) - s.frames
            guard room > 0 else { return }
            if Int64(buffer.frameLength) > room { buffer.frameLength = AVAudioFrameCount(room) }
            do {
                try file.write(from: buffer)
                s.frames += Int64(buffer.frameLength)
            } catch {
                soundLog.error("take write: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Closes the audio, writes the MIDI file. nil for an empty take.
    func finish(bpm: Double) -> Take? {
        kernel.notes.on.store(false, ordering: .releasing)
        let fresh = kernel.notes.drain()
        let (frames, events): (Int64, [NoteEvent]) = state.withLock { s in
            s.events += fresh
            s.file?.close()
            s.file = nil
            return (s.frames, s.events)
        }
        guard frames > 0 else {
            try? FileManager.default.removeItem(at: audioURL)
            return nil
        }
        let notes = TakeNotes.from(events, start: startSample, end: startSample + frames, sampleRate: sampleRate)
        do {
            try MIDIFile.data(notes, bpm: bpm).write(to: midiURL)
        } catch {
            soundLog.error("take midi: \(error.localizedDescription, privacy: .public)")
        }
        let dropped = kernel.notes.dropped.load(ordering: .relaxed)
        if dropped > 0 { soundLog.error("take dropped \(dropped, privacy: .public) notes") }
        return Take(audio: audioURL, midi: midiURL, seconds: Double(frames) / sampleRate, notes: notes, sampleRate: sampleRate)
    }
}
