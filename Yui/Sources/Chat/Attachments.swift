import Foundation
import SwiftUI
import UIKit
import YuiLines

// Photos from the composer (TestFlight feedback ABEd9FQg0MUy5hNiDKEy13Q).
// They go up to `yui-media` under from=user first, then ride an ordinary text
// row: body = the caption (or "Photo"), meta = {"photos": [bucket path, ...]}.
// The host plugin already fetches any user path it finds in a row's meta
// (hermes-plugin/yui/media.py `localize`), so the agent gets a photo message.

/// A picture on a person's bubble: still on the phone, or in the bucket.
enum MessagePhoto: Equatable {
    case local(UIImage)
    case stored(String)
}

/// A photo waiting in the composer, already shrunk to what we send.
struct ComposerPhoto: Identifiable, Equatable {
    let id = UUID()
    let jpeg: Data
    let preview: UIImage

    init?(_ data: Data) {
        // The preview is drawn at 200 pt at most: decoded that small, not at the 2048 px sent (YUI-100).
        guard let jpeg = YuiMedia.jpeg(data),
              let preview = Pictures.downsample(jpeg, points: CGSize(width: 200, height: 200), scale: 3) else { return nil }
        self.jpeg = jpeg
        self.preview = preview
    }
}

enum Attachments {
    /// Most photos one message carries. It is not ours to fix: the server's `yui_limits` row `photos_per_message`
    /// (the lowest per-request image cap of Claude, OpenAI and Gemini, so any agent takes the whole send in one call)
    /// is read on each thread open and kept here, so it moves without a build. Until it has been read once, 20.
    nonisolated(unsafe) private(set) static var maxPhotos: Int = {
        let kept = UserDefaults.standard.integer(forKey: limitKey)
        return kept >= 1 ? kept : fallbackLimit
    }()
    static let fallbackLimit = 20
    private static let limitKey = "yuiPhotosPerMessage"

    /// `[{"value": 100}]`, what PostgREST answers for the limit; nil when it is not a whole number of 1 or more.
    static func limit(from data: Data) -> Int? {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let value = (rows.first?["value"] as? NSNumber)?.doubleValue, value >= 1, value <= 10_000 else { return nil }
        return Int(value)
    }

    /// Reads the limit from the server and keeps it. A failed read leaves the last one in place.
    @MainActor static func refreshLimit(_ account: Account) async {
        var c = URLComponents(url: YuiBackend.url.appending(path: "rest/v1/yui_limits"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "select", value: "value"), URLQueryItem(name: "name", value: "eq.photos_per_message")]
        guard let data = try? await YuiRelay.data(account, URLRequest(url: c.url!)), let n = limit(from: data) else { return }
        maxPhotos = n
        UserDefaults.standard.set(n, forKey: limitKey)
    }

    /// The row's body: the words, or a stand-in when there are only photos (body is never empty).
    static func body(text: String, photos: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty || photos == 0 { return t }
        return placeholder(photos)
    }

    static func placeholder(_ photos: Int) -> String { photos == 1 ? "Photo" : "\(photos) photos" }

    /// The row's meta for these bucket paths. nil with none: a plain text row stays as it was.
    static func meta(paths: [String]) -> YLValue? {
        paths.isEmpty ? nil : .object(["photos": .array(paths.map { .string($0) })])
    }

    /// The bucket paths a person's row carries. Only our own user paths count.
    static func paths(_ meta: YLValue?) -> [String] {
        guard case .array(let items)? = meta?.object?["photos"] else { return [] }
        return items.compactMap(\.string).filter(isUserPath)
    }

    /// The words to show on the bubble: the stand-in body draws as the photos alone.
    static func caption(body: String, photos: Int) -> String {
        photos > 0 && body == placeholder(photos) ? "" : body
    }

    /// `<user>/<agent>/user/<file>`, the shape the host plugin looks for.
    static func isUserPath(_ p: String) -> Bool {
        p.range(of: #"^[0-9a-f-]{36}/[0-9a-f-]{36}/user/[A-Za-z0-9._-]{1,80}$"#, options: .regularExpression) != nil
    }
}

/// One photo on a bubble. Stored ones are signed with the person's own token.
struct BubblePhoto: View {
    let photo: MessagePhoto
    @State private var url: URL?
    @Environment(\.yuiMedia) private var media
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        // The photo's own shape, 220 wide, never cropped (AM6xGDZ3).
        Group {
            switch photo {
            case .local(let image):
                RatioBox(ratio: image.size.height > 0 ? image.size.width / image.size.height : 1, maxHeight: 320) {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                }
            case .stored(let path):
                if let url {
                    WholeImage(src: url, maxHeight: 320)
                } else {
                    s.surface.overlay(ProgressView().tint(s.accent))
                        .frame(height: 220)
                        .task(id: path) { url = await media?.link(path: path) }
                }
            }
        }
        .frame(width: 220)
        .clipShape(.rect(cornerRadius: theme.radius.bubble))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Photo")
        .accessibilityAddTraits(.isImage)
        .accessibilityIdentifier("bubble-photo")
    }
}
