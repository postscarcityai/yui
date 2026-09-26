import SwiftUI
import YuiLines

// Full-screen pages tell a story (YUI-82, TestFlight feedback on build 96: "we're
// telling a story visually with the letters"). On the stage a page is the whole
// screen, never a card: the headline is set big, sized to its words, the body is a
// second, quieter voice, points are numbered beats, and a picture has its own slot.
// Each part springs on when the page arrives and drifts off when it leaves; with
// Reduce Motion they only fade. In the chat a page is still drawn by PagePreset.

struct StoryPage: View {
    let c: YLComponent
    /// The page showing now. Its parts come on when this turns true, go off when false.
    var active = true
    var showNotes = false
    @State private var phase = Phase.before
    @State private var viewing = false
    @Environment(\.ylComponents) private var all
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Before it arrives the words wait below; once it has been left they sit above,
    /// so going back brings them down from where they went.
    enum Phase { case before, on, after }

    /// The page showing is always on. Only a page off screen waits above or below.
    /// Driving this from onAppear/onChange alone left a page blank when a paging
    /// TabView missed the event (TestFlight feedback AKsr0Ha8, build 96: "Sometimes
    /// I come to these pages and they don't come back").
    private var shown: Phase { Self.shown(active: active, phase: phase) }
    static func shown(active: Bool, phase: Phase) -> Phase { active ? .on : phase }

    var body: some View {
        let s = theme.swatch(scheme)
        GeometryReader { geo in
            ScrollView {
                content(s, width: geo.size.width)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
        }
        .onChange(of: active) { if !active { phase = .after } }
        .fullScreenCover(isPresented: $viewing) {
            if let img = YLMediaURL.url(c.string("img")) {
                MediaViewer(items: [img], captions: [c.string("title") ?? ""], index: 0, close: { viewing = false })
            }
        }
    }

    private func content(_ s: Swatch, width: CGFloat) -> some View {
        let title = c.string("title").flatMap { $0.isEmpty ? nil : $0 }
        let body = c.string("body").flatMap { $0.isEmpty ? nil : $0 }
        let points = c.strings("points") ?? []
        // No title: the words are the headline.
        let statement = title == nil && points.isEmpty
        // A drawn picture comes on part by part first; the words take their beats after it.
        let drawn = all.art(of: c)
        let after = drawn.map { $0.parts.count + 1 } ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            if let drawn {
                SketchDrawing(sketch: drawn.sketch, parts: drawn.parts, phase: shown)
                    .padding(.bottom, title == nil && body == nil && points.isEmpty ? 0 : theme.spacing.xl)
            } else if let img = YLMediaURL.url(c.string("img")) {
                art(img)
                    .padding(.bottom, theme.spacing.xl)
                    .beat(shown, 0, reduceMotion, theme.spring)
            }
            if let title {
                headline(title, width: width, statement: false)
                    .foregroundStyle(s.ink)
                    .accessibilityIdentifier("story-title")
                    .accessibilityAddTraits(.isHeader)
                    .beat(shown, after + 1, reduceMotion, theme.spring)
            }
            if let body {
                Group {
                    if statement {
                        headline(body, width: width, statement: true).foregroundStyle(s.ink)
                    } else {
                        Text(body)
                            .font(theme.font(voice, .medium))
                            .foregroundStyle(s.ink.opacity(0.72))
                            .lineSpacing(voice * 0.18)
                            .padding(.top, theme.spacing.l)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("story-body")
                .beat(shown, after + (statement ? 1 : 2), reduceMotion, theme.spring)
            }
            if !points.isEmpty {
                VStack(alignment: .leading, spacing: theme.spacing.l) {
                    ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                        HStack(alignment: .firstTextBaseline, spacing: theme.spacing.m) {
                            Text(String(format: "%02d", i + 1))
                                .font(theme.font(voice * 0.8, .black).monospacedDigit())
                                .foregroundStyle(s.accent)
                                .accessibilityHidden(true)
                            Text(p)
                                .font(theme.font(voice, .semibold))
                                .foregroundStyle(s.ink)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("story-point")
                        }
                        .beat(shown, after + 2 + i, reduceMotion, theme.spring)
                    }
                }
                .padding(.top, title == nil && body == nil ? 0 : theme.spacing.xl)
            }
            if showNotes, let n = c.string("notes") {
                Text(n).font(theme.font(theme.type.caption, .medium)).foregroundStyle(s.inkSoft)
                    .padding(theme.spacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(s.butter.opacity(0.35), in: .rect(cornerRadius: theme.radius.bubble / 2))
                    .padding(.top, theme.spacing.xl)
            }
        }
        .padding(.vertical, theme.spacing.xl)
    }

    /// The headline, sized to how much it says, never so big that a word breaks.
    private func headline(_ text: String, width: CGFloat, statement: Bool) -> some View {
        let size = Self.headlineSize(text, width: width, display: theme.type.display, floor: voice + 3, statement: statement)
        return Text(text)
            .font(theme.font(size, statement && LongText.wordCount(text) > 12 ? .bold : theme.strong))
            .tracking(-size * 0.02)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A few words set big, a sentence smaller. The longest word always fits a line:
    /// SF Rounded's widest weights run about 0.64 em a letter.
    static func headlineSize(_ text: String, width: CGFloat, display: Double, floor: Double, statement: Bool) -> Double {
        let n = LongText.wordCount(text)
        let size: Double = statement
            ? (n <= 6 ? display * 1.6 : n <= 12 ? display * 1.3 : n <= 20 ? display * 1.05 : display * 0.9)
            : (n <= 4 ? display * 1.7 : n <= 8 ? display * 1.4 : display * 1.15)
        let longest = text.split(whereSeparator: \.isWhitespace).map(\.count).max() ?? 1
        let fits = width > 0 ? Double(width) / (Double(longest) * 0.64) : size
        return max(min(size, fits), min(floor, fits))
    }

    /// The body's voice: a size under the headline, bigger with larger text settings
    /// (the headline is big already).
    private var voice: Double {
        let base = theme.type.title + 1
        return typeSize.isAccessibilitySize ? base * 1.3 : typeSize >= .xxLarge ? base * 1.12 : base
    }

    /// The picture's slot for an image (a drawn `sketch` takes it over, see `content`).
    private func art(_ img: URL) -> some View {
        MediaTile(src: img)
            .frame(maxWidth: .infinity)
            .frame(maxHeight: 280)
            .clipShape(.rect(cornerRadius: theme.radius.bubble))
            .onTapGesture { viewing = true }
    }

}

extension View {
    /// One part of a story page on its beat: in order after the page arrives,
    /// all at once and quickly when it leaves.
    func beat(_ phase: StoryPage.Phase, _ order: Int, _ reduce: Bool, _ spring: Animation) -> some View {
        let on = phase == .on
        let travel: CGFloat = reduce ? 0 : phase == .before ? 26 : phase == .after ? -18 : 0
        return self
            .opacity(on ? 1 : 0)
            .offset(y: travel)
            .scaleEffect(on || reduce ? 1 : 0.96, anchor: .bottomLeading)
            .blur(radius: on || reduce ? 0 : 6)
            .animation(on ? (reduce ? .easeOut(duration: 0.25) : spring.delay(0.05 + 0.09 * Double(order)))
                          : .easeIn(duration: 0.16), value: phase)
    }
}
