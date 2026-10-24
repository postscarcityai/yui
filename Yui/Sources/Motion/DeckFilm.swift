import SwiftUI
import YuiLines

// An explainer deck becomes a film on the phone (Chris, TestFlight Oct 5 to 7: "a card in a card with a tiny
// little stupid drawing", "a shitty PowerPoint deck", "animated vector graphics or something that tweens",
// "I want this to be an immersive experience"). A `deck` whose pages carry `shapes` (or a `sketch`, or no
// picture) is compiled here, on the phone, into scenes for the bundled motion kit: no network, no model, no
// wait. Each page is one scene: the drawing is the hero in the middle band, drawn on part by part in the
// agent's colours and alive after; the title comes on as kinetic type; the body is spoken, a sentence at a
// time, and captioned by the kit. The stage plays it full bleed where the slides used to be.

enum DeckFilm {
    /// The pictures a page can carry and still film: a `shapes` drawing, a `sketch` (its rows become lines), or none.
    static let filmable: Set<String> = ["shapes", "sketch"]

    /// Whether the stage can film this deck: every step is a page whose picture is filmable, or a question
    /// (asked after the film), and at least one page exists.
    static func canFilm(steps: [YLComponent], all: [YLComponent]) -> Bool {
        let pages = steps.filter { $0.preset == "page" }
        guard !pages.isEmpty else { return false }
        return pages.allSatisfy { p in
            guard let pic = all.picture(of: p) else { return true }
            return filmable.contains(pic.preset)
        }
    }

    /// The film: one scene per page, in order. Questions between pages are skipped (the stage asks them after).
    static func scenes(steps: [YLComponent], all: [YLComponent]) -> [MotionSceneSpec] {
        steps.filter { $0.preset == "page" }.enumerated().map { i, p in scene(page: p, index: i, all: all) }
    }

    /// Every line the film says, page by page: the fallback's words and VoiceOver's.
    static func words(steps: [YLComponent], all: [YLComponent]) -> [String] {
        steps.filter { $0.preset == "page" }.flatMap { p -> [String] in
            let title = p.string("title").map { [$0] } ?? []
            return title + lines(page: p, pic: all.picture(of: p), all: all)
        }
    }

    // MARK: One scene

    struct Beat: Equatable {
        var text: String
        var from: Double
        var to: Double
    }

    /// Seconds a line is on screen and in the voice: about a third of a second a word, with room to land.
    static func window(_ words: Int) -> Double { max(2.2, Double(words) * 0.36 + 0.7) }
    static let leastScene = 5.0, mostScene = 16.0, firstBeat = 0.6, tail = 0.8

