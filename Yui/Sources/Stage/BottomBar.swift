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
    /// Hold to snap and say (YUI-166): nil with no camera.
    var snap: (() -> Void)? = nil
    var files: () -> Void
    /// Finger down on the mic, then its slide (points, negative is left), then up.
    var micDown: () -> Void
    var micDrag: (CGFloat) -> Void
    var micUp: () -> Void
    /// VoiceOver's activate: the tap, with no hold.
    var micTap: () -> Void
    /// Set while the agent works (YUI-190): the mic is a stop square and a tap stops it.
    var stop: (() -> Void)? = nil
    /// How far up the finger is on the mic (points, 0 or more): the lock is above it.
    var micLift: (CGFloat) -> Void = { _ in }
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
    /// Held to talk: the lock waits just above the mic.
    var held = false
    /// Held and slid up onto the lock: let go keeps it recording, hands-free.
    var lockArmed = false
    let attachDisabled: Bool
    let reduceMotion: Bool
    let actions: BarActions
    /// The agent's motion look (YUI-120): the mic's ring beats in its pulse while it listens.
    var look: MotionLook? = nil
    /// Changes each time the mic hears more words: the ring beats with the voice.
    var voice = 0
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @GestureState private var press: CGSize?
    /// Counts Stop taps: each one is a firm tap under the thumb.
    @State private var stops = 0

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
            // Chris on TestFlight (YUI-190): "Find the best place to put a cancel button... I'm
            // leaning towards the main screen." The mic's own spot, always under the thumb.
            if let stop = actions.stop { stopButton(c, stop).transition(swap) }
            else if showMic { mic(c).transition(swap) }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : theme.spring, value: micOn)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : theme.spring, value: actions.stop != nil)
    }

    /// The mic and the stop square trade places where they stand.
    private var swap: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.7).combined(with: .opacity)
    }

    private var pop: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.4, anchor: .trailing).combined(with: .opacity)
    }

    private func type(_ c: Swatch) -> some View {
        Button(action: actions.type) {
            Text("T")
                .font(theme.font(18, .bold))
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

    /// Stop (YUI-190): the mic's size and color, a square in it. One tap ends the agent's turn;
    /// the mic comes back at once, so the next thing can be said right away.
    private func stopButton(_ c: Swatch, _ stop: @escaping () -> Void) -> some View {
        Button {
            stops += 1
            stop()
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: Self.micSize * 0.3, weight: .bold))
                .foregroundStyle(c.onAccent)
                .frame(width: Self.micSize, height: Self.micSize)
                .background(c.accent, in: Circle())
                .shadow(color: c.accent.opacity(0.45), radius: 9, y: 6)
                .contentShape(Circle())
        }
        .buttonStyle(BounceButtonStyle())
        .sensoryFeedback(.impact(weight: .medium), trigger: stops)
        .accessibilityLabel("Stop")
        .accessibilityHint("Stops the agent's answer.")
        .accessibilityIdentifier("\(prefix)-stop")
    }

    private func lock(_ c: Swatch) -> some View {
        VStack(spacing: 4) {
            Image(systemName: lockArmed ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(lockArmed ? c.onAccent : c.ink)
                .frame(width: Self.small, height: Self.small)
                .background(lockArmed ? c.accent : c.surface, in: Circle())
                .overlay(Circle().stroke(lockArmed ? .clear : c.outline, lineWidth: 1.5))
                .scaleEffect(lockArmed && !reduceMotion ? 1.2 : 1)
                .animation(reduceMotion ? nil : theme.spring, value: lockArmed)
            Image(systemName: "chevron.up")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(c.inkSoft)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
        .accessibilityElement()
        .accessibilityLabel(lockArmed ? "Locked. Let go to keep recording" : "Slide up to keep recording")
        .accessibilityIdentifier(lockArmed ? "\(prefix)-lock-armed" : "\(prefix)-lock")
    }

    /// How far left the finger goes to arm the trash (the same 110 the chat mic uses).
    static let trashReach: CGFloat = 110

    private func trash(_ c: Swatch) -> some View {
        Image(systemName: armed ? "trash.fill" : "trash")
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(armed ? c.onAccent : c.ink)
            .frame(width: Self.small, height: Self.small)
            .background(armed ? c.accent : c.surface, in: Circle())
            .overlay(Circle().stroke(armed ? .clear : c.outline, lineWidth: 1.5))
            .scaleEffect(armed && !reduceMotion ? 1.2 : 1)
            .animation(reduceMotion ? nil : theme.spring, value: armed)
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityElement()
            .accessibilityLabel(armed ? "Let go to cancel" : "Slide left to cancel")
            .accessibilityIdentifier(armed ? "\(prefix)-trash-armed" : "\(prefix)-trash")
    }

    /// A tap talks hands-free; a hold talks until the finger lets go. The drag runs in
    /// global space so the finger sliding off the circle still counts.
    private func mic(_ c: Swatch) -> some View {
        Image(systemName: micOn ? "waveform" : "mic.fill")
            .font(.system(size: Self.micSize * 0.42 * 0.8, weight: .bold))
            .foregroundStyle(c.onAccent)
            .symbolEffect(.variableColor.iterative, isActive: micLive && !reduceMotion)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: Self.micSize, height: Self.micSize)
            .background {
                if let look, micLive, !look.reduced { MicRing(color: c.accent, look: look, voice: voice) }
            }
            .background(c.accent, in: Circle())
            .shadow(color: c.accent.opacity(0.45), radius: 9, y: 6)
            .scaleEffect(press != nil && !reduceMotion ? 0.94 : micLive && !reduceMotion ? 1.08 : 1)
            .animation(reduceMotion ? nil : theme.spring, value: press != nil)
            .animation(reduceMotion ? nil : theme.spring, value: micLive)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .updating($press) { v, state, _ in state = v.translation })
            .onChange(of: press) { old, new in
                if old == nil, new != nil { actions.micDown() }
                if let t = new { actions.micDrag(min(0, t.width)); actions.micLift(max(0, -t.height)) }
                if old != nil, new == nil { actions.micUp() }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: micLive) { _, now in now }
            .sensoryFeedback(.impact(weight: .medium), trigger: armed)
            .sensoryFeedback(.impact(weight: .medium), trigger: lockArmed)
            // The lock: a spot just above the mic. Slide up onto it and let go to keep recording.
            .overlay(alignment: .top) { if held, !armed { lock(c).offset(y: -(Self.micSize + 26)) } }
            // The trash: its own target to the left, like the lock. The mic stays a mic.
            // Let go over it cancels; let go anywhere else does not.
            .overlay(alignment: .leading) { if held { trash(c).offset(x: -Self.trashReach - Self.small / 2) } }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(micOn ? "Stop talking" : "Talk")
            .accessibilityHint(micOn ? "" : "Tap to talk. Hold to talk until you let go.")
            .accessibilityAction { actions.micTap() }
            .accessibilityIdentifier("\(prefix)-mic")
    }
}

