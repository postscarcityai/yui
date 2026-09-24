import SwiftUI
import YuiLines

// The stage (YUI-13, spec yuigui/spec/YL.md section 5): a full-screen layer
// over the chat for moments that deserve the whole phone. Workouts always go
// there. Swipe down or tap the X to close it; the chat is right underneath and
// a pill brings the stage back. A running timer keeps running either way.

extension EnvironmentValues {
    /// Timer state that outlives any one view of it (stage, pill, chat).
    @Entry var ylTimers: TimerRuns? = nil
    /// Which reply a component belongs to, so its state key is unique per thread.
    @Entry var ylScope = ""
}

/// One timer's clock. Wall-clock based, so it keeps time with no view on screen.
@Observable @MainActor
final class TimerRun {
    var banked: TimeInterval = 0
    var since: Date?
    var started = false
    var finished = false

    var running: Bool { since != nil }
    func elapsed(at now: Date = .now) -> TimeInterval { banked + (since.map { now.timeIntervalSince($0) } ?? 0) }
}

/// Every timer in the thread, by reply and component.
@Observable @MainActor
final class TimerRuns {
    private var runs: [String: TimerRun] = [:]

    func run(_ scope: String, _ c: YLComponent) -> TimerRun {
        let key = "\(scope)#\(c.serial)"
        if let r = runs[key] { return r }
        let r = TimerRun()
        runs[key] = r
        return r
    }
}

extension YLComponent {
    /// Opens on the stage for an agent with this style profile (spec section 5).
    func onStage(_ style: [String: String]) -> Bool {
        YuiLines.opensOnStage(preset: preset, screen: screen, props: props, style: style)
    }

    var timerPlan: TimerPlan {
        TimerPlan(work: number("work") ?? 60, rest: number("rest") ?? 0,
                  rounds: max(1, Int(number("rounds") ?? 1)), up: flag("up"))
    }
}

extension YLScreen {
    func staged(_ style: [String: String]) -> [YLComponent] { components.filter { $0.onStage(style) } }
}

/// The full-screen layer. Mounted as long as there is something on it, open or
/// not, so timers keep ticking and beeping while the person is in the chat.
struct StageView: View {
    let components: [YLComponent]
    let scope: String
    var agent: YuiAgent?
    let open: Bool
    let close: () -> Void
    @State private var drag: CGFloat = 0
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        GeometryReader { geo in
            let height = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
            VStack(spacing: 0) {
                header(c)
                ScrollView {
                    VStack(spacing: theme.spacing.l) {
                        ForEach(components) { PresetView(component: $0) }
                    }
                    .padding(.horizontal, theme.spacing.l)
                    .padding(.bottom, theme.spacing.xl)
                    .frame(minHeight: geo.size.height - 90, alignment: .center)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .environment(\.ylScope, scope)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(c.background.ignoresSafeArea())
            .mask { RoundedRectangle(cornerRadius: drag > 0 ? 38 : 0).ignoresSafeArea() }
            .offset(y: open ? drag : height + 40)
            .opacity(open ? 1 : 0)
            .simultaneousGesture(swipe)
            .allowsHitTesting(open)
            .accessibilityHidden(!open)
            .accessibilityAddTraits(open ? .isModal : [])
        }
    }

    private func header(_ c: Swatch) -> some View {
        ZStack {
            Capsule().fill(c.outline).frame(width: 40, height: 5)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, theme.spacing.s)
            HStack(spacing: theme.spacing.s) {
                if let agent { AgentBadge(agent: agent, size: 26) }
                Text(agent?.name ?? "Yui")
                    .font(theme.font(theme.type.body, theme.strong))
                    .foregroundStyle(c.ink)
            }
            HStack {
                Spacer()
                Button("Close full screen", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .font(theme.font(theme.type.body, .black))
                    .foregroundStyle(c.ink)
                    .frame(width: 44, height: 44)
                    .background(c.surface, in: Circle())
                    .overlay(Circle().stroke(c.outline, lineWidth: 1.5))
                    .buttonStyle(BounceButtonStyle())
            }
        }
        .frame(height: 64)
        .padding(.horizontal, theme.spacing.l)
        .contentShape(.rect)
    }

    /// Pull down past a third of the way, or flick, and it goes; less springs back.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { v in
                guard open, v.translation.height > 0, abs(v.translation.height) > abs(v.translation.width) else { return }
                drag = v.translation.height
            }
            .onEnded { v in
                guard open else { return }
                let gone = v.translation.height > 140 || v.predictedEndTranslation.height > 420
                if gone { close() }
                withAnimation(theme.spring) { drag = 0 }
            }
    }
}

