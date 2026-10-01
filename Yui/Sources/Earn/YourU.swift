import SwiftUI

/// The pill in the drawer's top right: the coin and the number. Fades to green while the number climbs.
struct UPill: View {
    let earn: EarnStore
    let reduceMotion: Bool
    let tap: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        Button(action: tap) {
            HStack(spacing: 6) {
                UCoin(size: 20)
                Text(earn.shown.formatted(.number.locale(Locale(identifier: "en_US"))))
                    .font(theme.font(15, .bold)).monospacedDigit()
                    .foregroundStyle(c.ink)
                    .contentTransition(.identity)
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background {
                Capsule().fill(c.surface)
                Capsule().fill(Color(red: 0.22, green: 0.72, blue: 0.42).opacity(scheme == .dark ? 0.45 : 0.32))
                    .opacity(earn.climbing ? 1 : 0)
            }
            .overlay(Capsule().stroke(c.outline, lineWidth: 1))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: earn.climbing)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Your U")
        .accessibilityValue("\(earn.shown)")
        .accessibilityIdentifier("drawer-u")
    }
}

/// Your $U (YUI-210): total, today against the soft cap, streak, per-day history, how it adds up.
struct YourUView: View {
    let earn: EarnStore
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let c = theme.swatch(scheme)
        let s = earn.summary
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.spacing.l) {
                    HStack(spacing: 10) {
                        UCoin(size: 38)
                        Text(s.total.formatted(.number.locale(Locale(identifier: "en_US"))))
                            .font(theme.font(44, theme.strong)).monospacedDigit().foregroundStyle(c.ink)
                            .accessibilityIdentifier("u-total")
                    }
                    card(c) {
                        row(c, "Today", "\(s.today) of \(s.softCap)")
                        ProgressView(value: Double(min(s.today, s.softCap)), total: Double(max(s.softCap, 1)))
                            .tint(c.accent)
                        Text("After \(s.softCap) a day, each one counts a tenth.").font(theme.font(13, .regular)).foregroundStyle(c.inkSoft)
                    }
                    card(c) {
                        row(c, "Streak", s.streak == 0 ? "None yet" : "\(s.streak) days")
                        row(c, "Speed", "x\(s.mult.formatted(.number.precision(.fractionLength(0...2))))")
                    }
                    if !s.built.isEmpty {
                        section(c, "You helped build") {
                            ForEach(s.built) { b in row(c, EarnSummary.shortDay(b.day), b.words) }
                        }
                    }
                    section(c, "Each day") {
                        if s.days.isEmpty { Text("Use Yui and it shows up here.").foregroundStyle(c.inkSoft) }
                        ForEach(s.days) { d in
                            row(c, EarnSummary.shortDay(d.day), "\(d.messages) messages, \(d.screens) screens, \(d.jobs) jobs, +\(d.earned)")
                        }
                    }
                    section(c, "How it adds up") {
                        table(c, [("A message", "1"), ("A screen you answer", "2"), ("A job finished", "5"), ("First visit of a day", "10")])
                        table(c, [("3 days in a row", "x1.1"), ("7 days in a row", "x1.25 and +50"), ("30 days in a row", "x1.5 and +300")])
                        table(c, [("Feedback sent", "10"), ("Feedback shipped", "500"), ("Idea accepted", "200"), ("Idea shipped", "500"),
                                  ("Code added, small", "1,000"), ("medium", "3,000"), ("large", "10,000")])
                    }
                    Text("No cash value. Not a token yet.").font(theme.font(13, .bold)).foregroundStyle(c.inkSoft)
                        .accessibilityIdentifier("u-note")
                }
                .padding(theme.spacing.l)
            }
            .background(c.background)
            .navigationTitle("Your U").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private func card<V: View>(_ c: Swatch, @ViewBuilder _ body: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 10, content: body)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(c.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(c.outline, lineWidth: 1))
    }

    private func section<V: View>(_ c: Swatch, _ title: String, @ViewBuilder _ body: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(theme.font(17, .bold)).foregroundStyle(c.ink).accessibilityAddTraits(.isHeader)
            card(c, body)
        }
    }

    private func row(_ c: Swatch, _ l: String, _ r: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(l).font(theme.font(15, .regular)).foregroundStyle(c.inkSoft)
            Spacer(minLength: 12)
            Text(r).font(theme.font(15, .bold)).foregroundStyle(c.ink).multilineTextAlignment(.trailing)
        }
    }

    private func table(_ c: Swatch, _ rows: [(String, String)]) -> some View {
        VStack(spacing: 6) { ForEach(rows, id: \.0) { row(c, $0.0, $0.1) } }
            .padding(.bottom, 6)
    }
}
