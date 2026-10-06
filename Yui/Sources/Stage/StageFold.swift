import SwiftUI
import YuiLines

/// Older stage replies fold into one chip in the chat (pick A, Oct 6: the rest of "chat is home"). A reply that
/// is only pills, nothing to read and nothing to answer, keeps the newest one in place and folds the ones before
/// it, once there are two or more. Tap the chip to open them, tap again to fold. Web twin: `foldStage` in
/// yuigui site/lib/yl/stage.mjs.
enum StageFold {
    /// Staged-only replies it takes before a chip beats the pills.
    static let minFolded = 2

    struct Plan: Equatable {
        /// The row the chip sits at: the oldest folded reply.
        var chipAt: String?
        /// Every folded reply, the chip's own row included.
        var folded: [String] = []
    }

    /// A reply whose whole body is stage pills: no words, no error lines, no look or restyle note.
    static func pillsOnly(_ m: ChatMessage, style: [String: String]) -> Bool {
        guard !m.fromUser, !m.stopped, !m.hello, !m.home, let yl = m.yl, yl.errors.isEmpty, yl.looks.isEmpty,
              yl.restyle == nil, !yl.top.isEmpty else { return false }
        return YLItem.layout(yl.top, pills: style).allSatisfy { if case .pill = $0 { true } else { false } }
    }

    /// Which replies fold. The newest staged-only reply always stays out.
    static func plan(_ messages: [ChatMessage], style: [String: String]) -> Plan {
        let staged = messages.filter { pillsOnly($0, style: style) }.map(\.id)
        guard staged.count > minFolded else { return Plan() }
        let older = Array(staged.dropLast())
        return Plan(chipAt: older.first, folded: older)
    }
}

/// The one chip: "3 earlier screens", a tap opens them in place.
struct StageFoldChip: View {
    let count: Int
    let open: Bool
    let toggle: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        Button(action: toggle) {
            HStack(spacing: theme.spacing.s) {
                Image(systemName: open ? "chevron.up" : "square.stack")
                    .foregroundStyle(c.onAccent)
                    .frame(width: 30, height: 30)
                    .background(c.accent, in: Circle())
                Text(open ? "Fold earlier screens" : "\(count) earlier screens")
                    .font(theme.font(theme.type.body, .bold))
                    .foregroundStyle(c.ink)
                    .lineLimit(1)
            }
            .padding(.leading, theme.spacing.xs)
            .padding(.trailing, theme.spacing.m)
            .padding(.vertical, theme.spacing.xs)
            .background(c.surface, in: Capsule())
            .overlay(Capsule().stroke(c.outline, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("stage-fold-chip")
        .accessibilityLabel(open ? "Fold earlier screens" : "\(count) earlier screens")
        .accessibilityHint(open ? "Hides them" : "Shows them")
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
