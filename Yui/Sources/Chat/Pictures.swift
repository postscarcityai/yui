import ImageIO
import SwiftUI
import UIKit

// Pictures kept small (YUI-100). A picture is decoded at the size it is drawn, not
// the size it was sent at, and the decoded copies share one cache with a byte limit
// that empties on a memory warning. AsyncImage kept every render at full resolution
// for as long as its row lived.

enum Pictures {
    /// Decoded bytes kept for pictures that scrolled away. Past this, the oldest go.
    nonisolated static let budget = 48 << 20

    /// The largest side, in pixels, the picture needs to fill `points` at `scale`.
    /// Pictures are only ever made smaller.
    nonisolated static func maxPixels(width: CGFloat, height: CGFloat, points: CGSize, scale: CGFloat) -> CGFloat {
        guard width > 0, height > 0 else { return max(points.width, points.height) * scale }
        let need = max(points.width * scale / width, points.height * scale / height)
        return max(width, height) * min(1, need)
    }

    /// `data` decoded to at most what `points` needs, EXIF turned upright.
    nonisolated static func downsample(_ data: Data, points: CGSize, scale: CGFloat) -> UIImage? {
        downsampled(data, points: points, scale: scale)?.image
    }

    /// The same, and whether that is the whole picture (no bigger frame needs a new decode).
    nonisolated static func downsampled(_ data: Data, points: CGSize, scale: CGFloat) -> (image: UIImage, whole: Bool)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        var w: CGFloat = 0, h: CGFloat = 0
        if let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            w = (p[kCGImagePropertyPixelWidth] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
            h = (p[kCGImagePropertyPixelHeight] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
            // Orientations 5 to 8 are turned a quarter: the sides swap once upright.
            if let o = p[kCGImagePropertyOrientation] as? NSNumber, o.intValue >= 5 { swap(&w, &h) }
        }
        let side = maxPixels(width: w, height: h, points: points, scale: scale)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(side.rounded(.up))),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return (UIImage(cgImage: cg), w > 0 && side >= max(w, h) - 1)
    }

    /// Enough pixels for `points` at `scale`: fill has to cover both sides, fit either one.
    static func sharp(_ image: UIImage, _ points: CGSize, scale: CGFloat, fill: Bool) -> Bool {
        let px = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let w = px.width >= points.width * scale - 1, h = px.height >= points.height * scale - 1
        return fill ? w && h : w || h
    }

    /// A picture's decoded size in bytes: what it costs in the cache.
    nonisolated static func cost(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        return cg.bytesPerRow * cg.height
    }

    /// The same picture at a similar size shares one entry: sides step by 256 px.
    static func key(_ id: String, _ side: CGFloat) -> NSString {
        "\(id)@\(Int((side / 256).rounded(.up)) * 256)" as NSString
    }

    private final class Entry {
        let image: UIImage, whole: Bool
        init(_ image: UIImage, _ whole: Bool) { self.image = image; self.whole = whole }
    }
    nonisolated(unsafe) private static let entries: NSCache<NSString, Entry> = {
        let c = NSCache<NSString, Entry>()
        c.totalCostLimit = budget
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: .main) { _ in Pictures.empty() }
        return c
    }()
    static func empty() { entries.removeAllObjects() }

    /// Fetches, downsamples off the main thread and caches. `id` stays the same when
    /// a signed link is signed again, so a new link is not a new picture.
    static func load(_ url: URL, id: String, points: CGSize, scale: CGFloat) async -> (image: UIImage, whole: Bool)? {
        let key = key(id, max(points.width, points.height) * scale)
        if let hit = entries.object(forKey: key) { return (hit.image, hit.whole) }
        // The whole picture, already decoded for another frame, fits this one too.
        if let whole = entries.object(forKey: "\(id)@whole" as NSString) { return (whole.image, true) }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
        guard let made = await Task.detached(priority: .userInitiated, operation: { downsampled(data, points: points, scale: scale) }).value
        else { return nil }
        entries.setObject(Entry(made.image, made.whole), forKey: made.whole ? "\(id)@whole" as NSString : key, cost: cost(made.image))
        return made
    }
}
