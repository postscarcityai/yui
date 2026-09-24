// Draws the stills for the marketing videos (SOC-3): phone frames with a caption,
// title cards, typed terminal and Yui Lines cards, the token benchmark bars and the
// end card. ffmpeg here has no drawtext, so every word is drawn here and
// composited there. One run renders a whole job list:
//
//   swift promo_card.swift jobs.json LOGO.png
//
// jobs.json is an array of {"out", "w", "h", "kind", "layout", ...}; see promo_videos.py.
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let data = FileManager.default.contents(atPath: args[1]),
      let jobs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
    FileHandle.standardError.write("usage: promo_card.swift jobs.json LOGO.png\n".data(using: .utf8)!)
    exit(2)
}
let logoImage = NSImage(contentsOfFile: args[2])?.cgImage(forProposedRect: nil, context: nil, hints: nil)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
let cream = color(0xFFF9F0), ink = color(0x3A3340), soft = color(0x7A7080), coral = color(0xFF7E8A)
let night = color(0x2A2430), paper = color(0xFFFFFF), mint = color(0x9BE3C3), blush = color(0xFFE4E1)

func rounded(_ size: CGFloat, _ weight: NSFont.Weight = .bold) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
}
func mono(_ size: CGFloat, _ weight: NSFont.Weight = .medium) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: size, weight: weight)
}

final class Canvas {
    let W: CGFloat, H: CGFloat
    let rep: NSBitmapImageRep
    let ctx: NSGraphicsContext
    var cg: CGContext { ctx.cgContext }

    init(_ w: CGFloat, _ h: CGFloat) {
        W = w; H = h
        rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(h), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
        ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = ctx
        // Top-left origin, like ffmpeg's overlay coordinates.
        cg.translateBy(x: 0, y: h)
        cg.scaleBy(x: 1, y: -1)
    }

    func fill(_ c: NSColor, _ r: CGRect, radius: CGFloat = 0) {
        c.setFill()
        radius > 0 ? NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill() : r.fill()
    }

    func punch(_ r: CGRect, radius: CGFloat) {
        cg.setBlendMode(.clear)
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
        cg.setBlendMode(.normal)
    }

    func ring(_ r: CGRect, radius: CGFloat) {
        coral.withAlphaComponent(0.55).setStroke()
        let p = NSBezierPath(roundedRect: r.insetBy(dx: -5, dy: -5), xRadius: radius + 5, yRadius: radius + 5)
        p.lineWidth = 6
        p.stroke()
    }

    /// Text drawn upright inside the flipped context. Returns the height it took.
    @discardableResult
    func text(_ s: NSAttributedString, in r: CGRect) -> CGFloat {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        s.draw(with: r, options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
        return ceil(s.boundingRect(with: r.size, options: [.usesLineFragmentOrigin]).height)
    }

    @discardableResult
    func text(_ s: String, in r: CGRect, font: NSFont, color c: NSColor = ink, align: NSTextAlignment = .left,
              spacing: CGFloat = 0.12) -> CGFloat {
        text(NSAttributedString(string: s, attributes: attrs(font, c, align, spacing)), in: r)
    }

    func attrs(_ font: NSFont, _ c: NSColor, _ align: NSTextAlignment, _ spacing: CGFloat = 0.12) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.alignment = align
        p.lineSpacing = font.pointSize * spacing
        return [.font: font, .foregroundColor: c, .paragraphStyle: p]
    }

    func logo(_ r: CGRect, center: Bool = true) {
        guard let img = logoImage else { return }
        let h = r.height, w = h * CGFloat(img.width) / CGFloat(img.height)
        let x = center ? r.minX + (r.width - w) / 2 : r.minX
        cg.saveGState()
        cg.translateBy(x: 0, y: r.minY + h)
        cg.scaleBy(x: 1, y: -1)
        cg.draw(img, in: CGRect(x: x, y: 0, width: w, height: h))
        cg.restoreGState()
    }

