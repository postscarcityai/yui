import AVFoundation
import SwiftUI
import UIKit

// Hold to snap and say (YUI-166). Chris, build 244: "a picture alone is not good
// enough. I have to mention how much butter is in it or did I use copious amounts of
// cooking oil?" One press does both: the photo is taken the moment the finger goes
// down, the mic listens while it holds, and letting go sends the photo with the words
// as one message. Slide left to the trash throws both away, like hold to talk.

/// What a snap and say hands back: the photo, and what was said over it (maybe nothing).
struct SnapSaid {
    let photo: Data
    let words: String
}

/// The back camera, live, with one photo on demand. The session runs off the main thread.
@MainActor
final class SnapCamera {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "yui.snap.camera")
    private var shooting: PhotoTaken?
    private var configured = false
    /// No camera to use (the simulator, or the person said no).
    private(set) var unavailable = false

    #if DEBUG
    /// `-yuiSnapFake <path>`: that picture stands in for the camera (UI tests; the simulator has none).
    var fake: Data?
    #endif

    /// A camera to open, or (debug) the fake that stands in for one.
    static var available: Bool {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "yuiSnapFake") != nil { return true }
        #endif
        return UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func start() async {
        #if DEBUG
        if fake != nil { return }
        #endif
        guard await AVCaptureDevice.requestAccess(for: .video),
              let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { unavailable = true; return }
        if !configured {
            configured = true
            session.beginConfiguration()
            session.sessionPreset = .photo
            if session.canAddInput(input) { session.addInput(input) }
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
        }
        nonisolated(unsafe) let session = session
        queue.async { if !session.isRunning { session.startRunning() } }
    }

    func stop() {
        nonisolated(unsafe) let session = session
        queue.async { if session.isRunning { session.stopRunning() } }
    }

    /// One photo, now. nil when there is no camera.
    func capture() async -> Data? {
        #if DEBUG
        if let fake { return fake }
        #endif
        guard !unavailable, session.isRunning else { return nil }
        return await withCheckedContinuation { c in
            let taken = PhotoTaken.resuming(c)
            shooting = taken
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: taken)
        }
    }
}

/// The photo output's delegate, called on the camera's own queue.
private final class PhotoTaken: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let done: @Sendable (Data?) -> Void
    private var called = false
    init(done: @escaping @Sendable (Data?) -> Void) { self.done = done }

    /// Built off the main actor: the camera calls back on its own queue, and a closure
    /// made in main-actor code traps there under Swift 6 (see PushToTalk).
    nonisolated static func resuming(_ c: CheckedContinuation<Data?, Never>) -> PhotoTaken {
        PhotoTaken { c.resume(returning: $0) }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard !called else { return }
        called = true
        done(error == nil ? photo.fileDataRepresentation() : nil)
    }
}

/// The live picture behind the button.
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class Preview: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> Preview {
        let v = Preview()
        v.preview.session = session
        v.preview.videoGravity = .resizeAspectFill
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ view: Preview, context: Context) {}
}

/// The full screen: the camera, the words as they come, one big button.
struct SnapSayView: View {
    /// What the agent asked for (`camera "Snap your plate" +say`), or the default.
    var prompt: String? = nil
    let done: (SnapSaid?) -> Void

    @State private var camera = SnapCamera()
    @State private var talk = PushToTalk()
    @State private var shot: UIImage?
    @State private var photo: Data?
    /// The finger is on the button.
    @State private var holding = false
    /// How far left the finger is, 0 or less.
    @State private var dragX: CGFloat = 0
    @State private var sending = false
    @State private var note: String?
    /// The photo and the mic starting, from the finger going down.
    @State private var pressing: Task<Void, Never>?
    @GestureState private var press: CGFloat?
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let buttonSize: CGFloat = 84
    /// Past this far left, letting go throws the photo and the words away.
    static let cancelDistance: CGFloat = 110
    private var armed: Bool { holding && dragX <= -Self.cancelDistance }

