import SwiftUI
import YuiLines

/// Debug box: paste Yui Lines, see what parses, stream it into the chat as an agent reply.
struct PasteYLView: View {
    let store: ChatStore
    @State private var text = YLSamples.all[0].text
    @Environment(\.dismiss) private var dismiss
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = theme.swatch(scheme)
        let nodes = YuiLines.parse(text)
        let bad = nodes.filter { $0.op == .error }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.spacing.l) {
                    FlowLayout(spacing: theme.spacing.s) {
                        ForEach(Array(YLSamples.all.enumerated()), id: \.offset) { i, sample in
                            OptionPill(text: sample.name, fill: s.candy[i % 4], on: text == sample.text) {
                                text = sample.text
                            }
                        }
                    }
                    TextEditor(text: $text)
                        .font(.system(size: theme.type.caption + 1, design: .monospaced))
                        .foregroundStyle(s.ink)
                        .scrollContentBackground(.hidden)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(minHeight: 180)
                        .padding(theme.spacing.m)
                        .background(s.surface, in: .rect(cornerRadius: theme.radius.bubble))
                        .overlay(RoundedRectangle(cornerRadius: theme.radius.bubble).stroke(s.outline, lineWidth: 1.5))
                    Text("\(nodes.count - bad.count) lines parsed, \(bad.count) errors")
                        .font(theme.font(theme.type.caption, .bold))
                        .foregroundStyle(s.inkSoft)
                    ForEach(Array(bad.enumerated()), id: \.offset) { YLErrorRow(node: $1) }
                    OptionPill(text: "Send to chat", fill: s.accent, on: !nodes.isEmpty, grow: true) {
                        store.stream(text)
                        dismiss()
                    }
                    .disabled(nodes.isEmpty)
                    if !store.events.isEmpty {
                        Text("Events back to the agent")
                            .font(theme.font(theme.type.caption, .heavy))
                            .foregroundStyle(s.inkSoft)
                        ForEach(Array(store.events.prefix(12).enumerated()), id: \.offset) { _, e in
                            Text(e.json)
                                .font(.system(size: theme.type.caption, design: .monospaced))
                                .foregroundStyle(s.ink)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(theme.spacing.l)
            }
            .background(s.background)
            .navigationTitle("Paste YL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() }.tint(s.accent) }
            }
        }
    }
}
