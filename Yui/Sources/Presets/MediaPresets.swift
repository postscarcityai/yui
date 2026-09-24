import AVKit
import PhotosUI
import SwiftUI
import YuiLines

// `image`, `video` and `camera` (spec yuigui/spec/YL.md). Gallery, compare,
// storyboard and image edit are YUI-19; they reuse RemoteImage.

/// A picture from a YL URL, re-signed when its link has expired.
struct RemoteImage: View {
    let src: URL
    var fit: ContentMode = .fill
    @State private var url: URL?
    @Environment(\.yuiMedia) private var media
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        AsyncImage(url: url, transaction: Transaction(animation: theme.spring)) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: fit)
            case .failure:
                Label("Picture unavailable", systemImage: "photo.badge.exclamationmark")
                    .font(theme.font(theme.type.caption, .bold))
                    .foregroundStyle(s.inkSoft)
                    .frame(maxWidth: .infinity, minHeight: 160)
                    .background(s.background)
            default:
                s.background.overlay(ProgressView().tint(s.accent)).frame(minHeight: 160)
            }
        }
        .task(id: src) { url = await media?.fresh(src) ?? src }
    }
}

/// `image URL [caption]`, or `image prompt` (no URL) while the picture is being made.
struct ImagePreset: View {
    let c: YLComponent
    @State private var zoomed = false
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        let caption = c.string("caption") ?? c.string("alt")
        if let src = YLMediaURL.url(c.string("src")) {
            VStack(alignment: .leading, spacing: theme.spacing.s) {
                RemoteImage(src: src, fit: c.string("fit") == "contain" ? .fit : .fill)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 420)
                    .clipShape(.rect(cornerRadius: theme.radius.card))
                    .overlay(RoundedRectangle(cornerRadius: theme.radius.card).stroke(s.outline, lineWidth: 1.5))
                    .contentShape(.rect)
                    .onTapGesture { zoomed = true }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(c.string("alt") ?? caption ?? "Picture")
                    .accessibilityAddTraits(.isImage)
                if let caption {
                    Text(caption)
                        .font(theme.font(theme.type.caption, .semibold))
                        .foregroundStyle(s.inkSoft)
                }
            }
            .fullScreenCover(isPresented: $zoomed) { ZoomedImage(src: src, close: { zoomed = false }) }
        } else {
            PresetCard {
                Label("Making a picture", systemImage: "paintbrush.pointed.fill")
                    .font(theme.font(theme.type.caption, .bold))
                    .foregroundStyle(s.inkSoft)
                if let prompt = c.string("prompt") ?? caption {
                    Text(prompt).font(theme.font(theme.type.body, .medium)).foregroundStyle(s.ink)
                }
            }
        }
    }
}

private struct ZoomedImage: View {
    let src: URL
    let close: () -> Void
    @State private var scale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            RemoteImage(src: src, fit: .fit)
                .scaleEffect(scale)
                .gesture(MagnifyGesture().onChanged { scale = max(1, $0.magnification) }
                    .onEnded { _ in withAnimation { scale = 1 } })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button("Close", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly)
                .font(.title2.bold())
                .foregroundStyle(.white)
                .padding()
        }
    }
}

/// `video URL [caption] [+loop] [+auto] [+mute]`.
struct VideoPreset: View {
    let c: YLComponent
    @State private var player: AVPlayer?
    @State private var looper: Any?
    @Environment(\.yuiMedia) private var media
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        let src = YLMediaURL.url(c.string("src"))
        VStack(alignment: .leading, spacing: theme.spacing.s) {
            if src != nil {
                Group {
                    if let player { VideoPlayer(player: player) } else { s.background.overlay(ProgressView().tint(s.accent)) }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(.rect(cornerRadius: theme.radius.card))
                .overlay(RoundedRectangle(cornerRadius: theme.radius.card).stroke(s.outline, lineWidth: 1.5))
            } else {
                PresetCard {
                    Label("Making a video", systemImage: "film")
                        .font(theme.font(theme.type.caption, .bold))
                        .foregroundStyle(s.inkSoft)
                    if let p = c.string("prompt") { Text(p).font(theme.font(theme.type.body, .medium)).foregroundStyle(s.ink) }
                }
            }
            if let caption = c.string("caption") {
                Text(caption).font(theme.font(theme.type.caption, .semibold)).foregroundStyle(s.inkSoft)
            }
        }
        .task(id: src) {
            guard let src else { return }
            let url = await media?.fresh(src) ?? src
            let p = AVPlayer(url: url)
            p.isMuted = c.flag("mute") || c.flag("auto")
            if c.flag("loop") {
                looper = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                                object: p.currentItem, queue: .main) { _ in
                    Task { @MainActor in p.seek(to: .zero); p.play() }
                }
            }
            player = p
            if c.flag("auto") { p.play() }
        }
        .onDisappear { player?.pause() }
    }
}

