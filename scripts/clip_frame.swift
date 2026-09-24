// Draws the overlay for a demo clip (SOC-2): cream canvas, caption, wordmark,
// and a transparent rounded window where the simulator video shows through.
// ffmpeg here has no drawtext, so text is rendered here and composited there.
//
//   swift clip_frame.swift OUT.png W H winX winY winW winH radius CAPTION LOGO.png portrait|landscape
import AppKit

let a = CommandLine.arguments
guard a.count == 12 else {
    FileHandle.standardError.write("usage: clip_frame.swift OUT W H x y w h r CAPTION LOGO layout\n".data(using: .utf8)!)
    exit(2)
}
let (out, W, H) = (a[1], CGFloat(Double(a[2])!), CGFloat(Double(a[3])!))
let win = CGRect(x: Double(a[4])!, y: Double(a[5])!, width: Double(a[6])!, height: Double(a[7])!)
let radius = CGFloat(Double(a[8])!)
let (caption, logoPath, portrait) = (a[9], a[10], a[11] == "portrait")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
let cream = color(0xFFF9F0), ink = color(0x3A3340), coral = color(0xFF7E8A)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
// Top-left origin, like ffmpeg's overlay coordinates.
ctx.cgContext.translateBy(x: 0, y: H)
ctx.cgContext.scaleBy(x: 1, y: -1)

// Canvas with the window punched out.
cream.setFill()
CGRect(x: 0, y: 0, width: W, height: H).fill()
ctx.cgContext.setBlendMode(.clear)
NSBezierPath(roundedRect: win, xRadius: radius, yRadius: radius).fill()
ctx.cgContext.setBlendMode(.normal)
// A soft coral outline around the phone.
coral.withAlphaComponent(0.55).setStroke()
let ring = NSBezierPath(roundedRect: win.insetBy(dx: -5, dy: -5), xRadius: radius + 5, yRadius: radius + 5)
ring.lineWidth = 6
ring.stroke()

func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
}

// Text draws upright inside the flipped context.
func draw(_ text: String, in rect: CGRect, size: CGFloat, align: NSTextAlignment) {
    let p = NSMutableParagraphStyle()
    p.alignment = align
    p.lineSpacing = size * 0.12
    let s = NSAttributedString(string: text, attributes: [.font: rounded(size, .bold), .foregroundColor: ink,
                                                          .paragraphStyle: p])
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx.cgContext, flipped: true)
    s.draw(with: rect, options: [.usesLineFragmentOrigin])
    NSGraphicsContext.restoreGraphicsState()
}

func logo(_ rect: CGRect, left: Bool = false) {
    guard let img = NSImage(contentsOfFile: logoPath), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { return }
    let h = rect.height, w = h * CGFloat(cg.width) / CGFloat(cg.height)
    let x = left ? rect.minX : rect.minX + (rect.width - w) / 2
    // The image is upright in a flipped context: flip it back locally.
    ctx.cgContext.saveGState()
    ctx.cgContext.translateBy(x: 0, y: rect.minY + h)
    ctx.cgContext.scaleBy(x: 1, y: -1)
    ctx.cgContext.draw(cg, in: CGRect(x: x, y: 0, width: w, height: h))
    ctx.cgContext.restoreGState()
}

if portrait {
    draw(caption, in: CGRect(x: 70, y: 70, width: W - 140, height: win.minY - 100), size: 62, align: .center)
    logo(CGRect(x: 0, y: win.maxY + 45, width: W, height: H - win.maxY - 90))
} else {
    let left = CGRect(x: 110, y: 0, width: win.minX - 200, height: H)
    logo(CGRect(x: left.minX, y: 300, width: left.width, height: 110), left: true)
    draw(caption, in: CGRect(x: left.minX, y: 470, width: left.width, height: 420), size: 72, align: .left)
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
