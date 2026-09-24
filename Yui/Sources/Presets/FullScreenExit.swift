import SwiftUI

// The way out of every full-screen view (TestFlight feedback, 2026-09-24: "the
// X button doesn't work, I can't get out of the screen"). The old X took taps
// on its 22pt glyph only, since the padding sat outside the button, and there
// was no other exit. Now: a 44pt X with a 60pt touch area, and a swipe down.

/// The X for a full-screen view. Runs `action`, then dismisses the
/// presentation it sits in, so a stale binding can never keep it up.
struct FullScreenCloseButton: View {
    let action: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button {
            action()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.5), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1.5))
                .frame(width: 60, height: 60)
                .contentShape(.rect)
        }
        .buttonStyle(BounceButtonStyle())
        .accessibilityLabel("Close")
    }
}

extension View {
    /// Swipe down closes a full-screen cover; the view follows the finger and
    /// springs back if the pull is short. `x: true` also pins the X top right.
    func fullScreenExit(x: Bool = true, close: @escaping () -> Void) -> some View {
        modifier(FullScreenExit(x: x, close: close))
    }
}

private struct FullScreenExit: ViewModifier {
    let x: Bool
    let close: () -> Void
    @State private var drag: CGFloat = 0
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if x { FullScreenCloseButton(action: close).padding(.trailing, 4) }
            }
            .offset(y: drag)
            .opacity(1 - min(drag / 600, 0.4))
            .simultaneousGesture(
                // Mostly down, never sideways: pages and sliders keep their swipes.
                DragGesture(minimumDistance: 24)
                    .onChanged { v in
                        guard v.translation.height > 0, v.translation.height > abs(v.translation.width) * 1.5 else { return }
                        drag = v.translation.height
                    }
                    .onEnded { v in
                        if drag > 0, v.translation.height > 120 || v.predictedEndTranslation.height > 400 {
                            close()
                            dismiss()
                        } else {
                            withAnimation(.spring(duration: 0.3)) { drag = 0 }
                        }
                    }
            )
            // A cover inherits its presenter's environment: under a locked
            // (`.disabled`) preset the X and the swipe would be dead too.
            .environment(\.isEnabled, true)
    }
}