    /// The spoken lines of a page: the body a sentence at a time, then its points, then a sketch's rows.
    static func lines(page: YLComponent, pic: YLComponent?, all: [YLComponent]) -> [String] {
        var out: [String] = []
        if let body = page.string("body"), !body.trimmingCharacters(in: .whitespaces).isEmpty {
            let s = LongText.sentences(body)
            out += s.isEmpty ? [body] : s
        }
        out += page.strings("points") ?? []
        if let pic, pic.preset == "sketch" {
            for r in all.members(of: pic) where r.preset == "row" {
                if let t = r.string("text") ?? r.string("title"), !t.isEmpty { out.append(t) }
            }
        }
        if out.isEmpty, let caption = pic?.string("caption"), !caption.isEmpty { out.append(caption) }
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// The lines laid on the scene's clock, one after another.
    static func beats(_ lines: [String]) -> [Beat] {
        var t = firstBeat
        return lines.map { l in
            let w = window(LongText.wordCount(l))
            defer { t += w }
            return Beat(text: l, from: t, to: t + w - 0.15)
        }
    }

    static func duration(_ beats: [Beat]) -> Double {
        min(mostScene, max(leastScene, (beats.last?.to ?? 0) + tail))
    }

    /// The title's size: a few words big, a sentence a step down.
    static func titleSize(_ title: String) -> Double {
        let n = LongText.wordCount(title)
        return n <= 3 ? 40 : n <= 6 ? 34 : 28
    }

    /// A caption's size: the kit sets 28 for six words; longer lines step down so they stay in the band.
    static func captionSize(_ text: String) -> Double {
        let n = LongText.wordCount(text)
        return n <= 6 ? 26 : n <= 14 ? 21 : 18
    }

    static func scene(page: YLComponent, index: Int, all: [YLComponent]) -> MotionSceneSpec {
        let pic = all.picture(of: page)
        let title = page.string("title") ?? ""
        let spoken = beats(lines(page: page, pic: pic, all: all))
        let dur = duration(spoken)
        var shapes: [String: Any] = [:]
        var rows: [[String: Any]] = []
        if let pic {
            if pic.preset == "shapes" {
                let parts = all.members(of: pic).filter { $0.preset == "shape" }
                shapes = sceneJSON(ShapesModel.scene(head: pic.props, members: parts.map { (id: $0.ylID, props: $0.props) }))
            } else if pic.preset == "sketch" {
                rows = all.members(of: pic).filter { $0.preset == "row" }.map { r in
                    ["text": r.string("text") ?? r.string("title") ?? "", "x": r.flag("x"), "hi": r.flag("hi"), "button": r.flag("button")]
                }
            }
        }
        let data: [String: Any] = [
            "title": title, "ts": titleSize(title), "dur": dur,
            "say": spoken.map { ["text": $0.text, "from": $0.from, "to": $0.to, "size": captionSize($0.text)] },
            "shapes": shapes, "rows": rows, "first": index == 0,
        ]
        let code = "var D = \(json(data));\n" + kit
        return MotionSceneSpec(name: "page-\(index + 1)", dur: dur, code: code)
    }

    /// A shapes scene as the kit draws it: units, and each part with its place, size, timing and the ends of a
    /// connector already resolved to the edges of the shapes it joins (ShapesModel's still frame).
    static func sceneJSON(_ sc: ShapesModel.Scene) -> [String: Any] {
        let frames = ShapesModel.frame(sc, at: .infinity)
        let items: [[String: Any]] = frames.map { f in
            let it = f.item
            var d: [String: Any] = ["kind": it.kind, "label": it.label, "tone": it.tone, "fill": it.fill, "dash": it.dash,
                                    "pulse": it.pulse, "start": it.start, "dur": max(0.3, it.dur), "motion": it.motion.rawValue]
            if let c = f.c { d["c"] = c }
            if let s = it.size { d["size"] = s }
            if let a = f.a, let b = f.b { d["a"] = a; d["b"] = b }
            if let pts = it.pts { d["pts"] = pts }
            if let bend = it.bend { d["bend"] = bend }
            if let rings = it.rings { d["rings"] = rings }
            if it.close { d["close"] = true }
            return d
        }
        return ["w": sc.w, "h": sc.h, "fs": sc.fs, "items": items, "box": box(frames, w: sc.w, h: sc.h, fs: sc.fs)]
    }

    /// The drawing's own extent in canvas units, with a little air, so the film can fit it rather than the canvas.
    static func box(_ frames: [ShapesModel.Frame], w: Double, h: Double, fs: Double = 0.42) -> [Double] {
        var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
        func take(_ p: [Double], _ r: [Double] = [0, 0]) {
            x0 = min(x0, p[0] - r[0] / 2); x1 = max(x1, p[0] + r[0] / 2)
            y0 = min(y0, p[1] - r[1] / 2); y1 = max(y1, p[1] + r[1] / 2)
        }
        for f in frames {
            if let c = f.c {
                var size = f.item.size ?? [0, 0]
                // A label under a dot, or a bare text, is wider than the shape: about 0.55 of the label size a character.
                if f.item.kind == "dot" || f.item.kind == "text", !f.item.label.isEmpty {
                    size = [max(size[0], 0.55 * fs * Double(f.item.label.count)), size[1] + (f.item.kind == "dot" ? fs * 2.2 : 0)]
                }
                take(c, size)
            }
            if let a = f.a { take(a) }
            if let b = f.b { take(b) }
            for p in f.item.pts ?? [] where p.count >= 2 { take(p) }
        }
        guard x0.isFinite, y0.isFinite, x1 > x0, y1 > y0 else { return [0, 0, w, h] }
        // Labels under a dot and glow want room: a third of a unit around, and a little more below.
        let air = 0.35
        return [max(0, x0 - air), max(0, y0 - air), min(w, x1 + air), min(h, y1 + air + 0.5)]
    }

    /// JSON as a JS literal. Numbers that are not finite are dropped by the serializer, so none reach it.
    static func json(_ o: Any) -> String {
        guard JSONSerialization.isValidJSONObject(o), let d = try? JSONSerialization.data(withJSONObject: o),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        // U+2028 and U+2029 are line breaks to JavaScript: escape them, and the </ that could close a script.
        return s.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            .replacingOccurrences(of: "</", with: "<\\/")
    }

    /// The scene body the kit runs every frame: `(t, c, api)` with `D` defined above it. Layout: the hero band
    /// runs from under the top bar to above the title; the title sits over the caption band; captions and the
    /// voice are the kit's (`api.say`).
    static let kit = #"""
    api.look('agent');
    var W = api.w, H = api.h, pi = Math.PI;
    var TONE = {accent: 'accent', mint: 'a2', lavender: 'a3', butter: 'warn', ink: 'fg', mute: 'dim'};
    function tone(n) { return TONE[n] || 'accent'; }
    // The screen in three bands: the hero on top, the title under it, the spoken line at the bottom.
    var bandTop = H * 0.06, bandH = H * 0.46, titleY = H * 0.5, heroBottom = 0;
    var hero = {x: W / 2, y: bandTop + bandH / 2};
    // A quiet field behind the hero, drifting.
    api.swarm(16, t, {mode: 'drift', cx: hero.x, cy: hero.y, rx: W * 0.42, ry: bandH * 0.42, c: 'a2', size: 2.2, a: 0.35, glow: 8, seed: 3});
    // The scene fades out in its last half second, so the next one takes over clean.
    c.globalAlpha = api.seg(D.dur - t, 0, 0.6);
    // The drawing leans in a touch as it comes on, then settles.
    var zoom = api.lerp(1.05, 1, api.ease(api.seg(t, 0, Math.min(2.4, D.dur))));
    function drawShapes(S) {
      if (!S || !S.items || !S.items.length) return;
      // Fit the drawing's own extent (not its canvas) to the band, so a row of three fills the width.
      var b = S.box || [0, 0, S.w, S.h], bw = Math.max(1, b[2] - b[0]), bh = Math.max(1, b[3] - b[1]);
      var pad = 18, sc = Math.min((W - 2 * pad) / bw, bandH / bh) * zoom;
      var ox = (W - bw * sc) / 2 - b[0] * sc, oy = bandTop + (bandH - bh * sc) / 2 - b[1] * sc;
      heroBottom = oy + b[3] * sc;
      function X(p) { return ox + p[0] * sc; } function Y(p) { return oy + p[1] * sc; }
      var lw = Math.max(4, 0.013 * S.w * sc), fs = Math.max(18, S.fs * sc);
      S.items.forEach(function (it) {
        var k = api.seg(t, it.start, it.start + it.dur); if (k <= 0) return;
        var col = tone(it.tone), done = t > it.start + it.dur;
        var pz = (it.pulse && done) ? 1 + 0.05 * Math.sin((t - it.start - it.dur) * 2 * pi / 1.6) : 1;
        var o = {c: col, w: lw, k: k, glow: it.pulse ? 14 : 0};
        if (it.dash) o.dash = [lw * 3, lw * 2.5];
        if (it.fill) { o.fill = col; o.fa = 0.22; }
        if (it.c && it.size) {
          var x = X(it.c), y = Y(it.c), w = it.size[0] * sc * pz, h = it.size[1] * sc * pz;
          var round = it.kind === 'circle' || it.kind === 'blob' || it.kind === 'venn' || it.kind === 'tap';
          if (round) api.ellipse(x, y, w / 2, h / 2, o);
          else if (it.kind === 'contour') { var R = it.rings || 4; for (var r = 0; r < R; r++) { var sh = 1 - r / R; api.ellipse(x, y, w / 2 * sh, h / 2 * sh, {c: col, w: lw * (r ? 0.7 : 1), k: api.seg(k, r / R * 0.5, r / R * 0.5 + 0.5), a: r ? 0.75 : 1}); } }
          else if (it.kind === 'dot') api.dot(x, y, Math.max(w, h) / 2, {c: col, k: k, glow: 10});
          else if (it.kind !== 'text') api.rect(x - w / 2, y - h / 2, w, h, Object.assign({r: it.kind === 'pill' ? h / 2 : Math.min(20, h * 0.28)}, o));
          if (it.label) {
            var inside = it.kind !== 'dot' && it.kind !== 'text';
            api.text(it.label, x, inside ? y : y + h / 2 + fs * 0.95, {size: fs * (it.kind === 'text' ? 1.15 : 1), c: 'fg', weight: 800, k: api.seg(k, 0.35, 1),
                     maxw: inside ? Math.max(w * 0.86, fs * 3.2) : W * 0.5, free: inside});
          }
        } else if (it.a && it.b) {
          var ax = X(it.a), ay = Y(it.a), bx = X(it.b), by = Y(it.b);
          var ao = {c: col, w: lw, k: k, head: it.kind !== 'line' && it.kind !== 'bracket'};
          if (it.dash) ao.dash = [lw * 3, lw * 2.5];
          if (it.bend) ao.bend = -it.bend * Math.hypot(bx - ax, by - ay);
          api.arrow(ax, ay, bx, by, ao);
          if (it.label) api.text(it.label, (ax + bx) / 2, (ay + by) / 2 - fs * 1.1, {size: fs * 0.85, c: 'dim', k: k});
        } else if (it.pts && it.pts.length > 1) {
          api.poly(it.pts.map(function (p) { return [X(p), Y(p)]; }), Object.assign({close: !!it.close}, o));
        }
      });
    }
    function drawRows(rows) {
      if (!rows || !rows.length) return;
      var n = rows.length, lh = Math.min(46, bandH / (n + 0.5)), y0 = hero.y - lh * (n - 1) / 2;
      heroBottom = y0 + (n - 1) * lh + lh / 2;
      rows.forEach(function (r, i) {
        var k = api.stag(t, i, {gap: 0.35, dur: 0.6, from: 0.3}); if (k <= 0) return;
        var y = y0 + i * lh, col = r.hi ? 'accent' : r.x ? 'dim' : 'fg';
        var b = api.text(r.text, 36, y, {size: 22, c: col, weight: r.hi ? 800 : 600, align: 'left', k: k, maxw: W - 72, free: true});
        if (r.x && b) api.line(b.x, y, b.x + b.w, y, {c: 'bad', w: 3, k: api.seg(k, 0.5, 1)});
        if (r.hi) api.dot(22, y, 4, {c: 'accent', k: k});
      });
    }
    drawShapes(D.shapes);
    drawRows(D.rows);
    api.cam0();
    // The title sits a hand under the drawing, never higher than mid screen, never over the spoken line.
    if (heroBottom) titleY = Math.min(H * 0.66, Math.max(H * 0.5, heroBottom + 72));
    if (D.title) api.kinetic(D.title, W / 2, titleY, {mode: 'rise', k: api.seg(t, 0.15, 1.1), size: D.ts, maxw: W - 44, shadow: false, lh: 1.08});
    // The spoken line: the kit's cue carries the voice (its own caption is parked off screen), the words are
    // set here in a quieter weight than the kit's caption.
    D.say.forEach(function (s) {
      api.say(s.text, s.from, s.to, {y: -600});
      var al = Math.min(1, Math.max(0, Math.min((t - s.from) / 0.45, (s.to - t) / 0.45)));
      if (al > 0) api.text(s.text, W / 2, H * 0.84, {size: s.size, c: 'dim', weight: 600, a: al * al * (3 - 2 * al), maxw: W - 56, free: true, lh: 1.28});
    });
    """#
}

// MARK: - On the stage

/// The film of a deck, full bleed in the stage's page: the kit draws it, the phone speaks it. Close goes home;
/// when it ends, Replay and the way on (the questions, or home) float over the last frame.
struct DeckFilmStage: View {
    let deck: StageDeck
    /// Something to answer after the film.
    let hasQuestions: Bool
    let onQuestions: () -> Void
    let onHome: () -> Void
    @StateObject private var controller = MotionController()
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var fed = false

    var body: some View {
        let s = theme.swatch(scheme)
        MotionView(controller: controller, onClose: onHome) {
            // The kit could not draw (a slow phone, a frame that never came): the words, plainly.
            MotionFallback(title: deck.head.string("title") ?? "", words: DeckFilm.words(steps: deck.steps, all: deck.all), close: onHome)
        } after: {
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    endPill("Replay", "arrow.counterclockwise", id: "deck-film.replay", fill: s.surface, ink: s.ink, line: s.outline) { controller.replay() }
                    if hasQuestions {
                        endPill("Answer", "hand.tap", id: "deck-film.questions", fill: s.accent, ink: s.onAccent, line: s.accent, onQuestions)
                    } else {
                        endPill("Back home", "house", id: "deck-film.home", fill: s.accent, ink: s.onAccent, line: s.accent, onHome)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 84)
            }
        }
        .accessibilityIdentifier("stage-film")
        .onAppear {
            controller.setTheme(theme.palette(for: scheme), dark: scheme == .dark)
            guard !fed else { return }
            fed = true
            for scene in DeckFilm.scenes(steps: deck.steps, all: deck.all) { controller.addScene(scene) }
            controller.end()
        }
    }

    private func endPill(_ title: String, _ icon: String, id: String, fill: Color, ink: Color, line: Color,
                         _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 12, weight: .black))
                Text(title).font(theme.font(theme.type.caption, .heavy)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity)
            .background(fill, in: Capsule())
            .overlay(Capsule().stroke(line, lineWidth: 1.5))
        }
        .buttonStyle(BounceButtonStyle())
        .accessibilityIdentifier(id)
    }
}
