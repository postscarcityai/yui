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
    /// Most photos one message carries. Keeps a send quick on a phone connection.
    static let maxPhotos = 4

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
        Group {
            switch photo {
            case .local(let image):
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            case .stored(let path):
                if let url {
                    RemoteImage(src: url)
                } else {
                    s.surface.overlay(ProgressView().tint(s.accent))
                        .task(id: path) { url = await media?.link(path: path) }
                }
            }
        }
        .frame(width: 200, height: 200)
        .clipShape(.rect(cornerRadius: theme.radius.bubble))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Photo")
        .accessibilityAddTraits(.isImage)
        .accessibilityIdentifier("bubble-photo")
    }
}
