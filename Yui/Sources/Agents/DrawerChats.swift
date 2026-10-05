import SwiftUI

// The drawer's chats (YUI-169, spec yuigui/spec/CHATS.md sections 2 to 4, the approved mock):
// New chat, then the list, newest activity first. A row says its title, then the last line
// said and when; a coral dot when the agent said something you have not read; a soft coral
// fill on the open one. Hold a row, or swipe it left, for Rename and Delete. Delete asks first.

struct DrawerChats: View {
    let store: ChatStore
    /// Starts a new chat and takes the person to it: the drawer closes.
    let newChat: () -> Void
    /// A chat from the list: the drawer closes and it is up.
    let openChat: (String) -> Void
    @State private var renaming: String?
    @State private var title = ""
    @State private var deleting: ChatInfo?
    @State private var query = ""
    @FocusState private var typing: Bool
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private var name: String { store.agent?.name ?? "Yui" }

    var body: some View {
        let c = theme.swatch(scheme)
        let chats = store.chats
        let rows = Chats.filter(chats.items, agent: name, query: query)
        VStack(alignment: .leading, spacing: 0) {
            Button(action: newChat) {
                Label("New chat", systemImage: "plus")
                    .font(theme.font(theme.type.body, .heavy))
                    .foregroundStyle(c.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(c.accent, in: .rect(cornerRadius: 16))
                    .contentShape(.rect(cornerRadius: 16))
            }
            .buttonStyle(BounceButtonStyle())
            .accessibilityIdentifier("drawer-new-chat")
            .padding(.top, theme.spacing.xs)

            if !chats.items.isEmpty {
                DrawerHeading(text: "Chats")
                if chats.items.count > Chats.searchAfter { search(c) }
                VStack(spacing: 2) {
                    ForEach(rows) { chat in row(chat, c) }
                    if chats.more, query.isEmpty {
                        // The list shows the newest 30 and loads more as you scroll.
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(theme.spacing.m)
                            .task { await store.loadMoreChats() }
                    }
                    if rows.isEmpty {
                        Text("No chats match.")
                            .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                            .padding(theme.spacing.m)
                    }
                }
                .accessibilityIdentifier("drawer-chats")
            }
            if let note = chats.note {
                Label(note, systemImage: "info.circle")
                    .font(theme.font(theme.type.caption, .semibold)).foregroundStyle(c.inkSoft)
                    .padding(.top, theme.spacing.s)
                    .accessibilityIdentifier("drawer-chats-note")
            }
        }
        // Delete asks first (spec section 4): a sheet, Delete in red and Keep it. Nothing else in the app asks.
        .sheet(item: $deleting) { chat in
            let words = Chats.sheet(for: store.deletePlan, title: Chats.title(chat, agent: name, among: store.chats.savedCount), agent: name)
            ChatDeleteSheet(question: words.question, note: words.note, confirm: words.confirm) {
                deleting = nil
                Task { await store.deleteChat(chat.id) }
            } keep: {
                deleting = nil
            }
            .presentationDetents([.height(300)])
            .presentationCornerRadius(28)
        }
    }

    private func search(_ c: Swatch) -> some View {
        HStack(spacing: theme.spacing.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(c.inkSoft)
            TextField("Search chats", text: $query)
                .font(theme.font(theme.type.body))
                .foregroundStyle(c.ink)
                .submitLabel(.search)
                .accessibilityIdentifier("drawer-chat-search")
            if !query.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly).foregroundStyle(c.inkSoft)
            }
            NameMic(text: $query, id: "drawer-chat-search-mic", label: "Say what to search")
                .padding(.vertical, -6)
        }
        .padding(.horizontal, theme.spacing.m).padding(.vertical, 10)
        .background(c.surface, in: Capsule())
        .overlay(Capsule().stroke(c.outline, lineWidth: 1))
        .padding(.bottom, theme.spacing.xs)
    }

    // MARK: A row

    private func row(_ chat: ChatInfo, _ c: Swatch) -> some View {
        let open = chat.id == store.chats.openID
        let label = Chats.title(chat, agent: name, among: store.chats.savedCount)
        return ScrollView(.horizontal) {
            HStack(spacing: 0) {
                Group {
                    if renaming == chat.id { rename(chat, c) } else { content(chat, label: label, open: open, c) }
                }
                .containerRelativeFrame(.horizontal)
                actions(chat, c)
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .scrollDisabled(renaming == chat.id)
        .background(open ? c.accent.opacity(0.18) : .clear, in: .rect(cornerRadius: 16))
        .contextMenu {
            Button("Rename", systemImage: "pencil") { startRename(chat, label) }
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = chat }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("drawer-chat-\(chat.id)")
    }

    private func content(_ chat: ChatInfo, label: String, open: Bool, _ c: Swatch) -> some View {
        let line = Chats.lastLine(chat)
        return Button { openChat(chat.id) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(label)
                        .font(theme.font(theme.type.body, .heavy)).foregroundStyle(c.ink)
                        .lineLimit(1)
                    if chat.unread {
                        Circle().fill(c.accent).frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: theme.spacing.s) {
                    Text(line.isEmpty ? "Nothing said yet" : line)
                        .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(Chats.when(chat))
                        .font(theme.font(theme.type.caption)).foregroundStyle(c.inkSoft)
                }
            }
            .padding(.horizontal, theme.spacing.m).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label). \(line.isEmpty ? "Nothing said yet" : line). \(Chats.when(chat))\(chat.unread ? ". New reply" : "")")
        .accessibilityAddTraits(open ? .isSelected : [])
        .accessibilityIdentifier("drawer-chat-open-\(chat.id)")
    }

    private func rename(_ chat: ChatInfo, _ c: Swatch) -> some View {
        HStack(spacing: theme.spacing.xs) {
            TextField("Chat title", text: $title)
                .font(theme.font(theme.type.body, .heavy)).foregroundStyle(c.ink)
                .focused($typing)
                .submitLabel(.done)
                .onSubmit { finishRename(chat) }
                .onChange(of: title) { if title.count > Chats.titleMax { title = String(title.prefix(Chats.titleMax)) } }
                .onChange(of: typing) { was, now in if was, !now, renaming == chat.id { finishRename(chat) } }
                .accessibilityIdentifier("chat-rename-field")
            NameMic(text: $title, id: "chat-rename-mic", label: "Say the chat title")
                .padding(.vertical, -6)
        }
            .padding(.leading, theme.spacing.m).padding(.trailing, theme.spacing.xs)
            .frame(height: 44)
            .background(c.surface, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(c.accent, lineWidth: 2))
            .padding(.horizontal, theme.spacing.xs).padding(.vertical, 6)
    }

    /// Swiped left: Rename and Delete, behind the row.
    private func actions(_ chat: ChatInfo, _ c: Swatch) -> some View {
        HStack(spacing: 6) {
            Button { startRename(chat, Chats.title(chat, agent: name, among: store.chats.savedCount)) } label: {
                Image(systemName: "pencil")
                    .font(theme.font(16, .bold)).foregroundStyle(c.ink)
                    .frame(width: 52, height: 52)
                    .background(c.surface, in: Circle())
                    .overlay(Circle().stroke(c.outline, lineWidth: 1))
            }
            .accessibilityLabel("Rename chat")
            .accessibilityIdentifier("chat-rename-\(chat.id)")
            Button { deleting = chat } label: {
                Image(systemName: "trash")
                    .font(theme.font(16, .bold)).foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Color(red: 0.90, green: 0.28, blue: 0.30), in: Circle())
            }
            .accessibilityLabel(store.deletePlan == .clear ? "Clear chat" : "Delete chat")
            .accessibilityIdentifier("chat-delete-\(chat.id)")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
    }

    private func startRename(_ chat: ChatInfo, _ current: String) {
        title = current
        renaming = chat.id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            typing = true
        }
    }

    private func finishRename(_ chat: ChatInfo) {
        guard renaming == chat.id else { return }
        renaming = nil
        typing = false
        if Chats.validTitle(title) != nil, Chats.validTitle(title) != Chats.title(chat, agent: name, among: store.chats.savedCount) {
            store.renameChat(chat.id, to: title)
        }
    }
}


