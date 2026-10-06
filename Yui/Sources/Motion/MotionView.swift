import SwiftUI
import WebKit

/// The film, full bleed (spec/MOTION.md 2.3). Native chrome only: pause, scrub, replay, close. Reduce
/// Motion shows the last frame still. When the watchdog fires the caller's `fallback` (the agent's shapes
/// drawing) takes the screen. `after` floats over the last frame once the film ends: a quiz or pick
/// buttons, never a card under a box.
struct MotionView<Fallback: View, After: View>: View {
    @ObservedObject var controller: MotionController
    let onClose: () -> Void
    @ViewBuilder var fallback: () -> Fallback
    @ViewBuilder var after: () -> After

    @Environment(\.accessibilityReduceMotion) private var systemReduce
    @State private var chrome = true
    @State private var hide: Task<Void, Never>?
    @State private var scrubbing = false
    @State private var scrub: Double = 0

    private var reduce: Bool { systemReduce || ProcessInfo.processInfo.arguments.contains("-yuiReduceMotion") }

    var body: some View {
        ZStack {
            Color(red: 11 / 255, green: 8 / 255, blue: 19 / 255).ignoresSafeArea()
            if controller.isFailed {
                fallback()
            } else {
                MotionWeb(web: controller.web)
                    .ignoresSafeArea()
                    .accessibilityElement()
                    .accessibilityLabel(label)
                    .accessibilityAddTraits(.isImage)
                if controller.phase == .ended { after().transition(.opacity) }
                if chrome && !reduce { controls.transition(.opacity) }
            }
        }
        .overlay(alignment: .topTrailing) { if !controller.isFailed { closeButton } }
        .fullScreenExit(x: false, close: onClose)
        .onAppear {
            controller.setStill(reduce)
            controller.onChromeTap = { poke(toggle: true) }
            poke(toggle: false)
        }
        .onChange(of: reduce) { _, on in controller.setStill(on) }
        .onDisappear { controller.stop() }
        .animation(reduce ? nil : .easeInOut(duration: 0.25), value: chrome)
        .animation(reduce ? nil : .easeInOut(duration: 0.25), value: controller.phase)
    }

    private var label: String {
        let words = controller.spoken
        return words.isEmpty ? "Film" : "Film: \(words)"
    }

    private var closeButton: some View {
        FullScreenCloseButton(action: onClose).padding(.trailing, 4).padding(.top, 4)
    }

    private func poke(toggle: Bool) {
        hide?.cancel()
        if toggle { chrome.toggle() } else { chrome = true }
        guard chrome else { return }
        hide = Task {
            try? await Task.sleep(for: .seconds(3.5))
            if !Task.isCancelled && controller.phase == .playing && !scrubbing { chrome = false }
        }
    }

    private var controls: some View {
        VStack {
            Spacer()
            HStack(spacing: 14) {
                Button {
                    if controller.phase == .ended { controller.replay() } else { controller.toggle() }
                    poke(toggle: false)
                } label: {
                    Image(systemName: controller.phase == .ended ? "arrow.counterclockwise" : (controller.phase == .paused ? "play.fill" : "pause.fill"))
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.5), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1.5))
                }
                .buttonStyle(BounceButtonStyle())
                .accessibilityLabel(controller.phase == .ended ? "Replay" : (controller.phase == .paused ? "Play" : "Pause"))
                .accessibilityIdentifier("motion.playpause")

                Slider(value: Binding(get: { scrubbing ? scrub : controller.time },
                                      set: { scrub = $0; controller.seek($0) }),
                       in: 0...max(controller.total, 0.1)) { editing in
                    scrubbing = editing
                    if editing { controller.pause() } else { controller.resume(); poke(toggle: false) }
                }
                .tint(.white)
                .accessibilityLabel("Scrub")
                .accessibilityIdentifier("motion.scrub")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 22)
        }
    }
}

extension MotionView where Fallback == EmptyView, After == EmptyView {
    init(controller: MotionController, onClose: @escaping () -> Void) {
        self.init(controller: controller, onClose: onClose, fallback: { EmptyView() }, after: { EmptyView() })
    }
}

/// The web view itself. Taps go through the harness (`api.hit` targets, else the chrome).
private struct MotionWeb: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> WKWebView { web }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
