// Stamps a "DEV" band on the app icon for test builds by link (YUI-91), so
// Yui Dev and TestFlight Yui are easy to tell apart on the home screen.
// Called by scripts/devbuild.sh on the worktree's copy, never the repo's.
//
//   swift scripts/devbuild_icon.swift <icon-1024.png>   (rewrites it in place)
import AppKit

let path = CommandLine.arguments[1]
guard let src = NSImage(contentsOfFile: path),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
    exit(1)
}
let w = cg.width, h = cg.height
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

// A dark band across the bottom, under the wordmark.
let band = CGRect(x: 0, y: CGFloat(h) * 0.05, width: CGFloat(w), height: CGFloat(h) * 0.2)
ctx.setFillColor(CGColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 0.92))
ctx.fill(band)

NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
let font = NSFont.systemFont(ofSize: band.height * 0.62, weight: .heavy)
let text = NSAttributedString(string: "DEV", attributes: [
    .font: font,
    .foregroundColor: NSColor.white,
    .kern: band.height * 0.06,
])
let size = text.size()
text.draw(at: CGPoint(x: (CGFloat(w) - size.width) / 2, y: band.midY - size.height / 2))

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