/// The mic's ring while it listens (YUI-120, Stage motion): it breathes in the look's pulse
/// and beats once more each time the mic hears words.
private struct MicRing: View {
    let color: Color
    let look: MotionLook
    let voice: Int

    var body: some View {
        let t = look.timings
        let period = t.breath > 0 ? t.breath : 2.4
        ZStack {
            TimelineView(.animation(minimumInterval: nil, paused: look.pulse == .still)) { ctx in
                let x = (ctx.date.timeIntervalSinceReferenceDate / period).truncatingRemainder(dividingBy: 1)
                Circle()
                    .stroke(color.opacity(0.45 * (1 - x)), lineWidth: 3)
                    .scaleEffect(look.pulse == .still ? 1 : 1 + 0.45 * x)
            }
            Circle()
                .fill(color.opacity(0.35))
                .keyframeAnimator(initialValue: 0.0, trigger: voice) { v, x in
                    v.scaleEffect(1 + 0.3 * x).opacity(x)
                } keyframes: { _ in
                    KeyframeTrack {
                        CubicKeyframe(1, duration: max(0.08, t.beat * 0.25))
                        CubicKeyframe(0, duration: max(0.15, t.beat * 0.6))
                    }
                }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The + menu: photos, the camera, files. Every picked picture joins the message.
struct AttachMenu<Label: View>: View {
    let actions: BarActions
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            if let snap = actions.snap { Button(action: snap) { SwiftUI.Label("Snap and say", systemImage: "camera.viewfinder") } }
            Button(action: actions.photos) { SwiftUI.Label("Photo library", systemImage: "photo.on.rectangle") }
            if let camera = actions.camera { Button(action: camera) { SwiftUI.Label("Camera", systemImage: "camera") } }
            Button(action: actions.files) { SwiftUI.Label("Files", systemImage: "folder") }
        } label: {
            label()
        }
    }
}
