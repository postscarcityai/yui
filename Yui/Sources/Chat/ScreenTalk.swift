import Foundation
import SwiftUI
import YuiLines

// Chat with a screen (YUI-62, spec yuigui/spec/YL.md section 5 "Pages" and
// section 7). A page is for reading and tapping, unless the agent keeps the
// composer on it with `>2 talk` (`>2 talk off` or `>2 clear` takes it away).
// What the person types there is one ordinary text row in this thread:
//   body  [yui] screen=2
//         <the words>
//   meta  {"screen": "2"}
// The agent reads the first line and knows which screen the words are about.
// The bubble lands in the chat with a "From screen 2" chip that goes back there.

enum ScreenTalk {
    /// `[yui] screen=2` then the words.
    static func body(_ words: String, screen: Int) -> String {
        YuiLines.typedBody(screen: String(screen), words: words)
    }

    static func meta(_ base: YLValue?, screen: Int) -> YLValue {
        var o = base?.object ?? [:]
        o["screen"] = .string(String(screen))
        return .object(o)
    }

    /// The page a person's row was typed on, if it was typed on one.
    static func screen(meta: YLValue?) -> Int? {
        guard let s = meta?.object?["screen"]?.string else { return nil }
        let n = YuiLines.page(of: s)
        return n == 1 ? nil : n
    }

    /// The bubble's words: the screen line comes off.
    static func words(body: String, meta: YLValue?) -> String {
        guard screen(meta: meta) != nil, let typed = YuiLines.readTyped(body) else { return body }
        return typed.words
    }
}

/// Over a message typed on a screen: where it came from, and a way back there.
struct ScreenChip: View {
    let screen: Int
    @Environment(\.ylPage) private var go
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        Button { go(screen) } label: {
            Label("From screen \(screen)", systemImage: "rectangle.portrait.on.rectangle.portrait")
                .font(theme.font(theme.type.caption, .bold))
                .foregroundStyle(c.inkSoft)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Goes to screen \(screen)")
        .accessibilityIdentifier("screen-chip")
    }
}
