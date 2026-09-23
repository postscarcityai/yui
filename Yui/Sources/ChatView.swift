import SwiftUI

/// Phase 1 shell: the chat screen every agent starts from.
/// Presets render inline here once the Yui Lines parser lands.
struct ChatView: View {
    @State private var draft = ""
    @State private var messages: [String] = ["Yui is alive. Agents connect in Phase 1."]

    var body: some View {
        NavigationStack {
            List(messages, id: \.self) { Text($0) }
                .listStyle(.plain)
                .navigationTitle("Yui")
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        TextField("Message", text: $draft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(send)
                        Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                            .labelStyle(.iconOnly)
                            .font(.title2)
                            .disabled(draft.isEmpty)
                    }
                    .padding()
                    .background(.bar)
                }
        }
    }

    private func send() {
        guard !draft.isEmpty else { return }
        messages.append(draft)
        draft = ""
    }
}
