import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// A group talks like a one-on-one chat (voice first, t_76b0a0cf). Chris, TestFlight: never make
// people type. The group's bar is the agent chat's bar: + T and the mic, mic biggest, bottom right.
// The mic sends what was said to the group; T brings up the field; + attaches. The buttons are the
// chat's own BarButtons and the mic is the chat's PushToTalk, no second one.

/// The bar under a group thread: + T mic, or the typing field once T is tapped.
struct GroupBar: View {
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    let thread: GroupThread
    let members: [YuiAgent]
    let account: Account
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var typing = false
    @State private var talk = PushToTalk()
    @State private var micHeld = false
    @State private var micTapOnly = false
    @State private var micDragX: CGFloat = 0
    @State private var holdStart: Task<Void, Never>?
    @State private var micStarting = false
    @State private var photos: [ComposerPhoto] = []
    @State private var picked: [PhotosPickerItem] = []
    @State private var pickingPhotos = false
    @State private var importingFiles = false
    @State private var shooting = false
    @State private var uploading = false

    private var cancelArmed: Bool { micDragX < -BarButtons.trashReach(width: 390, inset: theme.spacing.l) }
    private var hasWords: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        let c = theme.swatch(scheme)
        VStack(spacing: theme.spacing.xs) {
            if !photos.isEmpty { strip(c) }
            HStack(alignment: .bottom, spacing: theme.spacing.s) {
                if talk.listening {
                    listening(c)
                } else if typing || !photos.isEmpty {
                    field(c)
                    send(c)
                } else {
                    Spacer(minLength: 0)
                }
                if !typing && photos.isEmpty || talk.listening {
                    BarButtons(prefix: "group", showMic: true, showType: true, showAttach: true,
                               micOn: talk.listening, micLive: talk.listening, armed: cancelArmed,
                               held: micHeld && talk.listening, attachDisabled: uploading || photos.count >= Attachments.maxPhotos,
                               reduceMotion: reduceMotion, actions: actions)
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : theme.spring, value: typing)
        }
        .padding(.horizontal, theme.spacing.l)
        .onChange(of: thread.replyTarget) { _, who in if who != nil { typeHere() } }
        .onChange(of: focused.wrappedValue) { was, now in if was, !now, photos.isEmpty, !pickingPhotos, !shooting, !importingFiles { typing = false } }
        .onDisappear { talk.cancel() }
        .photosPicker(isPresented: $pickingPhotos, selection: $picked,
                      maxSelectionCount: max(Attachments.maxPhotos - photos.count, 1), matching: .images)
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task {
                for item in items {
                    guard let d = try? await item.loadTransferable(type: Data.self), photos.count < Attachments.maxPhotos else { continue }
                    if let p = await Task.detached(priority: .userInitiated, operation: { ComposerPhoto(d) }).value { photos.append(p) }
                }
            }
        }
        .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            add(urls.compactMap { url in
                let open = url.startAccessingSecurityScopedResource()
                defer { if open { url.stopAccessingSecurityScopedResource() } }
                return try? Data(contentsOf: url)
            })
        }
        .fullScreenCover(isPresented: $shooting) {
            CameraCapture(front: false) { data in
                shooting = false
                if let data { add([data]) }
            }
            .ignoresSafeArea()
        }
        #if DEBUG
        .task {
            talk.fakeWords = UserDefaults.standard.string(forKey: "yuiPTTFake")
            if let words = UserDefaults.standard.string(forKey: "yuiPTTDemo") { talk.demo(words) }
        }
        #endif
    }

    // MARK: Pieces

    private func field(_ c: Swatch) -> some View {
        TextField(photos.isEmpty ? "Message the group" : "Add a caption", text: $draft, axis: .vertical)
            .lineLimit(1...5)
            .focused(focused)
            .accessibilityIdentifier("group-field")
            .padding(.horizontal, theme.spacing.l).padding(.vertical, theme.spacing.m)
            .background(c.surface, in: RoundedRectangle(cornerRadius: theme.radius.bubble))
            .overlay(RoundedRectangle(cornerRadius: theme.radius.bubble).stroke(c.outline, lineWidth: 1))
    }

    private func send(_ c: Swatch) -> some View {
        Button(action: sendTyped) {
            Image(systemName: uploading ? "ellipsis.circle.fill" : "arrow.up.circle.fill").font(.system(size: 34)).foregroundStyle(c.accent)
        }
        .disabled(!(hasWords || !photos.isEmpty) || uploading)
        .accessibilityLabel("Send").accessibilityIdentifier("group-send")
    }

    /// While it listens: what it hears, live, with the trash on the left when slid to it.
    private func listening(_ c: Swatch) -> some View {
        HStack(spacing: theme.spacing.s) {
            if micHeld { BarTrash(prefix: "group", armed: cancelArmed, reduceMotion: reduceMotion) }
            Text(talk.transcript.isEmpty ? "Listening" : talk.transcript)
                .font(theme.font(theme.type.body)).foregroundStyle(c.ink).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, theme.spacing.l).padding(.vertical, theme.spacing.m)
                .background(c.surface, in: RoundedRectangle(cornerRadius: theme.radius.bubble))
                .overlay(RoundedRectangle(cornerRadius: theme.radius.bubble).stroke(cancelArmed ? c.inkSoft : c.accent, lineWidth: 2))
                .accessibilityIdentifier("group-listening")
        }
    }

    private func strip(_ c: Swatch) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: theme.spacing.s) {
                ForEach(photos) { p in
                    Image(uiImage: p.preview).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 64, height: 64).clipShape(.rect(cornerRadius: theme.radius.bubbleTail + 6))
                        .overlay(alignment: .topTrailing) {
                            Button { photos.removeAll { $0.id == p.id } } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 20, weight: .bold))
                                    .symbolRenderingMode(.palette).foregroundStyle(c.onAccent, c.ink.opacity(0.7))
                            }
                            .padding(3).disabled(uploading).accessibilityLabel("Remove photo")
                        }
                        .accessibilityIdentifier("group-attachment")
                }
            }
        }
    }

    // MARK: Actions

    private var actions: BarActions {
        BarActions(
            type: typeHere,
            photos: { pickingPhotos = true },
            camera: UIImagePickerController.isSourceTypeAvailable(.camera) ? { shooting = true } : nil,
            files: { importingFiles = true },
            micDown: { if talk.listening { micTapOnly = true } else { micDown() } },
            micDrag: { x in if !micTapOnly { micDragX = x } },
            micUp: {
                if micTapOnly { micTapOnly = false; micDragX = 0; talkTap(); return }
                micUp()
            },
            micTap: talkTap,
            micLift: { _ in })
    }

    private func typeHere() {
        typing = true
        DispatchQueue.main.async { focused.wrappedValue = true }
    }

    private func add(_ datas: [Data]) {
        for d in datas where photos.count < Attachments.maxPhotos {
            if let p = ComposerPhoto(d) { photos.append(p) }
        }
    }

    /// Finger on the mic: after a short hold it listens; a quick tap is handled on let go.
    private func micDown() {
        micHeld = true
        micDragX = 0
        holdStart?.cancel()
        holdStart = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, micHeld else { return }
            micStarting = true
            await talk.start()
            micStarting = false
            if talk.listening && !micHeld { talk.cancel() }
        }
    }

    /// Let go: a hold sends what it heard (the trash cancels); a quick tap talks, and the next tap sends.
    private func micUp() {
        micHeld = false
        let cancel = cancelArmed
        micDragX = 0
        if talk.listening {
            if cancel { talk.cancel() } else { finishTalk() }
        } else if !micStarting {
            holdStart?.cancel()
            talkTap()
        }
    }

    private func talkTap() {
        if talk.listening { finishTalk() } else { Task { await talk.start() } }
    }

    private func finishTalk() {
        Task {
            let words = await talk.stop()
            guard !words.isEmpty else { return }
            thread.send(words, members: members)
        }
    }

    private func sendTyped() {
        let words = draft
        if photos.isEmpty {
            thread.send(words, members: members)
            draft = ""
            return
        }
        uploading = true
        let sent = photos
        Task {
            defer { uploading = false }
            do {
                try await thread.send(words, photos: sent, members: members, account: account)
                photos = []
                draft = ""
            } catch {
                thread.notice = "Couldn't send the photo. Try again."
            }
        }
    }
}

