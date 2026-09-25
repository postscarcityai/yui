import SwiftUI

/// INT-19: an MCP client (Claude, ChatGPT, Cursor) asks to connect through
/// OAuth. Its sign-in page (www.yuigui.com/connect/<id>) hands off here with
/// `yui://connect/<id>` (same phone) or the universal link
/// `https://www.yuigui.com/a/<id>` (a QR scanned from a computer). The person
/// picks which agent the client talks as, a new one named after it or one it
/// already had, and taps Allow. The page sees the approval and finishes the
/// sign-in; the client never gets more than that one thread.
struct ConnectRequestID: Identifiable, Equatable {
    let id: String

    /// `yui://connect/<uuid>` or `https://www.yuigui.com/a/<uuid>`.
    static func parse(_ url: URL) -> ConnectRequestID? {
        let parts = url.pathComponents.filter { $0 != "/" }
        let raw: String? = switch url.scheme {
        case "yui" where url.host() == "connect": parts.first
        case "https" where ["www.yuigui.com", "yuigui.com"].contains(url.host() ?? "") && parts.first == "a": parts.dropFirst().first
        default: nil
        }
        guard let raw, UUID(uuidString: raw) != nil else { return nil }
        return ConnectRequestID(id: raw.lowercased())
    }
}

struct ConnectRequest: Decodable, Equatable {
    struct Client: Decodable, Equatable { let name: String; let site: String }
    struct Agent: Decodable, Equatable, Identifiable { let id: String; let name: String; let handle: String }
    /// What app_deny answers.
    struct Brief: Decodable { let status: String }
    let id: String
    let client: Client
    let status: String
    let agents: [Agent]
    let suggestedName: String
    enum CodingKeys: String, CodingKey { case id, client, status, agents, suggestedName = "suggested_name" }
}

struct ConnectApprovalSheet: View {
    let request: ConnectRequestID
    @Environment(AgentStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.yuiTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var loaded: ConnectRequest?
    /// nil = a new agent named after the client.
    @State private var agentID: String?
    @State private var phase: Phase = .loading
    @State private var working = false
    @State private var error: String?

    enum Phase: Equatable { case loading, asking, allowed(id: String, name: String), denied, finished(String) }

    var body: some View {
        let c = theme.swatch(scheme)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.spacing.l) {
                    switch phase {
                    case .loading:
                        HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 60)
                    case .asking:
                        if let loaded { asking(loaded, c) }
                    case .allowed(let id, let agent):
                        done(title: "Connected", body: "\(loaded?.client.name ?? "It") talks as \(agent) now. Go back to \(loaded?.client.name ?? "the app") to finish. Remove it any time in Agents.", c)
                        PillButton(title: "Open \(agent)'s thread") {
                            store.selectedID = id
                            dismiss()
                        }
                        .accessibilityIdentifier("connectOpenThread")
                    case .denied:
                        done(title: "Not connected", body: "\(loaded?.client.name ?? "The app") won't get in. Go back to it if you change your mind.", c)
                    case .finished(let why):
                        done(title: "Nothing to approve", body: why, c)
                    }
                    if let error {
                        Text(error).font(theme.font(theme.type.caption, .semibold)).foregroundStyle(.red)
                    }
                }
                .padding(theme.spacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(c.background)
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if phase != .asking { Button("Done") { dismiss() }.tint(c.accent) }
                }
            }
        }
        .interactiveDismissDisabled(phase == .asking)
        .task { await load() }
    }

    private func asking(_ r: ConnectRequest, _ c: Swatch) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.l) {
            HStack {
                Spacer()
                AgentAvatar(name: r.client.name, size: 72)
                Spacer()
            }
            Text("Connect \(r.client.name)?")
                .font(theme.font(theme.type.title, .bold)).foregroundStyle(c.ink)
                .accessibilityIdentifier("connectTitle")
            Text("\(r.client.name)\(r.client.site.isEmpty ? "" : " (\(r.client.site))") wants to put screens on your phone and read your taps, in one thread. It can't see your other threads.")
                .font(theme.font(theme.type.body)).foregroundStyle(c.inkSoft)
            Text("Talks as").font(theme.font(theme.type.caption, .bold)).foregroundStyle(c.inkSoft)
            VStack(spacing: theme.spacing.s) {
                choice(nil, title: "New agent: \(r.suggestedName)", c)
                ForEach(r.agents) { a in choice(a.id, title: a.name, c) }
            }
            PillButton(title: "Allow", working: working) { Task { await allow(r) } }
                .accessibilityIdentifier("connectAllow")
            Button("Don't allow") { Task { await deny(r) } }
                .font(theme.font(theme.type.body, .bold)).tint(c.inkSoft)
                .frame(maxWidth: .infinity)
                .disabled(working)
        }
    }

    private func choice(_ id: String?, title: String, _ c: Swatch) -> some View {
        let on = agentID == id
        return Button { withAnimation(theme.spring) { agentID = id } } label: {
            HStack {
                Text(title).font(theme.font(theme.type.body, .semibold)).foregroundStyle(c.ink)
                Spacer()
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? c.accent : c.outline)
            }
            .padding(theme.spacing.m)
            .background(c.surface, in: .rect(cornerRadius: theme.radius.bubble))
            .overlay(RoundedRectangle(cornerRadius: theme.radius.bubble).stroke(on ? c.accent : c.outline, lineWidth: on ? 2 : 1))
        }
        .buttonStyle(BounceButtonStyle())
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func done(title: String, body: String, _ c: Swatch) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.m) {
            Text(title).font(theme.font(theme.type.title, .bold)).foregroundStyle(c.ink)
                .accessibilityIdentifier("connectResult")
            Text(body).font(theme.font(theme.type.body)).foregroundStyle(c.inkSoft)
        }
    }

    private func load() async {
        do {
            // Right after launch the session may still be refreshing: one retry.
            let r: ConnectRequest
            do { r = try await store.connectRequest(request.id) } catch AccountError.server(let code) where code == "invalid_request" {
                throw AccountError.server(code)
            } catch {
                try? await Task.sleep(for: .seconds(2))
                r = try await store.connectRequest(request.id)
            }
            loaded = r
            switch r.status {
            case "pending": phase = .asking
            case "expired": phase = .finished("This request expired. Add Yui in \(r.client.name) again.")
            default: phase = .finished("\(r.client.name) is already approved or turned down.")
            }
        } catch AccountError.server(let code) where code == "invalid_request" {
            phase = .finished("This connect link doesn't exist. Add Yui in your app again.")
        } catch {
            #if DEBUG
            print("connect load failed:", error)
            #endif
            phase = .finished("Couldn't load this request. Check your connection and open the link again.")
        }
    }

    private func allow(_ r: ConnectRequest) async {
        working = true
        defer { working = false }
        do {
            let id = try await store.approveConnect(r.id, agentID: agentID, name: agentID == nil ? r.suggestedName : nil)
            let name = store.agents.first { $0.id == id }?.name ?? r.agents.first { $0.id == id }?.name ?? r.suggestedName
            error = nil
            withAnimation(theme.spring) { phase = .allowed(id: id, name: name) }
        } catch {
            self.error = "That didn't go through. Check your connection and tap Allow again."
        }
    }

    private func deny(_ r: ConnectRequest) async {
        working = true
        defer { working = false }
        do {
            try await store.denyConnect(r.id)
            withAnimation(theme.spring) { phase = .denied }
        } catch {
            self.error = "That didn't go through. Try again."
        }
    }
}