    func save(_ path: String) {
        NSGraphicsContext.current = nil
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
}

func num(_ j: [String: Any], _ k: String, _ d: CGFloat = 0) -> CGFloat { (j[k] as? NSNumber).map { CGFloat(truncating: $0) } ?? d }
func str(_ j: [String: Any], _ k: String) -> String { j[k] as? String ?? "" }
func rect(_ j: [String: Any], _ k: String) -> CGRect {
    let a = (j[k] as? [NSNumber] ?? [0, 0, 0, 0]).map { CGFloat(truncating: $0) }
    return CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
}

/// The caption block: a small coral kicker ("Step 2") over the caption.
/// Portrait: centered in `r`. Landscape: left-aligned in `r`.
func caption(_ c: Canvas, _ j: [String: Any], in r: CGRect, portrait: Bool, size: CGFloat) {
    let kicker = str(j, "kicker"), cap = str(j, "caption")
    let align: NSTextAlignment = portrait ? .center : .left
    let s = NSMutableAttributedString()
    if !kicker.isEmpty {
        s.append(NSAttributedString(string: kicker.uppercased() + "\n",
                                    attributes: c.attrs(rounded(size * 0.5, .heavy), coral, align, 0.5)))
    }
    s.append(NSAttributedString(string: cap, attributes: c.attrs(rounded(size, .bold), ink, align)))
    let h = ceil(s.boundingRect(with: r.size, options: [.usesLineFragmentOrigin]).height)
    // Vertically centered in the block.
    c.text(s, in: CGRect(x: r.minX, y: r.minY + max(0, (r.height - h) / 2), width: r.width, height: h + 4))
}

/// Cream canvas, caption and wordmark around a content window at `win`.
func chrome(_ c: Canvas, _ j: [String: Any], win: CGRect, portrait: Bool) {
    c.fill(cream, CGRect(x: 0, y: 0, width: c.W, height: c.H))
    if portrait {
        caption(c, j, in: CGRect(x: 60, y: 40, width: c.W - 120, height: win.minY - 70), portrait: true, size: 64)
        let room = c.H - win.maxY, lh = min(110, room - 100)
        c.logo(CGRect(x: 0, y: win.maxY + (room - lh) / 2, width: c.W, height: lh))
    } else {
        let left = CGRect(x: 110, y: 0, width: win.minX - 200, height: c.H)
        c.logo(CGRect(x: left.minX, y: 110, width: left.width, height: 100), center: false)
        caption(c, j, in: CGRect(x: left.minX, y: 260, width: left.width, height: 560), portrait: false, size: 76)
    }
}

/// A terminal (dark) or Yui Lines (light) window with typed lines.
func console(_ c: Canvas, _ j: [String: Any], win panel: CGRect) {
    let dark = str(j, "style") != "light"
    let lines = j["lines"] as? [String] ?? []
    let typed = Int(num(j, "typed", 100000))
    let r: CGFloat = 36
    // The window fits the finished text (every line, fully typed), centered in the panel.
    let fs = num(j, "font", 40)
    let full = NSMutableAttributedString()
    for (i, line) in (j["all"] as? [String] ?? lines).enumerated() {
        if i > 0 { full.append(NSAttributedString(string: "\n\n", attributes: c.attrs(mono(fs * 0.5), ink, .left))) }
        full.append(NSAttributedString(string: (dark ? "$ " : "") + line + "▍", attributes: c.attrs(mono(fs, .bold), ink, .left, 0.3)))
    }
    let textH = ceil(full.boundingRect(with: CGSize(width: panel.width - 96, height: 4000), options: [.usesLineFragmentOrigin]).height)
    let reserve = CGFloat(num(j, "rows", 0)) * fs * 1.6
    let wh = min(panel.height, max(textH, reserve) + 190)
    let win = CGRect(x: panel.minX, y: panel.minY + (panel.height - wh) / 2, width: panel.width, height: wh)
    c.fill(NSColor.black.withAlphaComponent(0.08), win.offsetBy(dx: 0, dy: 14), radius: r)
    c.fill(dark ? night : paper, win, radius: r)
    // Title bar: three dots and a label.
    for (i, hex) in [0xFF7E8A, 0xFFD27A, 0x9BE3C3].enumerated() {
        c.fill(color(UInt32(hex)), CGRect(x: win.minX + 40 + CGFloat(i) * 40, y: win.minY + 36, width: 22, height: 22), radius: 11)
    }
    c.text(str(j, "title"), in: CGRect(x: win.minX, y: win.minY + 30, width: win.width, height: 40),
           font: rounded(26, .semibold), color: dark ? cream.withAlphaComponent(0.55) : soft, align: .center)
    let body = CGRect(x: win.minX + 48, y: win.minY + 110, width: win.width - 96, height: win.height - 150)
    let s = NSMutableAttributedString()
    let prompt = dark ? "$ " : ""
    for (i, line) in lines.enumerated() {
        let last = i == lines.count - 1
        let shown = last ? String(line.prefix(typed)) : line
        if i > 0 { s.append(NSAttributedString(string: "\n\n", attributes: c.attrs(mono(fs * 0.5), ink, .left))) }
        if line.hasPrefix("#") {
            s.append(NSAttributedString(string: shown, attributes: c.attrs(mono(fs, .regular), dark ? cream.withAlphaComponent(0.5) : soft, .left, 0.3)))
        } else {
            s.append(NSAttributedString(string: prompt, attributes: c.attrs(mono(fs, .bold), coral, .left, 0.3)))
            s.append(NSAttributedString(string: shown, attributes: c.attrs(mono(fs, .medium), dark ? cream : ink, .left, 0.3)))
        }
        if last && j["cursor"] as? Bool ?? true {
            s.append(NSAttributedString(string: "▍", attributes: c.attrs(mono(fs, .regular), coral, .left, 0.3)))
        }
    }
    c.text(s, in: body)
}

func bars(_ c: Canvas, _ j: [String: Any], win: CGRect, portrait: Bool) {
    let rows = j["rows"] as? [[String: Any]] ?? []
    let p = min(1, max(0, num(j, "progress", 1)))
    let maxV = rows.map { num($0, "value") }.max() ?? 1
    c.fill(paper, win, radius: 36)
    let pad: CGFloat = portrait ? 56 : 60
    let inner = win.insetBy(dx: pad, dy: pad)
    c.text(str(j, "title"), in: CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: 60),
           font: rounded(portrait ? 40 : 38, .heavy), color: ink)
    let top = inner.minY + (portrait ? 100 : 90)
    let foot: CGFloat = portrait ? 150 : 110
    let rowH = (inner.maxY - foot - top) / CGFloat(max(1, rows.count))
    for (i, row) in rows.enumerated() {
        let y = top + CGFloat(i) * rowH
        let first = i == 0
        c.text(str(row, "label"), in: CGRect(x: inner.minX, y: y, width: inner.width, height: 50),
               font: rounded(portrait ? 34 : 32, first ? .heavy : .semibold), color: first ? coral : ink)
        let barY = y + (portrait ? 52 : 46), barH: CGFloat = portrait ? 56 : 48
        let full = inner.width - (portrait ? 150 : 170)
        let w = max(barH, full * num(row, "value") / maxV * p)
        c.fill(first ? coral : color(0xE9E1EA), CGRect(x: inner.minX, y: barY, width: w, height: barH), radius: barH / 2)
        let v = Int((num(row, "value") * p).rounded())
        c.text("\(v)", in: CGRect(x: inner.minX + w + 16, y: barY + barH / 2 - 22, width: 160, height: 50),
               font: rounded(portrait ? 34 : 32, .bold), color: first ? coral : ink)
        let note = str(row, "note")
        if !note.isEmpty && p >= 1 {
            c.text(note, in: CGRect(x: inner.minX + 24, y: barY + barH / 2 - 20, width: w - 40, height: 50),
                   font: rounded(portrait ? 30 : 28, .heavy), color: first ? paper : ink, align: .right)
        }
    }
    c.text(str(j, "footnote"), in: CGRect(x: inner.minX, y: inner.maxY - foot + 30, width: inner.width, height: foot),
           font: rounded(portrait ? 26 : 24, .medium), color: soft)
}

