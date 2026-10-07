import SwiftUI
import YuiLines

// `motion` in the thread (spec/MOTION.md section 0.5): a quiet tile, no card, with the film's title and
// where it is; tapping it, or the film arriving while the person is here, opens it full screen in the
// native player. The film is the agent's, written by the plugin from its one-line ask.

extension YLComponent {
    /// A later part of a film: it feeds the film and draws nothing of its own.
    var isMotionPart: Bool { preset == "motion" && (props["part"]?.number ?? 1) > 1 }
}

struct MotionPreset: View {
    let c: YLComponent
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.ylEmit) private var emit
    @Environment(\.ylFilmChange) private var filmChange
    @State private var open = false

    private var filmID: String { c.props["film"]?.string ?? c.ylID }
    private var film: MotionFilm? { MotionFilms.shared.film(filmID) }

    var body: some View {
        if c.isMotionPart {
            EmptyView()
        } else {
            let s = theme.swatch(scheme)
            let title = (film?.title).flatMap { $0.isEmpty ? nil : $0 } ?? c.props["title"]?.string ?? "A film"
            let drawing = film.map { !$0.complete } ?? true
            Button { open = true } label: {
                HStack(spacing: theme.spacing.m) {
                    ZStack {
                        Circle().fill(s.accent).frame(width: 44, height: 44)
                        Image(systemName: "play.fill").font(.system(size: 17, weight: .bold)).foregroundStyle(s.onAccent)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(theme.font(theme.type.body, .heavy)).foregroundStyle(s.ink).multilineTextAlignment(.leading)
                        Text(drawing ? "Drawing it now" : "\(film?.scenes.count ?? 0) scenes")
                            .font(theme.font(theme.type.caption, .medium)).foregroundStyle(s.inkSoft)
                    }
                    Spacer(minLength: 0)
                }
                .padding(theme.spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(s.surface, in: .rect(cornerRadius: theme.radius.card))
                .overlay(RoundedRectangle(cornerRadius: theme.radius.card).stroke(s.outline, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Film: \(title)")
            .accessibilityHint("Plays full screen")
            .accessibilityIdentifier("motion-tile")
            .task { if MotionFilms.shared.shouldAutoOpen(filmID) || ProcessInfo.processInfo.arguments.contains("-yuiMotionOpen") { open = true } }
            .fullScreenCover(isPresented: $open) {
                MotionFilmPlayer(filmID: filmID, title: title, again: {
                    open = false
                    emit(MotionEnd.again(film: filmID, title: title))
                }, change: {
                    open = false
                    filmChange(filmID)
                }) { open = false }
            }
        }
    }
}

/// The player for one film: the native chrome around the bundled kit, fed the film's scenes as they arrive.
struct MotionFilmPlayer: View {
    let filmID: String
    let title: String
    var again: () -> Void = {}
    var change: () -> Void = {}
    let close: () -> Void
    @StateObject private var controller = MotionController()
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var fed = 0
    @State private var ended = false

    private var film: MotionFilm? { MotionFilms.shared.film(filmID) }

    var body: some View {
        MotionView(controller: controller, onClose: close) {
            MotionFallback(title: title, words: film?.words ?? [], close: close)
        } after: {
            MotionEndButtons(replay: { controller.replay() }, again: again, change: change)
        }
        .onAppear {
            controller.setTheme(theme.palette(for: scheme), dark: scheme == .dark)
            feed()
        }
        .onChange(of: film?.scenes.count ?? 0) { _, _ in feed() }
        .onChange(of: film?.complete ?? false) { _, _ in feed() }
    }

    private func feed() {
        guard let f = film else { return }
        let scenes = f.scenes
        while fed < scenes.count { controller.addScene(scenes[fed]); fed += 1 }
        if f.complete, !ended { ended = true; controller.end() }
    }
}

/// What the agent hears when a film ends and the person wants more (YUI-320). The tap is a normal turn:
/// `[yui] m7 motion again note="..." title="How a heart pumps"`, and the agent answers with a new `motion` line.
enum MotionEnd {
    static func again(film: String, title: String) -> YLEvent {
        YLEvent(id: film, preset: "motion",
                value: ["again": .bool(true), "title": .string(title),
                        "note": .string("make this film again, a different take, same ask")],
                echo: "Another take")
    }
}

/// Over the last frame once the film ends: Replay, Another take, Change it. Every button does something.
struct MotionEndButtons: View {
    let replay: () -> Void
    let again: () -> Void
    let change: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        VStack {
            Spacer()
            HStack(spacing: 8) {
                pill("Replay", "arrow.counterclockwise", id: "motion.replay", fill: s.surface, ink: s.ink, line: s.outline, replay)
                pill("Another take", "sparkles", id: "motion.again", fill: s.accent, ink: s.onAccent, line: s.accent, again)
                pill("Change it", "pencil", id: "motion.change", fill: s.surface, ink: s.ink, line: s.outline, change)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 84)
        }
    }

    private func pill(_ title: String, _ icon: String, id: String, fill: Color, ink: Color, line: Color,
                      _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 12, weight: .black))
                Text(title).font(theme.font(theme.type.caption, .heavy)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 8)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity)
            .background(fill, in: Capsule())
            .overlay(Capsule().stroke(line, lineWidth: 1.5))
        }
        .buttonStyle(BounceButtonStyle())
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }
}

/// What shows when the film cannot play (the watchdog fired): its words, in order.
struct MotionFallback: View {
    let title: String
    let words: [String]
    let close: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        ZStack(alignment: .topTrailing) {
            s.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: theme.spacing.m) {
                Text(title).font(theme.font(theme.type.title, .heavy)).foregroundStyle(s.ink)
                ForEach(Array(words.enumerated()), id: \.offset) { _, w in
                    Text(w).font(theme.font(theme.type.body, .medium)).foregroundStyle(s.inkSoft)
                }
                Spacer()
            }
            .padding(theme.spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            FullScreenCloseButton(action: close).padding(.trailing, 4).padding(.top, 4)
        }
    }
}