/// `camera [prompt] [front|back]`: one photo, uploaded, sent as `{photo: path}`.
struct CameraPreset: View {
    let c: YLComponent
    @State private var shooting = false
    @State private var picking: PhotosPickerItem?
    @State private var preview: UIImage?
    @State private var state: Phase = .idle
    @Environment(\.yuiMedia) private var media
    @Environment(\.ylEmit) private var emit
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    enum Phase: Equatable { case idle, sending, sent, failed(String) }

    private var hasCamera: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    var body: some View {
        let s = theme.swatch(scheme)
        PresetCard {
            PresetTitle(text: c.string("prompt") ?? "Take a photo")
            if let preview {
                Image(uiImage: preview)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity).frame(height: 220)
                    .clipShape(.rect(cornerRadius: theme.radius.bubble))
            }
            switch state {
            case .sending:
                Label("Sending your photo", systemImage: "arrow.up.circle")
                    .font(theme.font(theme.type.caption, .bold)).foregroundStyle(s.inkSoft)
            case .sent:
                Label("Photo sent", systemImage: "checkmark.circle.fill")
                    .font(theme.font(theme.type.caption, .bold)).foregroundStyle(s.inkSoft)
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .font(theme.font(theme.type.caption, .bold)).foregroundStyle(s.accent)
            case .idle:
                EmptyView()
            }
            HStack(spacing: theme.spacing.s) {
                if hasCamera {
                    OptionPill(text: preview == nil ? "Open camera" : "Retake", fill: s.accent, ink: s.onAccent,
                               on: state != .sending, grow: true) { shooting = true }
                }
                PhotosPicker(selection: $picking, matching: .images) {
                    Label(hasCamera ? "Library" : "Choose a photo", systemImage: "photo.on.rectangle")
                        .font(theme.font(theme.type.body, .bold))
                        .foregroundStyle(hasCamera ? s.userInk : s.onAccent)
                        .padding(.horizontal, theme.spacing.l)
                        .padding(.vertical, theme.spacing.m)
                        .frame(maxWidth: hasCamera ? nil : .infinity)
                        .background(hasCamera ? s.lavender : s.accent, in: Capsule())
                }
                .disabled(state == .sending)
            }
        }
        .fullScreenCover(isPresented: $shooting) {
            CameraCapture(front: c.string("facing") == "front" || c.flag("front")) { data in
                shooting = false
                if let data { Task { await send(data) } }
            }
            .ignoresSafeArea()
        }
        .onChange(of: picking) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { await send(data) }
                picking = nil
            }
        }
    }

    private func send(_ data: Data) async {
        preview = UIImage(data: data)
        guard let media else { state = .failed("Photos need a signed-in account"); return }
        state = .sending
        do {
            let path = try await media.upload(photo: data)
            state = .sent
            emit(c.event(["photo": .string(path)], echo: "Photo"))
        } catch {
            state = .failed("Couldn't send it. Try again.")
        }
    }
}

/// The system camera, one shot. Returns the photo's bytes, or nil on cancel.
private struct CameraCapture: UIViewControllerRepresentable {
    let front: Bool
    let done: (Data?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.cameraDevice = front ? .front : .rear
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (Data?) -> Void
        init(done: @escaping (Data?) -> Void) { self.done = done }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done((info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.9))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}