for j in jobs {
    let c = Canvas(num(j, "w"), num(j, "h"))
    let portrait = str(j, "layout") != "landscape"
    let win = rect(j, "win")
    switch str(j, "kind") {
    case "frame":
        chrome(c, j, win: win, portrait: portrait)
        c.punch(win, radius: num(j, "radius", 60))
        c.ring(win, radius: num(j, "radius", 60))
    case "console":
        chrome(c, j, win: win, portrait: portrait)
        console(c, j, win: win)
    case "bars":
        chrome(c, j, win: win, portrait: portrait)
        bars(c, j, win: win, portrait: portrait)
    case "title":
        // Big words, centered, with an optional coral line and small line under them.
        c.fill(cream, CGRect(x: 0, y: 0, width: c.W, height: c.H))
        let size = num(j, "size", portrait ? 104 : 112)
        let s = NSMutableAttributedString()
        let pad: CGFloat = portrait ? 90 : 220
        let box = CGRect(x: pad, y: 0, width: c.W - pad * 2, height: c.H)
        s.append(NSAttributedString(string: str(j, "text"), attributes: c.attrs(rounded(size, .heavy), ink, .center, 0.08)))
        if !str(j, "accent").isEmpty {
            s.append(NSAttributedString(string: "\n" + str(j, "accent"), attributes: c.attrs(rounded(size, .heavy), coral, .center, 0.08)))
        }
        if !str(j, "small").isEmpty {
            s.append(NSAttributedString(string: "\n\n" + str(j, "small"), attributes: c.attrs(rounded(size * 0.42, .semibold), soft, .center, 0.2)))
        }
        let h = ceil(s.boundingRect(with: box.size, options: [.usesLineFragmentOrigin]).height)
        c.text(s, in: CGRect(x: box.minX, y: (c.H - h) / 2 - (portrait ? 40 : 10), width: box.width, height: h + 8))
        c.logo(CGRect(x: 0, y: c.H - (portrait ? 230 : 170), width: c.W, height: portrait ? 110 : 90))
    case "end":
        c.fill(cream, CGRect(x: 0, y: 0, width: c.W, height: c.H))
        let lh: CGFloat = portrait ? 330 : 300
        let top = portrait ? c.H * 0.30 : c.H * 0.17
        c.logo(CGRect(x: 0, y: top, width: c.W, height: lh))
        var y = top + lh + (portrait ? 70 : 50)
        y += c.text(str(j, "text"), in: CGRect(x: 80, y: y, width: c.W - 160, height: 300),
                    font: rounded(portrait ? 60 : 58, .bold), color: ink, align: .center) + (portrait ? 50 : 36)
        // The URL on a coral pill.
        let url = NSAttributedString(string: str(j, "url"), attributes: c.attrs(rounded(portrait ? 64 : 60, .heavy), paper, .center))
        let uw = ceil(url.size().width) + 110, uh: CGFloat = portrait ? 130 : 120
        c.fill(coral, CGRect(x: (c.W - uw) / 2, y: y, width: uw, height: uh), radius: uh / 2)
        c.text(url, in: CGRect(x: (c.W - uw) / 2, y: y + (uh - ceil(url.size().height)) / 2, width: uw, height: uh))
        y += uh + (portrait ? 50 : 36)
        c.text(str(j, "small"), in: CGRect(x: 80, y: y, width: c.W - 160, height: 200),
               font: rounded(portrait ? 36 : 34, .semibold), color: soft, align: .center)
    default:
        FileHandle.standardError.write("unknown kind \(str(j, "kind"))\n".data(using: .utf8)!)
        exit(2)
    }
    c.save(str(j, "out"))
}
