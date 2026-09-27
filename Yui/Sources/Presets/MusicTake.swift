import CoreAudioKit
import SwiftUI
import YuiLines
import YuiSound

// Step 5 of the music tools (YUI-116, yuigui spec/MUSIC.md sections 3 and 5):
// Record on the looper, drums, keys and chords records what the engine plays
// (never the mic) to an .m4a and a .mid, and sends both to the agent the way
// a camera photo goes: uploaded to the thread's media, the event carrying
// signed links. And MIDI: a keyboard over USB or Bluetooth plays the keys.

enum TakeUpload {
    enum Failure: Error { case signedOut, noLink }

    /// Uploads a take and returns the event's fields: `audio` and `midi`
    /// (signed links, good for 7 days), `seconds`.
    @MainActor static func fields(_ take: Take, media: YuiMedia?) async throws -> [String: YLValue] {
        var out: [String: YLValue] = ["seconds": .number((take.seconds * 10).rounded() / 10)]
        let midi = try? Data(contentsOf: take.midi)
        defer {
            try? FileManager.default.removeItem(at: take.audio)
            try? FileManager.default.removeItem(at: take.midi)
        }
        guard let media else {
            // UI tests on the demo account: no upload, the event says what it would carry.
            guard UserDefaults.standard.bool(forKey: "yuiTakeFake") else { throw Failure.signedOut }
            let size = (try? FileManager.default.attributesOfItem(atPath: take.audio.path)[.size] as? Int) ?? 0
            out["audio"] = .string("https://take.invalid/\(size)-bytes.m4a")
            if let midi { out["midi"] = .string("https://take.invalid/\(midi.count)-bytes.mid") }
            out["notes"] = .number(Double(take.notes.count))
            return out
        }
        let audioPath = try await media.upload(try Data(contentsOf: take.audio), type: "audio/mp4", ext: "m4a")
        guard let audio = await media.link(path: audioPath) else { throw Failure.noLink }
        out["audio"] = .string(audio.absoluteString)
        if let midi, !midi.isEmpty {
            let midiPath = try await media.upload(midi, type: "audio/midi", ext: "mid")
            if let link = await media.link(path: midiPath) { out["midi"] = .string(link.absoluteString) }
        }
        return out
    }

    static func echo(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s < 60 ? "Sent a take, \(s) s" : "Sent a take, \(s / 60):\(String(format: "%02d", s % 60))"
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}

/// Record, then Stop and send. One take at a time across the screen.
struct TakeControl: View {
    let c: YLComponent
    /// The MIDI file's tempo, so its bars line up with the music.
    var bpm: Double = 120
    /// Anything else the event should carry (the loop's pattern).
    var extra: () -> [String: YLValue] = { [:] }
    @State private var phase = Phase.idle
    private var host: MusicHost { .shared }
    @Environment(\.ylEmit) private var emit
    @Environment(\.yuiMedia) private var media
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    enum Phase: Equatable { case idle, recording, sending, sent(Double), failed(String) }

    private var mine: Bool { host.takeOwner == c.serial }

    var body: some View {
        let s = theme.swatch(scheme)
        HStack(spacing: theme.spacing.s) {
            MusicButton(text: label, icon: phase == .recording ? "stop.fill" : "record.circle", on: phase == .recording) {
                phase == .recording ? stop() : start()
            }
            .disabled(c.locked || phase == .sending || (host.takeOwner != nil && !mine))
            .accessibilityIdentifier("take-record")
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                status(s)
            }
            Spacer(minLength: 0)
        }
        .onDisappear { if phase == .recording { stop() } }
    }

    private var label: String {
        switch phase {
        case .recording: "Stop and send"
        case .sending: "Sending"
        case .sent: "Record again"
        default: "Record"
        }
    }

    @ViewBuilder private func status(_ s: Swatch) -> some View {
        let text: String? = switch phase {
        case .recording:
            TakeUpload.clock(YuiSound.shared.takeSeconds)
        case .sending: "Sending the take"
        case .sent(let secs): "Take sent, \(TakeUpload.clock(secs))"
        case .failed(let why): why
        case .idle: nil
        }
        if let text {
            HStack(spacing: theme.spacing.xs) {
                if phase == .recording { Circle().fill(s.accent).frame(width: 8, height: 8) }
                Text(text)
                    .font(theme.font(theme.type.caption, .bold))
                    .foregroundStyle(phase == .recording ? s.accent : s.inkSoft)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("take-status")
            .onChange(of: phase == .recording && YuiSound.shared.takeSeconds >= YuiSound.maxTakeSeconds) { _, full in
                if full { stop() }
            }
        }
    }

    private func start() {
        do {
            try YuiSound.shared.startTake()
            host.takeOwner = c.serial
            phase = .recording
        } catch {
            phase = .failed("Couldn't record. Try again.")
        }
    }

    private func stop() {
        guard phase == .recording else { return }
        let take = YuiSound.shared.stopTake(bpm: bpm)
        if mine { host.takeOwner = nil }
        guard let take, take.seconds >= 0.5 else {
            phase = .failed("Too short. Play, then stop.")
            return
        }
        phase = .sending
        let extra = extra()
        Task { @MainActor in
            do {
                var fields = try await TakeUpload.fields(take, media: media)
                fields.merge(extra) { a, _ in a }
                emit(c.event(fields, echo: TakeUpload.echo(take.seconds)))
                phase = .sent(take.seconds)
            } catch TakeUpload.Failure.signedOut {
                phase = .failed("Takes need a signed-in account")
            } catch {
                phase = .failed("Couldn't send it. Try again.")
            }
        }
    }
}

// MARK: - MIDI keyboard

/// On the keys: the MIDI keyboard the phone sees, or MIDI to pair one over
/// Bluetooth in Apple's own screen (no pairing screen of our own).
struct MIDIButton: View {
    @State private var pairing = false
    private var midi: MIDIKeyboard { .shared }

    var body: some View {
        let name = midi.inputs.first
        MusicButton(text: name.map { String($0.prefix(14)) } ?? "MIDI", icon: "pianokeys", on: name != nil) { pairing = true }
            .accessibilityLabel(name.map { "MIDI keyboard \($0)" } ?? "Connect a MIDI keyboard")
            .accessibilityIdentifier("keys-midi")
            .sheet(isPresented: $pairing, onDismiss: { midi.refresh() }) {
                BluetoothMIDIPairing()
                    .ignoresSafeArea()
            }
    }
}

/// Apple's Bluetooth MIDI screen (CABTMIDICentralViewController): finds and
/// pairs keyboards nearby. A USB keyboard needs nothing; it just plays.
struct BluetoothMIDIPairing: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        let central = CABTMIDICentralViewController()
        central.title = "Bluetooth MIDI"
        let nav = UINavigationController(rootViewController: central)
        central.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak nav] _ in
            nav?.dismiss(animated: true)
        })
        return nav
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}
