import SwiftUI

/// When each message was sent (YUI-202). Chris, TestFlight AB6Bae6I: "I don't even know when
/// this was sent ... group them by day, so I can understand where I'm at in the timeline in
/// actual time." A day divider where the day changes, a quiet time under each run of messages.
enum SentTimes {
    struct Marks: Equatable {
        /// Message id -> the divider drawn above it.
        var day: [String: String] = [:]
        /// Message id -> the time drawn under it (the last of a run).
        var time: [String: String] = [:]
    }

    /// Messages closer than this, from the same side, are one run and share a time.
    static let run: TimeInterval = 5 * 60

    static func marks(_ messages: [ChatMessage], now: Date = .now, calendar: Calendar = .current) -> Marks {
        let list = messages.filter { !$0.stopped }
        var out = Marks()
        for (i, m) in list.enumerated() {
            let before = i > 0 ? list[i - 1] : nil
            if before == nil || !calendar.isDate(before!.sentAt, inSameDayAs: m.sentAt) {
                out.day[m.id] = dayLabel(m.sentAt, now: now, calendar: calendar)
            }
            let after = i + 1 < list.count ? list[i + 1] : nil
            let continues = after.map {
                $0.fromUser == m.fromUser && calendar.isDate($0.sentAt, inSameDayAs: m.sentAt)
                    && $0.sentAt.timeIntervalSince(m.sentAt) < run
            } ?? false
            if !continues { out.time[m.id] = clock(m.sentAt) }
        }
        return out
    }

    /// Today, Yesterday, Mon 28 Sep (the year too when it is not this one).
    static func dayLabel(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "Yesterday" }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate(calendar.isDate(date, equalTo: now, toGranularity: .year) ? "EEEdMMM" : "EEEdMMMy")
        return f.string(from: date)
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// One line for the full screen: "Today, 11:30 AM".
    static func stamp(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        "\(dayLabel(date, now: now, calendar: calendar)), \(clock(date))"
    }
}

/// The day changes here: a quiet label between two hairlines.
struct DayDivider: View {
    let label: String
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        HStack(spacing: theme.spacing.s) {
            Rectangle().fill(c.outline).frame(height: 1)
            Text(label)
                .font(theme.font(theme.type.caption, .semibold))
                .foregroundStyle(c.inkSoft)
                .fixedSize()
            Rectangle().fill(c.outline).frame(height: 1)
        }
        .padding(.top, theme.spacing.s)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityIdentifier("day-divider")
    }
}

/// When the run above it was sent, on the side it came from.
struct SentTime: View {
    let text: String
    let fromUser: Bool
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(text)
            .font(theme.font(theme.type.caption, .regular))
            .foregroundStyle(theme.swatch(scheme).inkSoft)
            .frame(maxWidth: .infinity, alignment: fromUser ? .trailing : .leading)
            .padding(.horizontal, theme.spacing.xs)
            .accessibilityIdentifier("sent-time")
    }
}
