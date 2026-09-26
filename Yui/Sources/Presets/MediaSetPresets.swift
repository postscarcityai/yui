import AVKit
import SwiftUI
import YuiLines

// `gallery`, `compare`, `storyboard` and `image +edit` (YUI-19, spec
// yuigui/spec/YL.md "Media"). Every picture goes through RemoteImage, so
// expired yui-media links re-sign themselves.

/// One gallery or storyboard item: a picture, or a video shown as a play tile.
struct MediaTile: View {
    let src: URL
    var fit: ContentMode = .fill
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        if YLMediaURL.isVideo(src) {
            ZStack {
                s.ink.opacity(0.85)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(s.onAccent, s.accent)
            }
            .accessibilityLabel("Video")
        } else {
            RemoteImage(src: src, fit: fit)
        }
    }
}

/// Full screen, swipe to the next item. Pictures pinch to zoom, videos play.
/// The X or a swipe down closes it.
struct MediaViewer: View {
    let items: [URL]
    let captions: [String]
    @State var index: Int
    let close: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, url in
                    VStack(spacing: 12) {
                        if YLMediaURL.isVideo(url) {
                            ViewerVideo(src: url, active: index == i)
                        } else {
                            ZoomableImage(src: url)
                        }
                        if i < captions.count, !captions[i].isEmpty {
                            Text(captions[i])
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal)
                        }
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: items.count > 1 ? .always : .never))
        }
        .fullScreenExit(close: close)
    }
}

private struct ZoomableImage: View {
    let src: URL
    @State private var scale: CGFloat = 1