    var body: some View {
        let c = theme.swatch(scheme)
        ZStack {
            Color.black.ignoresSafeArea()
            // Filled to the screen, never wider: a photo's own size would push the buttons off.
            Color.clear.overlay { picture }.clipped().ignoresSafeArea()
            VStack(spacing: 0) {
                topRow
                Spacer()
                words(c)
                bottomRow(c)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .preferredColorScheme(.dark)
        .task {
            #if DEBUG
            if let path = UserDefaults.standard.string(forKey: "yuiSnapFake") {
                camera.fake = FileManager.default.contents(atPath: path)
            }
            talk.fakeWords = UserDefaults.standard.string(forKey: "yuiPTTFake")
            // -yuiSnapDemo "words": held, the photo taken and those words heard, for screenshots.
            if let words = UserDefaults.standard.string(forKey: "yuiSnapDemo"), let fake = camera.fake {
                photo = fake
                shot = UIImage(data: fake)
                holding = true
                talk.demo(words)
                return
            }
            #endif
            await camera.start()
        }
        .onDisappear {
            camera.stop()
            talk.cancel()
        }
        .onChange(of: press) { old, new in
            if old == nil, new != nil { down() }
            if let x = new { dragX = min(0, x) }
            if old != nil, new == nil { up() }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: armed)
        .sensoryFeedback(.impact(weight: .light), trigger: shot != nil) { _, now in now }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("snap")
    }

    @ViewBuilder private var picture: some View {
        if let shot {
            Image(uiImage: shot).resizable().scaledToFill()
                .accessibilityIdentifier("snap-shot")
        } else {
            #if DEBUG
            if let fake = camera.fake, let image = UIImage(data: fake) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                live
            }
            #else
            live
            #endif
        }
    }

    @ViewBuilder private var live: some View {
        if camera.unavailable {
            Text("No camera here")
                .font(theme.font(theme.type.body, .bold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            CameraPreview(session: camera.session)
        }
    }

    private var topRow: some View {
        HStack {
            Button { finish(nil) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .accessibilityLabel("Close")
            .accessibilityIdentifier("snap-close")
            Spacer()
        }
        .padding(.top, 8)
    }

    /// What it hears, over the photo. Before the press: how it works.
    private func words(_ c: Swatch) -> some View {
        let heard = talk.transcript
        let line = note ?? (armed ? "Let go to throw it away"
            : holding ? (heard.isEmpty ? "Say what's in it" : heard)
            : prompt ?? "Hold to snap, then say what's in it")
        return VStack(spacing: 10) {
            if holding, !armed {
                TalkWaveform(levels: talk.levels, level: talk.level, color: c.accent,
                             track: .white.opacity(0.25), reduceMotion: reduceMotion)
                    .frame(maxWidth: 220)
            }
            Text(line)
                .font(theme.font(holding && !heard.isEmpty ? theme.type.title : theme.type.body, .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(5)
                .accessibilityIdentifier("snap-words")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.bottom, 22)
        .animation(reduceMotion ? nil : theme.spring, value: holding)
    }

    private func bottomRow(_ c: Swatch) -> some View {
        ZStack {
            // The trash, to the left: slide there to throw it away.
            HStack {
                Image(systemName: "trash.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(armed ? c.onAccent : .white)
                    .frame(width: 52, height: 52)
                    .background(armed ? c.accent : .black.opacity(0.45), in: Circle())
                    .scaleEffect(armed && !reduceMotion ? 1.15 : 1)
                    .opacity(holding ? 1 : 0)
                    .accessibilityHidden(true)
                Spacer()
            }
            button(c)
                .offset(x: reduceMotion ? 0 : max(dragX, -Self.cancelDistance - 20) * 0.5)
        }
        .animation(reduceMotion ? nil : theme.spring, value: armed)
    }

    private func button(_ c: Swatch) -> some View {
        ZStack {
            Circle().stroke(.white, lineWidth: 5)
                .frame(width: Self.buttonSize, height: Self.buttonSize)
            Circle().fill(armed ? c.inkSoft : c.accent)
                .frame(width: Self.buttonSize - 16, height: Self.buttonSize - 16)
                .scaleEffect(holding && !reduceMotion ? 0.86 : 1)
            Image(systemName: armed ? "trash.fill" : holding ? "waveform" : "camera.fill")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(c.onAccent)
                .symbolEffect(.variableColor.iterative, isActive: holding && !armed && !reduceMotion)
                .contentTransition(.symbolEffect(.replace))
            if sending { ProgressView().tint(c.onAccent) }
        }
        .frame(width: Self.buttonSize + 16, height: Self.buttonSize + 16)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($press) { v, state, _ in state = v.translation.width })
        .animation(reduceMotion ? nil : theme.spring, value: holding)
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Snap and say")
        .accessibilityHint("Hold to take the photo and say what's in it. Let go to send. Slide left to throw it away.")
        .accessibilityAction { Task { await snapOnly() } }
        .accessibilityIdentifier("snap-button")
        .disabled(sending)
    }

    // MARK: The press

    /// Finger down: the photo now, and the mic while it holds.
    private func down() {
        guard !sending else { return }
        holding = true
        dragX = 0
        note = nil
        pressing = Task {
            async let listening: Void = talk.start()
            let data = await camera.capture()
            photo = data
            shot = data.flatMap { Pictures.downsample($0, points: UIScreen.main.bounds.size, scale: 2) }
            await listening
        }
    }

    /// Finger up: send both, or throw both away. Waits for the press to finish first,
    /// so a quick tap still sends its photo.
    private func up() {
        let throwAway = armed
        holding = false
        dragX = 0
        let press = pressing
        Task {
            await press?.value
            if throwAway {
                talk.cancel()
                photo = nil
                shot = nil
                return
            }
            sending = true
            let words = await talk.stop()
            guard let photo else {
                sending = false
                note = camera.unavailable ? "No camera here" : "No photo. Try again."
                return
            }
            finish(SnapSaid(photo: photo, words: words))
        }
    }

    /// VoiceOver: one tap takes the photo alone.
    private func snapOnly() async {
        guard let data = await camera.capture() else { note = "No camera here"; return }
        finish(SnapSaid(photo: data, words: ""))
    }

    private func finish(_ said: SnapSaid?) {
        camera.stop()
        if said == nil { talk.cancel() }
        done(said)
    }
}
