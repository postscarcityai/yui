import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

// The timer preset on the lock screen and in the Dynamic Island (YUI-30).
// Wears the agent's look from the attributes; counts between app updates with
// Text(timerInterval:), so each phase ticks down with no background work.

struct TimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TimerActivityAttributes.self) { ctx in
            LockScreenTimer(a: ctx.attributes, s: ctx.state)
                // Painted here too: iOS 26 restyles a light tint on the lock screen.
                .background(Color(hex: ctx.attributes.palette.background))
                .activityBackgroundTint(Color(hex: ctx.attributes.palette.background))
                .activitySystemActionForegroundColor(Color(hex: ctx.attributes.palette.ink))
        } dynamicIsland: { ctx in
            let a = ctx.attributes, s = ctx.state
            let look = Look(a, s)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.rounds > 1 && !a.up && s.phase != .done ? "\(a.label) · \(s.round)/\(a.rounds)" : a.label)
                            .font(look.font(13, .heavy))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                        PhaseTag(a: a, s: s, look: look, left: false)
                    }
                    .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Clock(a: a, s: s, look: look, size: 34)
                        .foregroundStyle(look.tint)
                        .frame(maxWidth: 120, alignment: .trailing)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        PhaseBar(s: s, look: look)
                        Controls(a: a, s: s, look: look, onDark: true)
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                Ring(s: s, look: look)
                    .frame(width: 18, height: 18)
            } compactTrailing: {
                Clock(a: a, s: s, look: look, size: 14)
                    .foregroundStyle(look.tint)
                    .frame(maxWidth: 52)
            } minimal: {
                Ring(s: s, look: look)
                    .frame(width: 18, height: 18)
            }
            .keylineTint(look.tint)
        }
    }
}

/// Colors and type for one timer, resolved from the agent's palette.
struct Look {
    let accent, rest, ink, inkSoft, surface, outline, onAccent, butter: Color
    let tint: Color
    let design: Font.Design

    init(_ a: TimerActivityAttributes, _ s: TimerActivityAttributes.ContentState) {
        let p = a.palette
        accent = Color(hex: p.accent); rest = Color(hex: p.mint); ink = Color(hex: p.ink)
        inkSoft = Color(hex: p.inkSoft); surface = Color(hex: p.surface); outline = Color(hex: p.outline)
        onAccent = Color(hex: p.onAccent); butter = Color(hex: p.butter)
        tint = s.phase == .rest ? rest : accent
        design = switch a.design {
        case "serif": .serif
        case "monospaced": .monospaced
        case "default": .default
        default: .rounded
        }
    }

    func font(_ size: Double, _ weight: Font.Weight) -> Font { .system(size: size, weight: weight, design: design) }
}

private struct LockScreenTimer: View {
    let a: TimerActivityAttributes
    let s: TimerActivityAttributes.ContentState

    var body: some View {
        let look = Look(a, s)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(a.label)
                            .font(look.font(15, .heavy))
                            .foregroundStyle(look.inkSoft)
                            .lineLimit(1)
                        if !a.up, a.rounds > 1, s.phase != .done {
                            Text("Round \(s.round)/\(a.rounds)")
                                .font(look.font(12, .heavy).monospacedDigit())
                                .foregroundStyle(Color(hex: a.palette.userInk))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(look.butter, in: Capsule())
                        }
                    }
                    Clock(a: a, s: s, look: look, size: 44, align: .leading)
                        .foregroundStyle(look.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    PhaseTag(a: a, s: s, look: look)
                }
                Spacer(minLength: 0)
                Controls(a: a, s: s, look: look, onDark: false)
            }
            PhaseBar(s: s, look: look)
        }
        .padding(16)
    }
}

/// "WORK", "REST", "DONE!", with the time left in the whole workout.
private struct PhaseTag: View {
    let a: TimerActivityAttributes
    let s: TimerActivityAttributes.ContentState
    let look: Look
    /// The whole workout's time left (the island is too narrow for it).
    var left = true

    var body: some View {
        HStack(spacing: 6) {
            Text(s.running || s.phase == .done || s.phase == .up ? s.label : "\(s.label) · paused")
                .font(look.font(12, .heavy))
                .textCase(.uppercase)
                .foregroundStyle(s.phase == .done ? look.ink : look.tint)
            if left, !a.up, a.rounds > 1, s.phase == .work || s.phase == .rest, s.running {
                Text("·").foregroundStyle(look.inkSoft)
                (Text(timerInterval: Date.now...max(Date.now, s.finish), countsDown: true) + Text(" left"))
                    .font(look.font(12, .bold).monospacedDigit())
                    .foregroundStyle(look.inkSoft)
            }
        }
        .lineLimit(1)
    }
}

/// The phase clock: counts on its own while running, still while paused.
private struct Clock: View {
    let a: TimerActivityAttributes
    let s: TimerActivityAttributes.ContentState
    let look: Look
    let size: Double
    var align: TextAlignment = .trailing

    var body: some View {
        Group {
            if s.phase == .done {
                Text("Done!")
            } else if s.running {
                Text(timerInterval: s.start...s.end, countsDown: s.phase != .up)
            } else {
                Text(TimerActivityAttributes.clock(s.shown, up: s.phase == .up))
            }
        }
        .font(look.font(size, .heavy).monospacedDigit())
        .multilineTextAlignment(align)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// How far into this phase.
private struct PhaseBar: View {
    let s: TimerActivityAttributes.ContentState
    let look: Look

    var body: some View {
        Group {
            if s.running, s.phase == .work || s.phase == .rest {
                ProgressView(timerInterval: s.start...s.end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
            } else {
                ProgressView(value: s.phase == .up ? 0 : s.progress)
            }
        }
        .progressViewStyle(.linear)
        .tint(look.tint)
    }
}

private struct Ring: View {
    let s: TimerActivityAttributes.ContentState
    let look: Look

    var body: some View {
        Group {
            if s.running, s.phase == .work || s.phase == .rest {
                ProgressView(timerInterval: s.start...s.end, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
            } else if s.phase == .done {
                ProgressView(value: 1)
            } else {
                ProgressView(value: s.phase == .up ? 1 : 1 - s.progress)
            }
        }
        .progressViewStyle(.circular)
        .tint(look.tint)
    }
}

/// Pause/Resume and End. They run in the app (LiveActivityIntent).
private struct Controls: View {
    let a: TimerActivityAttributes
    let s: TimerActivityAttributes.ContentState
    let look: Look
    let onDark: Bool

    var body: some View {
        if s.phase != .done {
            HStack(spacing: 8) {
                Button(intent: TimerToggleIntent(id: a.id)) {
                    Image(systemName: s.running ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(s.running ? Color(hex: a.palette.userInk) : look.onAccent)
                        .frame(width: 46, height: 46)
                        .background(s.running ? Color(hex: a.palette.lavender) : look.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(s.running ? "Pause" : "Resume")
                Button(intent: TimerEndIntent(id: a.id)) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(onDark ? .white : look.ink)
                        .frame(width: 36, height: 36)
                        .background(onDark ? Color.white.opacity(0.18) : look.surface, in: Circle())
                        .overlay(Circle().stroke(onDark ? .clear : look.outline, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("End timer")
            }
        }
    }
}