/// A mic that fills a text field (renaming or creating a group, or commenting on a photo, can be
/// said, not typed). Tap and say it; tap again to stop. The words are what was heard, without a
/// closing period. `append` adds to what is already typed instead of replacing it.
struct NameMic: View {
    @Binding var text: String
    let id: String
    var label = "Say the name"
    var append = false
    /// Runs once the words are in the field (a rename saves itself, as on Return).
    var done: () -> Void = {}
    @State private var talk = PushToTalk()
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        Button {
            if talk.listening {
                Task {
                    var heard = await talk.stop()
                    while let last = heard.last, ".!?,".contains(last) { heard.removeLast() }
                    if !heard.isEmpty {
                        let had = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        text = append && !had.isEmpty ? had + " " + heard : heard
                        done()
                    }
                }
            } else {
                Task { await talk.start() }
            }
        } label: {
            Image(systemName: talk.listening ? "waveform" : "mic.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(talk.listening ? c.onAccent : c.ink)
                .symbolEffect(.variableColor.iterative, isActive: talk.listening)
                .frame(width: 36, height: 36)
                .background(talk.listening ? c.accent : c.surface, in: Circle())
                .overlay(Circle().stroke(talk.listening ? .clear : c.outline, lineWidth: 1.5))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(talk.listening ? "Stop talking" : label)
        .accessibilityIdentifier(id)
        .onDisappear { talk.cancel() }
        #if DEBUG
        .task { talk.fakeWords = UserDefaults.standard.string(forKey: "yuiPTTFake") }
        #endif
    }
}