/// Where staged components sit in the chat: one pill per reply, live for timers.
/// Tap it and the stage comes back.
struct StagePill: View {
    let components: [YLComponent]
    let scope: String
    let open: () -> Void
    @Environment(\.ylTimers) private var timers
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        // Named after what the stage is for (the timer), not the chatter around it.
        let first = components.first { $0.preset == "timer" } ?? components.first { YuiLines.stagePresets.contains($0.preset) }
            ?? components[0]
        Button(action: open) {
            HStack(spacing: theme.spacing.s) {
                Image(systemName: icon(first.preset))
                    .foregroundStyle(c.onAccent)
                    .frame(width: 30, height: 30)
                    .background(c.accent, in: Circle())
                Text(title(first))
                    .font(theme.font(theme.type.body, .bold))
                    .foregroundStyle(c.ink)
                    .lineLimit(1)
                if let timer = components.first(where: { $0.preset == "timer" }), let timers {
                    TimerStatus(c: timer, run: timers.run(scope, timer))
                }
                if components.count > 1 {
                    Text("+\(components.count - 1)")
                        .font(theme.font(theme.type.caption, .heavy))
                        .foregroundStyle(c.inkSoft)
                }
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(theme.font(theme.type.caption, .heavy))
                    .foregroundStyle(c.inkSoft)
            }
            .padding(.leading, theme.spacing.xs)
            .padding(.trailing, theme.spacing.m)
            .padding(.vertical, theme.spacing.xs)
            .background(c.surface, in: Capsule())
            .overlay(Capsule().stroke(c.outline, lineWidth: 1.5))
        }
        .buttonStyle(BounceButtonStyle())
        .accessibilityLabel("Open \(title(first)) full screen")
        .transition(.scale(scale: 0.85, anchor: .leading).combined(with: .opacity))
    }

    private func title(_ c: YLComponent) -> String {
        let named: String = switch c.preset {
        case "timer": c.flag("up") ? "Stopwatch" : "Timer"
        case "camera": "Camera"
        case "mic": "Voice note"
        default: c.preset.capitalized
        }
        return c.string("label") ?? c.string("title") ?? c.string("q") ?? c.string("prompt") ?? c.string("text") ?? named
    }

    private func icon(_ preset: String) -> String {
        switch preset {
        case "timer": "timer"
        case "camera": "camera.fill"
        case "mic": "mic.fill"
        case "deck": "rectangle.stack.fill"
        case "gallery": "photo.on.rectangle"
        default: "arrow.up.left.and.arrow.down.right"
        }
    }
}

/// "3:12 · 2/8" for a timer, ticking only while it runs.
private struct TimerStatus: View {
    let c: YLComponent
    let run: TimerRun
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let plan = c.timerPlan
            let st = plan.state(at: run.elapsed(at: run.running ? ctx.date : .now))
            if run.started {
                Text(st.done ? "Done" : "\(TimerPreset.clock(st.shown, up: plan.up))\(plan.rounds > 1 && !plan.up ? " · \(st.round)/\(plan.rounds)" : "")\(run.running ? "" : " · paused")")
                    .font(theme.font(theme.type.caption, .heavy).monospacedDigit())
                    .foregroundStyle(st.resting ? s.mint : s.accent)
                    .contentTransition(.numericText())
            }
        }
    }
}