    var body: some View {
        RemoteImage(src: src, fit: .fit)
            .scaleEffect(scale)
            .gesture(MagnifyGesture().onChanged { scale = max(1, $0.magnification) }
                .onEnded { _ in withAnimation { scale = 1 } })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ViewerVideo: View {
    let src: URL
    let active: Bool
    @State private var player: AVPlayer?
    @Environment(\.yuiMedia) private var media

    var body: some View {
        Group {
            if let player { VideoPlayer(player: player) } else { ProgressView().tint(.white) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: src) { player = AVPlayer(url: await media?.fresh(src) ?? src) }
        .onChange(of: active) { _, on in if !on { player?.pause() } }
        .onDisappear { player?.pause() }
    }
}

/// A round check on a tile, for `+pick`.
private struct PickCheck: View {
    let on: Bool
    let order: Int?
    let action: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        Button(action: action) {
            ZStack {
                Circle().fill(on ? s.accent : .black.opacity(0.35))
                Circle().stroke(.white, lineWidth: 2)
                if let order, on {
                    Text("\(order)").font(theme.font(theme.type.caption, .black)).foregroundStyle(s.onAccent)
                }
            }
            .frame(width: 30, height: 30)
            .padding(8)
            .contentShape(.rect)
        }
        .buttonStyle(BounceButtonStyle())
        .accessibilityLabel(on ? "Picked" : "Pick")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - gallery

/// `gallery [title] URL|caption ... layout=row|feed|row3d|grid [+pick] [max=] [submit=]`.
struct GalleryPreset: View {
    let c: YLComponent
    @State private var viewing: Int?
    @State private var picked: [Int] = []
    @State private var sent: [Int]?
    @Environment(\.ylScope) private var scope
    @Environment(\.ylAnswers) private var answers
    @Environment(\.agentStyle) private var style
    @Environment(\.ylEmit) private var emit
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private var items: [URL] { (c.strings("items") ?? []).compactMap { YLMediaURL.url($0) } }
    private var caps: [String] { c.strings("caps") ?? [] }

    var body: some View {
        let s = theme.swatch(scheme)
        let layout = c.string("layout") ?? style["gallery"] ?? "row"
        VStack(alignment: .leading, spacing: theme.spacing.m) {
            if let t = c.string("title") { PresetTitle(text: t).padding(.horizontal, theme.spacing.xs) }
            switch layout {
            case "feed":
                VStack(spacing: theme.spacing.m) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, url in
                        tile(i, url).aspectRatio(4 / 3, contentMode: .fit)
                    }
                }
            case "grid":
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: theme.spacing.xs), count: 3),
                          spacing: theme.spacing.xs) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, url in
                        Color.clear.aspectRatio(1, contentMode: .fit).overlay { tile(i, url, radius: theme.radius.bubble / 2) }
                    }
                }
            case "row3d":
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: -20) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, url in
                            tile(i, url)
                                .frame(width: 220, height: 290)
                                .scrollTransition(axis: .horizontal) { view, phase in
                                    view.rotation3DEffect(.degrees(phase.value * -38), axis: (0, 1, 0), perspective: 0.6)
                                        .scaleEffect(1 - abs(phase.value) * 0.18)
                                        .opacity(1 - abs(phase.value) * 0.25)
                                }
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .contentMargins(.horizontal, 60, for: .scrollContent)
                .frame(height: 310)
            default:
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: theme.spacing.s) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, url in
                            tile(i, url).frame(width: 230, height: 170)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollClipDisabled()
            }
            if c.flag("pick"), !c.locked { submit(s) }
        }
        .disabled(c.locked)
        // Reopened thread: the picks sent last come back ticked.
        .onChange(of: answers(scope, c.ylID), initial: true) { _, v in
            guard sent == nil, let back = v?["picked"]?.array?.compactMap(\.number) else { return }
            picked = back.map { Int($0) }
            sent = picked
        }
        .fullScreenCover(item: Binding(get: { viewing.map { Viewing(index: $0) } }, set: { viewing = $0?.index })) { v in
            MediaViewer(items: items, captions: caps, index: v.index, close: { viewing = nil })
        }
    }

    private func tile(_ i: Int, _ url: URL, radius: Double? = nil) -> some View {
        let s = theme.swatch(scheme)
        let r = radius ?? theme.radius.card
        let caption = i < caps.count ? caps[i] : ""
        // The picture is laid over Color.clear so the tile is exactly the size it was
        // given. `.frame(maxWidth: .infinity, maxHeight: .infinity)` grew to a fill
        // image's own height and spilled over Done, which then took no taps.
        return Color.clear
            .overlay { MediaTile(src: url) }
            .overlay(alignment: .bottomLeading) {
                if !caption.isEmpty {
                    Text(caption)
                        .font(theme.font(theme.type.caption, .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .padding(theme.spacing.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                }
            }
            .clipShape(.rect(cornerRadius: r))
            .overlay(RoundedRectangle(cornerRadius: r).stroke(picked.contains(i) ? s.accent : s.outline,
                                                              lineWidth: picked.contains(i) ? 3 : 1.5))
            .contentShape(.rect)
            .onTapGesture {
                viewing = i
                emit(c.event(["open": .bool(true), "index": .number(Double(i))]))
            }
            .overlay(alignment: .topTrailing) {
                if c.flag("pick") {
                    PickCheck(on: picked.contains(i), order: picked.firstIndex(of: i).map { $0 + 1 }) { toggle(i) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(caption.isEmpty ? "Item \(i + 1)" : caption)
    }

    private func toggle(_ i: Int) {
        withAnimation(theme.spring) {
            if let k = picked.firstIndex(of: i) { picked.remove(at: k) }
            else if c.number("max").map({ picked.count < Int($0) }) ?? true { picked.append(i) }
        }
    }

    private func submit(_ s: Swatch) -> some View {
        // Done always answers, even with nothing ticked (TestFlight: "the done button
        // doesn't work"). It reads "Sent" only until the picks change again.
        let fresh = sent == nil || picked != sent
        return VStack(alignment: .leading, spacing: theme.spacing.xs) {
            Text(c.number("max").map { "Tap the circles to pick up to \(YLComponent.format($0))" } ?? "Tap the circles to pick")
                .font(theme.font(theme.type.caption, .semibold)).foregroundStyle(s.inkSoft)
            OptionPill(text: sent != nil && !fresh ? "Sent" : c.string("submit") ?? "Done", fill: s.accent, ink: s.onAccent,
                       on: fresh, grow: true) {
                let changed = sent != nil
                sent = picked
                let names = picked.map { i in i < caps.count && !caps[i].isEmpty ? caps[i] : "#\(i + 1)" }
                emit(c.answer(["picked": .array(picked.map { .number(Double($0)) })],
                              echo: names.isEmpty ? "None of these" : "Picked " + names.joined(separator: ", "), changed: changed))
            }
            .disabled(!fresh)
        }
    }
}

private struct Viewing: Identifiable {
    let index: Int
    var id: Int { index }
}

// MARK: - compare

/// `compare BEFORE AFTER [title] mode=slider|side|toggle notes=a|b hl=x,y,w,h|... labels=A|B [+pick]`.
struct ComparePreset: View {
    let c: YLComponent
    @State private var mode: String?
    @State private var split = 0.5
    @State private var showAfter = true
    @State private var choice: String?
    @State private var full = false
    @Environment(\.ylOnStage) private var onStage
    @Environment(\.ylEmit) private var emit
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private var labels: [String] {
        let l = c.strings("labels") ?? []
        return [l.first ?? "Before", l.count > 1 ? l[1] : "After"]
    }
    private var boxes: [[Double]] { (c.props["hl"]?.array ?? []).compactMap { $0.array?.compactMap(\.number) }.filter { $0.count == 4 } }

    var body: some View {
        let s = theme.swatch(scheme)
        let current = mode ?? c.string("mode") ?? "slider"
        let before = YLMediaURL.url(c.string("before"))
        let after = YLMediaURL.url(c.string("after"))
        PresetCard {
            HStack(spacing: theme.spacing.s) {
                if let t = c.string("title") { PresetTitle(text: t) }
                Spacer(minLength: 0)
                if !onStage {
                    Button { full = true } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(theme.font(theme.type.caption, .black))
                            .foregroundStyle(s.ink)
                            .frame(width: 36, height: 36)
                            .background(s.background, in: Circle())
                            .overlay(Circle().stroke(s.outline, lineWidth: 1.5))
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(BounceButtonStyle())
                    .accessibilityLabel("Compare full screen")
                }
            }
            modes(current)
            pictures(current, before, after, s, full: nil)
                .clipShape(.rect(cornerRadius: theme.radius.bubble))
            notes(s)
            if c.flag("pick"), !c.locked {
                HStack(spacing: theme.spacing.s) {
                    ForEach(Array(labels.enumerated()), id: \.offset) { i, l in
                        OptionPill(text: l, fill: s.candy[i % 4], ink: s.candyInk(i), on: choice == nil || choice == l,
                                   dim: choice != nil && choice != l, grow: true) {
                            guard choice != l else { return }
                            let changed = choice != nil
                            withAnimation(theme.spring) { choice = l }
                            emit(c.answer(["choice": .string(l)], echo: l, changed: changed))
                        }
                    }
                }
            }
        }
        .disabled(c.locked)
        // The whole phone for the pictures: same mode, same slider position.
        .fullScreenCover(isPresented: $full) {
            VStack(alignment: .leading, spacing: theme.spacing.m) {
                if let t = c.string("title") { PresetTitle(text: t).padding(.trailing, 64) }
                modes(current).padding(.trailing, c.string("title") == nil ? 64 : 0)
                GeometryReader { geo in
                    pictures(current, before, after, s, full: geo.size)
                        .clipShape(.rect(cornerRadius: theme.radius.bubble))
                }
                notes(s)
            }
            .padding(theme.spacing.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(s.background.ignoresSafeArea())
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("Compare viewer")
            .fullScreenExit { full = false }
        }
    }

    private func modes(_ current: String) -> some View {
        Picker("Compare", selection: Binding(get: { current }, set: { m in withAnimation(theme.spring) { mode = m } })) {
            Text("Slider").tag("slider")
            Text("Side by side").tag("side")
            Text("Toggle").tag("toggle")
        }
        .pickerStyle(.segmented)
    }

    /// The two pictures in `mode`: in the chat at a fixed ratio, full screen at
    /// `full` (side by side stacks top and bottom on a tall screen).
    @ViewBuilder
    private func pictures(_ mode: String, _ before: URL?, _ after: URL?, _ s: Swatch, full: CGSize?) -> some View {
        switch mode {
        case "side":
            box(8 / 5, full) {
                let a = labeled(before, labels[0], hl: false), b = labeled(after, labels[1], hl: true)
                if let full, full.height > full.width {
                    VStack(spacing: theme.spacing.xs) { a; b }
                } else {
                    HStack(spacing: theme.spacing.xs) { a; b }
                }
            }
        case "toggle":
            box(4 / 3, full) { labeled(showAfter ? after : before, labels[showAfter ? 1 : 0], hl: showAfter) }
                .contentShape(.rect)
                .onTapGesture { withAnimation(theme.spring) { showAfter.toggle() } }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Shows the other side")
        default:
            box(4 / 3, full) { slider(before, after, s) }
        }
    }

    /// Full width at `ratio`, or exactly `full`. The size comes from the empty
    /// box, never from the pictures: a fill image's own size leaks out,
    /// shrinking the slider or stretching side by side (and the whole reply) past the screen.
    @ViewBuilder
    private func box(_ ratio: CGFloat, _ full: CGSize?, @ViewBuilder _ content: () -> some View) -> some View {
        if let full {
            content().frame(width: full.width, height: full.height).clipped()
        } else {
            RatioBox(ratio: ratio) { content() }.clipped()
        }
    }

    private func picture(_ url: URL?) -> some View {
        let s = theme.swatch(scheme)
        // Over an empty color, so the picture's own width never skews an HStack split.
        return Color.clear
            .overlay {
                if let url { RemoteImage(src: url, fit: .fill) } else { s.background }
            }
            .clipped()
    }

    private func labeled(_ url: URL?, _ label: String, hl: Bool) -> some View {
        picture(url)
            .overlay { if hl { HighlightBoxes(boxes: boxes) } }
            .overlay(alignment: .topLeading) { Tag(text: label).padding(theme.spacing.s) }
            .clipShape(.rect(cornerRadius: theme.radius.bubble / 2))
    }

    private func slider(_ before: URL?, _ after: URL?, _ s: Swatch) -> some View {
        GeometryReader { geo in
            let x = geo.size.width * split
            ZStack(alignment: .leading) {
                picture(after).overlay { HighlightBoxes(boxes: boxes) }
                picture(before)
                    .mask(alignment: .leading) { Rectangle().frame(width: x) }
                Rectangle().fill(.white).frame(width: 3).offset(x: x - 1.5)
                Image(systemName: "arrow.left.and.right")
                    .font(theme.font(theme.type.caption, .black))
                    .foregroundStyle(s.onAccent)
                    .frame(width: 36, height: 36)
                    .background(s.accent, in: Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .offset(x: x - 18)
            }
            .overlay(alignment: .topLeading) { Tag(text: labels[0]).padding(theme.spacing.s) }
            .overlay(alignment: .topTrailing) { Tag(text: labels[1]).padding(theme.spacing.s) }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                split = min(max(v.location.x / max(geo.size.width, 1), 0), 1)
            })
            .accessibilityElement()
            .accessibilityLabel("\(labels[0]) and \(labels[1])")
            .accessibilityValue("\(Int(split * 100)) percent \(labels[0])")
            .accessibilityAdjustableAction { dir in
                split = min(max(split + (dir == .increment ? 0.1 : -0.1), 0), 1)
            }
        }
    }

    @ViewBuilder
    private func notes(_ s: Swatch) -> some View {
        let notes = c.strings("notes") ?? []
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: theme.spacing.s) {
                ForEach(Array(notes.enumerated()), id: \.offset) { i, n in
                    HStack(alignment: .firstTextBaseline, spacing: theme.spacing.s) {
                        Text("\(i + 1)")
                            .font(theme.font(theme.type.caption, .heavy))
                            .foregroundStyle(s.onAccent)
                            .frame(width: 22, height: 22)
                            .background(s.accent, in: Circle())
                        Text(n).font(theme.font(theme.type.body, .medium)).foregroundStyle(s.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// The full offered width, `width / ratio` tall; children get exactly that.
/// `.aspectRatio(.fit)` falls back to the child's ideal size when the height is
/// open (it is, in a scrolling chat), which left compare a thumbnail.
struct RatioBox: Layout {
    let ratio: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 320
        return CGSize(width: w, height: w / ratio)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for v in subviews { v.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }
}

/// Numbered boxes over a picture, in percent of its size.
struct HighlightBoxes: View {
    let boxes: [[Double]]
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        GeometryReader { geo in
            ForEach(Array(boxes.enumerated()), id: \.offset) { i, b in
                let r = CGRect(x: b[0] / 100 * geo.size.width, y: b[1] / 100 * geo.size.height,
                               width: b[2] / 100 * geo.size.width, height: b[3] / 100 * geo.size.height)
                RoundedRectangle(cornerRadius: 8)
                    .stroke(s.accent, style: StrokeStyle(lineWidth: 3, dash: [7, 4]))
                    .frame(width: r.width, height: r.height)
                    .overlay(alignment: .topLeading) {
                        Text("\(i + 1)")
                            .font(theme.font(theme.type.caption, .heavy))
                            .foregroundStyle(s.onAccent)
                            .frame(width: 22, height: 22)
                            .background(s.accent, in: Circle())
                            .offset(x: -8, y: -8)
                    }
                    .offset(x: r.minX, y: r.minY)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A small dark label on a picture.
struct Tag: View {
    let text: String
    @Environment(\.yuiTheme) private var theme

    var body: some View {
        Text(text)
            .font(theme.font(theme.type.caption, .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, theme.spacing.s)
            .padding(.vertical, theme.spacing.xs)
            .background(.black.opacity(0.55), in: Capsule())
    }
}

// MARK: - storyboard

/// `storyboard [title] URL|note ... [+reorder] [comment=off]`, or `frames=` / `notes=`.
struct StoryboardPreset: View {
    let c: YLComponent
    @State private var order: [Int]?
    @State private var savedOrder: [Int]?
    @State private var viewing: Int?
    @State private var drafts: [Int: String] = [:]
    @State private var commented: Set<Int> = []
    @Environment(\.ylEmit) private var emit
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private var frames: [String] { c.strings("frames") ?? [] }
    private var notes: [String] { c.strings("notes") ?? [] }
    private var count: Int { max(frames.count, notes.count) }

    var body: some View {
        let s = theme.swatch(scheme)
        let current = order ?? Array(0..<count)
        let urls = frames.compactMap { YLMediaURL.url($0) }
        PresetCard {
            if let t = c.string("title") { PresetTitle(text: t) }
            VStack(spacing: theme.spacing.m) {
                ForEach(Array(current.enumerated()), id: \.element) { pos, i in
                    row(pos: pos, i: i, total: current.count, s)
                }
            }
            if c.flag("reorder"), !c.locked, current != (savedOrder ?? Array(0..<count)) {
                OptionPill(text: "Save order", fill: s.accent, ink: s.onAccent, grow: true) {
                    savedOrder = current
                    emit(c.event(["order": .array(current.map { .number(Double($0)) })], echo: "New order: " +
                        current.map { i in i < notes.count && !notes[i].isEmpty ? notes[i] : "#\(i + 1)" }.joined(separator: ", ")))
                }
                .transition(.opacity)
            }
        }
        .disabled(c.locked)
        .fullScreenCover(item: Binding(get: { viewing.map { Viewing(index: $0) } }, set: { viewing = $0?.index })) { v in
            MediaViewer(items: urls, captions: notes, index: v.index, close: { viewing = nil })
        }
    }

    private func row(pos: Int, i: Int, total: Int, _ s: Swatch) -> some View {
        let url = i < frames.count ? YLMediaURL.url(frames[i]) : nil
        let note = i < notes.count ? notes[i] : ""
        return VStack(alignment: .leading, spacing: theme.spacing.s) {
            HStack(alignment: .top, spacing: theme.spacing.m) {
                ZStack {
                    if let url { MediaTile(src: url) } else { s.lavender }
                    if url == nil {
                        Text("\(i + 1)").font(theme.font(theme.type.display, .black)).foregroundStyle(s.userInk)
                    }
                }
                .frame(width: 104, height: 76)
                .clipShape(.rect(cornerRadius: theme.radius.bubble / 2))
                .overlay(alignment: .topLeading) {
                    if url != nil { Tag(text: "\(pos + 1)").padding(theme.spacing.xs) }
                }
                .onTapGesture {
                    guard url != nil else { return }
                    viewing = i
                    emit(c.event(["open": .bool(true), "index": .number(Double(i))]))
                }
                .accessibilityLabel("Frame \(pos + 1)")
                .accessibilityAddTraits(url != nil ? .isButton : [])
                Text(note.isEmpty ? "Frame \(pos + 1)" : note)
                    .font(theme.font(theme.type.body, .semibold))
                    .foregroundStyle(s.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if c.flag("reorder"), !c.locked {
                    VStack(spacing: theme.spacing.xs) {
                        move("chevron.up", "Move frame \(pos + 1) up", disabled: pos == 0) { swap(pos, pos - 1) }
                        move("chevron.down", "Move frame \(pos + 1) down", disabled: pos == total - 1) { swap(pos, pos + 1) }
                    }
                }
            }
            if c.props["comment"]?.bool != false, !c.locked { comment(i, pos: pos, s) }
        }
    }

    private func move(_ icon: String, _ label: String, disabled: Bool, _ action: @escaping () -> Void) -> some View {
        let s = theme.swatch(scheme)
        return Button(label, systemImage: icon, action: action)
            .labelStyle(.iconOnly)
            .font(theme.font(theme.type.caption, .black))
            .foregroundStyle(s.ink)
            .frame(width: 32, height: 32)
            .background(s.background, in: Circle())
            .overlay(Circle().stroke(s.outline, lineWidth: 1.5))
            .opacity(disabled ? 0.3 : 1)
            .disabled(disabled)
    }

    private func swap(_ a: Int, _ b: Int) {
        var o = order ?? Array(0..<count)
        o.swapAt(a, b)
        withAnimation(theme.spring) { order = o }
    }

    private func comment(_ i: Int, pos: Int, _ s: Swatch) -> some View {
        HStack(spacing: theme.spacing.s) {
            TextField(commented.contains(i) ? "Comment sent. Add another?" : "Comment on this frame",
                      text: Binding(get: { drafts[i] ?? "" }, set: { drafts[i] = $0 }))
                .font(theme.font(theme.type.caption, .medium))
                .foregroundStyle(s.ink)
                .submitLabel(.send)
                .onSubmit { send(i, pos: pos) }
                .padding(.horizontal, theme.spacing.m)
                .padding(.vertical, theme.spacing.s)
                .background(s.background, in: Capsule())
                .overlay(Capsule().stroke(s.outline, lineWidth: 1))
            if !(drafts[i] ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                Button("Send comment", systemImage: "arrow.up") { send(i, pos: pos) }
                    .labelStyle(.iconOnly)
                    .font(theme.font(theme.type.caption, .black))
                    .foregroundStyle(s.onAccent)
                    .frame(width: 32, height: 32)
                    .background(s.accent, in: Circle())
                    .buttonStyle(BounceButtonStyle())
            }
        }
    }

    private func send(_ i: Int, pos: Int) {
        let text = (drafts[i] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        drafts[i] = ""
        commented.insert(i)
        emit(c.event(["frame": .number(Double(i)), "comment": .string(text)], echo: "Frame \(pos + 1): \(text)"))
    }
}

// MARK: - image +edit

/// `image URL +edit`: circle (freehand) or box an area, say what should change.
/// Emits `{edit: {box, path?, instruction}}`, all in percent of the picture.
struct ImageEditPreset: View {
    let c: YLComponent
    @State private var image: UIImage?
    @State private var failed = false
    @State private var boxMode = false
    @State private var points: [CGPoint] = []
    @State private var start: CGPoint?
    @State private var rect: CGRect?
    @State private var instruction = ""
    @State private var sent = false
    @Environment(\.yuiMedia) private var media
    @Environment(\.ylEmit) private var emit
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        PresetCard {
            PresetTitle(text: c.string("caption") ?? c.string("prompt") ?? "Mark what to change")
            Picker("Mark with", selection: $boxMode) {
                Label("Circle", systemImage: "scribble").tag(false)
                Label("Box", systemImage: "rectangle.dashed").tag(true)
            }
            .pickerStyle(.segmented)
            .onChange(of: boxMode) { clear() }
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(image.size, contentMode: .fit)
                        .overlay { canvas(s) }
                } else if failed {
                    Label("Picture unavailable", systemImage: "photo.badge.exclamationmark")
                        .font(theme.font(theme.type.caption, .bold)).foregroundStyle(s.inkSoft)
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    s.background.overlay(ProgressView().tint(s.accent)).frame(minHeight: 200)
                }
            }
            .clipShape(.rect(cornerRadius: theme.radius.bubble))
            HStack(spacing: theme.spacing.s) {
                TextField("What should change?", text: $instruction, axis: .vertical)
                    .font(theme.font(theme.type.body))
                    .foregroundStyle(s.ink)
                    .padding(.horizontal, theme.spacing.l)
                    .padding(.vertical, theme.spacing.m)
                    .background(s.background, in: .rect(cornerRadius: theme.radius.pill))
                    .overlay(RoundedRectangle(cornerRadius: theme.radius.pill).stroke(s.outline, lineWidth: 1.5))
                if marked {
                    Button("Clear mark", systemImage: "arrow.uturn.backward", action: clear)
                        .labelStyle(.iconOnly)
                        .font(theme.font(theme.type.body, .bold))
                        .foregroundStyle(s.ink)
                        .frame(width: 40, height: 40)
                        .background(s.background, in: Circle())
                        .overlay(Circle().stroke(s.outline, lineWidth: 1.5))
                }
            }
            let ready = marked && !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            OptionPill(text: sent && !ready ? "Sent" : "Send edit", fill: s.accent, ink: s.onAccent, on: ready, grow: true, action: send)
                .disabled(!ready)
        }
        .disabled(c.locked)
        .task(id: c.string("src")) { await load() }
    }

    private var marked: Bool { rect != nil }

    private func canvas(_ s: Swatch) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(.rect)
                if !boxMode, points.count > 1 {
                    Path { p in p.addLines(points.map { CGPoint(x: $0.x * geo.size.width, y: $0.y * geo.size.height) }) }
                        .stroke(s.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
                if let r = rect {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(s.accent, style: StrokeStyle(lineWidth: 2.5, dash: [7, 4]))
                        .background(s.accent.opacity(0.12))
                        .frame(width: r.width * geo.size.width, height: r.height * geo.size.height)
                        .offset(x: r.minX * geo.size.width, y: r.minY * geo.size.height)
                }
            }
            .gesture(DragGesture(minimumDistance: 2).onChanged { v in
                let p = CGPoint(x: min(max(v.location.x / geo.size.width, 0), 1), y: min(max(v.location.y / geo.size.height, 0), 1))
                if start == nil {
                    start = CGPoint(x: min(max(v.startLocation.x / geo.size.width, 0), 1),
                                    y: min(max(v.startLocation.y / geo.size.height, 0), 1))
                    points = [start!]
                }
                if boxMode {
                    let a = start!
                    rect = CGRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(p.x - a.x), height: abs(p.y - a.y))
                } else {
                    points.append(p)
                    rect = Self.bounds(points)
                }
            }.onEnded { _ in start = nil })
            .accessibilityLabel(boxMode ? "Drag to box an area" : "Draw around an area")
        }
    }

    static func bounds(_ pts: [CGPoint]) -> CGRect {
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    private func clear() {
        points = []
        rect = nil
        start = nil
    }

    private func pct(_ v: CGFloat) -> YLValue { .number((Double(v) * 1000).rounded() / 10) }

    private func send() {
        guard let r = rect else { return }
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        var edit: [String: YLValue] = [
            "box": .array([pct(r.minX), pct(r.minY), pct(r.width), pct(r.height)]),
            "instruction": .string(text),
        ]
        if !boxMode, points.count > 2 {
            // At most about 24 points, evenly spaced along the stroke.
            let step = max(1, Int((Double(points.count) / 24).rounded(.up)))
            let thin = stride(from: 0, to: points.count, by: step).map { points[$0] }
            edit["path"] = .array(thin.map { .array([pct($0.x), pct($0.y)]) })
        }
        sent = true
        instruction = ""
        emit(c.event(["edit": .object(edit)], echo: text))
    }

    private func load() async {
        guard let src = YLMediaURL.url(c.string("src")) else { failed = true; return }
        let url = await media?.fresh(src) ?? src
        // Drawn the width of the card at most: a 12 MP picture decodes at that, not in full (YUI-100).
        let screen = CGSize(width: 440, height: 440)
        if let (data, _) = try? await URLSession.shared.data(from: url),
           let img = await Task.detached(operation: { Pictures.downsample(data, points: screen, scale: 3) }).value {
            image = img
        } else {
            failed = true
        }
    }
}
