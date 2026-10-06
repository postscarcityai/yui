import SwiftUI
import YuiLines

// A `sketch frame=phone` is an animated wireframe (YUI-267, direction B, picked Oct 6;
// TestFlight feedback t_f638d603, build 96: "you should totally be able to animate that.
// How can we re-create kind of wireframes of these UI?").
//
// One phone, not two outlines: a glass bezel, a recessed screen a shade off the page, a
// status bar and a home indicator, so it reads as a device. With an `after` line the same
// phone plays the before (struck rows, an xmark badge) into the after (lit rows, a check
// badge) and loops; the numbered notes under it are the current side's. No `after`: one
// still phone, its rows tracing on. Reduce Motion holds the after.
//
// Debug only: `-yuiSketchLookBPin <n>` holds side n (0 before, 1 after) for a still.

struct SketchPhone: View {
    let before: [YLComponent]
    /// The rows below the `after` line. Nil is a sketch with no `after`.
    let after: [YLComponent]?
    let beforeLabel: String
    let afterLabel: String
    let numbers: [Int: Int]
    /// The page, or the chat card, has arrived.
    let on: Bool
    /// 0 is the before, 1 the after.
    @State private var index = 0
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let width: CGFloat = 248
    private static let hold = 2.6
    /// The screen's least height, so a three row sketch is still a phone and not a wide pill.
    private static let screen: CGFloat = 190

    private var showingAfter: Bool { after != nil && index == 1 }
    private var rows: [YLComponent] { showingAfter ? after ?? [] : before }
    private var label: String { showingAfter ? afterLabel : beforeLabel }

    var body: some View {
        let s = theme.swatch(scheme)
        VStack(spacing: theme.spacing.m) {
            if after != nil { badge(s) }
            phone(s)
            key(s)
        }
        .frame(maxWidth: .infinity)
        .task(id: on) {
            guard on, after != nil else { return }
            if let pin = Self.pin { index = min(max(pin, 0), 1); return }
            guard !reduceMotion else { index = 1; return }
            while !Task.isCancelled {
                for i in 0...1 {
                    withAnimation(theme.spring) { index = i }
                    try? await Task.sleep(for: .seconds(Self.hold))
                    if Task.isCancelled { return }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sketch-phone")
    }

    /// Which half of the story the phone is on, readable without the words.
    private func badge(_ s: Swatch) -> some View {
        let good = ChartPalette.good(scheme), bad = ChartPalette.bad(scheme)
        let color = showingAfter ? good : bad
        return HStack(spacing: 6) {
            Image(systemName: showingAfter ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(theme.font(theme.type.caption, .black))
            Text(label.uppercased())
                .font(theme.font(theme.type.caption - 1, .black))
                .tracking(0.9)
                .contentTransition(.opacity)
        }
        .foregroundStyle(color)
        .padding(.horizontal, theme.spacing.m)
        .padding(.vertical, theme.spacing.s - 2)
        .glassEffect(.regular, in: .capsule)
        .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: index)
        .accessibilityIdentifier("sketch-label")
        .opacity(on ? 1 : 0)
    }

    private func phone(_ s: Swatch) -> some View {
        VStack(spacing: 0) {
            statusBar(s)
            // Both sides are laid out, one lit, so the phone never changes height mid-loop.
            ZStack(alignment: .top) {
                side(0, before, s)
                if let after { side(1, after, s) }
            }
            .padding(.horizontal, theme.spacing.m)
            .padding(.top, theme.spacing.s)
            .padding(.bottom, theme.spacing.m)
            .frame(maxWidth: .infinity, minHeight: Self.screen, alignment: .top)
            Capsule().fill(s.inkSoft.opacity(0.55))
                .frame(width: 92, height: 4)
                .frame(height: 18)
        }
        .frame(width: Self.width)
        .background(s.surface)
        .clipShape(.rect(cornerRadius: 38))
        .padding(5)
        .glassEffect(.regular, in: .rect(cornerRadius: 43))
        .overlay(RoundedRectangle(cornerRadius: 43).stroke(s.outline.opacity(0.8), lineWidth: 1))
        .opacity(on ? 1 : 0)
        .scaleEffect(on || reduceMotion ? 1 : 0.96)
        .animation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.18), value: on)
    }

    private func side(_ i: Int, _ list: [YLComponent], _ s: Swatch) -> some View {
        let lit = index == i || after == nil
        return VStack(alignment: .leading, spacing: theme.spacing.s) {
            ForEach(Array(list.enumerated()), id: \.element.serial) { n, r in
                SketchRow(r: r, i: n, frame: "phone", number: numbers[r.serial], faded: i == 0 && after != nil,
                          on: on && lit, step: n)
            }
            if list.isEmpty { Color.clear.frame(height: 28) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(lit ? 1 : 0)
        .offset(y: lit || reduceMotion ? 0 : 6)
        .animation(reduceMotion ? nil : theme.spring, value: index)
    }

    private func statusBar(_ s: Swatch) -> some View {
        ZStack {
            Capsule().fill(s.inkSoft.opacity(0.35)).frame(width: 52, height: 11)
            HStack(spacing: 4) {
                Text("9:41").font(theme.font(theme.type.caption - 2, .heavy)).foregroundStyle(s.ink)
                Spacer(minLength: 0)
                ForEach(0..<3, id: \.self) { i in
                    Capsule().fill(s.inkSoft).frame(width: 3, height: 4 + CGFloat(i) * 2)
                }
                Capsule().stroke(s.inkSoft, lineWidth: 1).frame(width: 16, height: 8).padding(.leading, 3)
            }
            .padding(.horizontal, 18)
        }
        .frame(height: 28)
        .accessibilityHidden(true)
    }

    /// The numbered notes of the side on show, under the phone, as on a drawing.
    private func key(_ s: Swatch) -> some View {
        let bad = ChartPalette.bad(scheme)
        let noted = rows.filter { numbers[$0.serial] != nil }
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(noted, id: \.serial) { r in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Blueprint.Number(n: numbers[r.serial] ?? 0, color: r.flag("x") ? bad : s.accent, ink: s.background)
                    Text(r.string("note") ?? "")
                        .font(theme.font(theme.type.caption, .semibold))
                        .foregroundStyle(s.ink.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: Self.width + 10, alignment: .leading)
        .animation(reduceMotion ? nil : theme.spring, value: index)
        .opacity(on ? 1 : 0)
        .accessibilityHidden(true)
    }

    /// `-yuiSketchLookBPin <n>`: hold side n so a still is the same every run.
    private static var pin: Int? {
        #if DEBUG
        let d = UserDefaults.standard
        guard d.object(forKey: "yuiSketchLookBPin") != nil else { return nil }
        return d.integer(forKey: "yuiSketchLookBPin")
        #else
        nil
        #endif
    }
}