/// "Delete 'Tuesday's groceries'?" and what goes with it: Delete in red, Keep it beside it.
private struct ChatDeleteSheet: View {
    let question: String
    let note: String
    let confirm: String
    let go: () -> Void
    let keep: () -> Void
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = theme.swatch(scheme)
        VStack(alignment: .leading, spacing: theme.spacing.m) {
            Text(question)
                .font(theme.font(theme.type.title, .heavy)).foregroundStyle(c.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(note)
                .font(theme.font(theme.type.body)).foregroundStyle(c.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: go) {
                Text(confirm)
                    .font(theme.font(theme.type.body, .heavy)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Color(red: 0.90, green: 0.28, blue: 0.30), in: .rect(cornerRadius: 18))
                    .contentShape(.rect(cornerRadius: 18))
            }
            .buttonStyle(BounceButtonStyle())
            .accessibilityIdentifier("chat-sheet-delete")
            Button(action: keep) {
                Text("Keep it")
                    .font(theme.font(theme.type.body, .heavy)).foregroundStyle(c.ink)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(c.surface, in: .rect(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(c.outline, lineWidth: 1))
                    .contentShape(.rect(cornerRadius: 18))
            }
            .buttonStyle(BounceButtonStyle())
            .accessibilityIdentifier("chat-sheet-keep")
        }
        .padding(theme.spacing.l)
        .padding(.top, theme.spacing.s)
        .background(c.background.ignoresSafeArea())
    }
}
