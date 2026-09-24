import Foundation
import Network
import Observation
import YuiLines

/// What the person sent that is not on Yui's server yet (YUI-28). Spec:
/// yuigui/spec/RELAY.md, "Delivery".
///
/// Every message and answered tap is written to disk before the first try, so
/// a dropped network or a killed app never loses one. They go out oldest
/// first, each with the id the app gave it: a resend of a row that already
/// landed hits the primary key (409) and counts as sent, so nothing is written
/// twice. Retries back off quietly (1 s up to 30 s) and start over the moment
/// the network comes back or the app returns to the foreground.
@Observable @MainActor
final class Outbox {
    static let shared = Outbox()

    struct Item: Codable, Equatable, Sendable {
        /// The row id, lowercased (the server returns ids lowercased).
        let id: String
        let userID: String
        let agentID: String
        let body: String
        let kind: String
        let meta: YLValue?
        let queuedAt: Date
    }

    private(set) var items: [Item] = []
    /// The last try failed on the network: the thread says so, quietly.
    private(set) var offline = false

    private let file: URL
    private weak var account: Account?
    private var runner: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private let monitor = NWPathMonitor()

    init(file: URL? = nil) {
        self.file = file ?? URL.applicationSupportDirectory.appending(path: "yui-outbox.json")
        if let data = try? Data(contentsOf: self.file),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        }
        monitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in Outbox.shared.kick() }
        }
        monitor.start(queue: DispatchQueue(label: "yui.outbox.path"))
    }

    func isPending(_ id: String) -> Bool { items.contains { $0.id == id.lowercased() } }
    func pending(agentID: String) -> [Item] { items.filter { $0.agentID == agentID } }

    /// Signed in: send what is waiting.
    func start(account: Account) {
        self.account = account
        kick()
    }

    func add(_ item: Item) {
        guard !isPending(item.id) else { return }
        items.append(item)
        save()
        kick()
    }

    /// Sign out: what was waiting belonged to that account.
    func clear() {
        items = []
        offline = false
        save()
    }

    /// Try now: a new message, the network is back, the app came forward.
    func kick() {
        sleeper?.cancel()
        guard runner == nil, !items.isEmpty, account != nil else { return }
        runner = Task { await run() }
    }

    private enum Outcome { case sent, drop, retry, stop }

    private func run() async {
        var backoff = 1.0
        while let item = items.first, let account {
            switch await send(item, account: account) {
            case .sent, .drop:
                items.removeAll { $0.id == item.id }
                save()
                offline = false
                backoff = 1
            case .retry:
                offline = true
                sleeper = Task { try? await Task.sleep(for: .seconds(backoff + .random(in: 0...0.5))) }
                await sleeper?.value
                backoff = min(backoff * 2, 30)
            case .stop:
                runner = nil
                return
            }
        }
        runner = nil
    }

    private func send(_ item: Item, account: Account) async -> Outcome {
        guard let user = account.session?.userID else { return .stop }
        if user != item.userID { return .drop }  // another account's leftover
        do {
            try await ThreadClient(account: account, agentID: item.agentID)
                .post(id: item.id, body: item.body, kind: item.kind, meta: item.meta)
            return .sent
        } catch AccountError.signedOut {
            return .stop
        } catch AccountError.server(let code) {
            switch code {
            case "http_409": return .sent  // an earlier try landed before its answer was lost
            case "http_400", "http_403", "http_404", "http_422": return .drop  // the agent is gone, or Yui refused it
            default: return .retry
            }
        } catch {
            return .retry
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(items).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
