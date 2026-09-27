import SwiftUI

// The bottom bar (YUI-121, STAGE-1 phase 1). Chris, Sep 26: "In the bottom right I
// can just see the microphone that's slightly bigger and then the text T next to
// that and then when I hit the T, a full text input field appears, and when I push
// the plus it does whatever the plus does." One bar, the same over the full-screen
// stage and over the chat record: + and T at 40 (48 to touch), the mic at 58.

/// What the bar's buttons do. The mic has a tap (talk, hands-free) and a hold
/// (talk while held, let go sends, slide left to the trash).
struct BarActions {
    var type: () -> Void
    var photos: () -> Void
    var camera: (() -> Void)?
    var files: () -> Void
    /// Finger down on the mic, then its slide (points, negative is left), then up.
    var micDown: () -> Void
    var micDrag: (CGFloat) -> Void
    var micUp: () -> Void
    /// VoiceOver's activate: the tap, with no hold.
    var micTap: () -> Void
}

/// + T and the mic, bottom right. While the mic is on only the mic shows.
struct BarButtons: View {
    /// "stage" or "record": the buttons' ids are `<prefix>-mic`, `-type`, `-attach`.
    let prefix: String
    let showMic: Bool
    let showType: Bool
    let showAttach: Bool
    /// Listening or hands-free: + and T step aside.
    let micOn: Bool
    /// The mic hears words right now.
    let micLive: Bool
    /// Held and slid to the trash: let go throws the words away.
    let armed: Bool
    let attachDisabled: Bool
    let reduceMotion: Bool
    let actions: BarActions
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @GestureState private var press: CGFloat?

    /// The sizes Chris picked on the mock (a notch under its first cut): mic 58,
    /// T and + 40 with a 48 point touch, 8 apart.
    static let micSize: CGFloat = 58
    static let small: CGFloat = 40
    static let touch: CGFloat = 48

    var body: some View {
        let c = theme.swatch(scheme)
        HStack(spacing: 8) {
            if showAttach, !micOn { attach(c).transition(pop) }
            if showType || !showMic, !micOn { type(c).transition(pop) }
            if showMic { mic(c) }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : theme.spring, value: micOn)
    }

    private var pop: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.4, anchor: .trailing).combined(with: .opacity)
    }

    private func type(_ c: Swatch) -> some View {
        Button(action: actions.type) {
            Text("T")
                .font(.system(size: 18, weight: .bold, design: .serif))
                .foregroundStyle(c.ink)
                .frame(width: Self.small, height: Self.small)
                .background(c.surface, in: Circle())
                .overlay(Circle().stroke(c.outline, lineWidth: 1.5))
                .frame(width: Self.touch, height: Self.touch)
                .contentShape(Circle())
        }
        .buttonStyle(BounceButtonStyle())
        .accessibilityLabel("Type")
        .accessibilityIdentifier("\(prefix)-type")
    }

    private func attach(_ c: Swatch) -> some View {
        AttachMenu(actions: actions) {
            Image(systemName: "plus")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(c.ink)
                .frame(width: Self.small, height: Self.small)
                .background(c.surface, in: Circle())
                .overlay(Circle().stroke(c.outline, lineWidth: 1.5))
                .frame(width: Self.touch, height: Self.touch)
                .contentShape(Circle())
        }
        .disabled(attachDisabled)
        .accessibilityLabel("Attach")
        .accessibilityIdentifier("\(prefix)-attach")
    }

    /// A tap talks hands-free; a hold talks until the finger lets go. The drag runs in
    /// global space so the finger sliding off the circle still counts.
    private func mic(_ c: Swatch) -> some View {
        Image(systemName: armed ? "trash.fill" : micOn ? "waveform" : "mic.fill")
            .font(.system(size: Self.micSize * 0.42 * 0.8, weight: .bold))
            .foregroundStyle(c.onAccent)
            .symbolEffect(.variableColor.iterative, isActive: micLive && !armed && !reduceMotion)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: Self.micSize, height: Self.micSize)
            .background(armed ? c.inkSoft : c.accent, in: Circle())
            .shadow(color: c.accent.opacity(armed ? 0 : 0.45), radius: 9, y: 6)
            .scaleEffect(press != nil && !reduceMotion ? 0.94 : micLive && !reduceMotion ? 1.08 : 1)
            .animation(reduceMotion ? nil : theme.spring, value: press != nil)
            .animation(reduceMotion ? nil : theme.spring, value: micLive)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .updating($press) { v, state, _ in state = v.translation.width })
            .onChange(of: press) { old, new in
                if old == nil, new != nil { actions.micDown() }
                if let x = new { actions.micDrag(min(0, x)) }
                if old != nil, new == nil { actions.micUp() }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: micLive) { _, now in now }
            .sensoryFeedback(.impact(weight: .medium), trigger: armed)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(micOn ? "Stop talking" : "Talk")
            .accessibilityHint(micOn ? "" : "Tap to talk. Hold to talk until you let go.")
            .accessibilityAction { actions.micTap() }
            .accessibilityIdentifier("\(prefix)-mic")
    }
}

/// The + menu: photos, the camera, files. Every picked picture joins the message.
struct AttachMenu<Label: View>: View {
    let actions: BarActions
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            Button(action: actions.photos) { SwiftUI.Label("Photo library", systemImage: "photo.on.rectangle") }
            if let camera = actions.camera { Button(action: camera) { SwiftUI.Label("Camera", systemImage: "camera") } }
            Button(action: actions.files) { SwiftUI.Label("Files", systemImage: "folder") }
        } label: {
            label()
        }
    }
}
