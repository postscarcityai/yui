import Foundation
import YuiLines

enum Money {
    /// 800 -> "$8", 250 -> "$2.50"
    static func dollars(_ cents: Int) -> String {
        cents % 100 == 0 ? "$\(cents / 100)" : String(format: "$%.2f", Double(cents) / 100)
    }
}

/// The vault as the screens see it: the Keychain's keys, this month's spend and the grants from the relay.
@MainActor @Observable
final class VaultModel {
    static let shared = VaultModel()

    var store = VaultStore.shared
    private(set) var keys: [VaultKeyMeta] = []
    private(set) var grants: [VaultGrant] = []
    private(set) var spentCents: [String: Int] = [:]
    private(set) var spentByAgent: [String: Int] = [:]
    /// The relay said no or could not be reached: shown in words, never a status code.
    var error: String?
    private var backend: VaultBackend?
    private var configured = false

    init(store: VaultStore = .shared, backend: VaultBackend? = nil) {
        self.store = store
        self.backend = backend
    }

    /// Point the model at this account's relay (the demo account gets its in-memory one).
    func configure(account: Account) {
        #if DEBUG
        if account.session?.userID == "demo" {
            let demo = DemoVaultBackend.shared
            backend = demo
            if !configured {
                let args = ProcessInfo.processInfo.arguments
                if !args.contains("-yuiVaultKeep") { store.removeAll(); demo.reset() }
                if args.contains("-yuiDemoVault"), store.list().isEmpty {
                    if let m = try? store.add("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee:0123456789abcdef0123456789abcdef", provider: .fal,
                                              name: "Personal fal") {
                        demo.spend.append((m.id.uuidString.lowercased(), "demo-nova", 800))
                    }
                }
            }
            configured = true
            keys = store.list()
            return
        }
        #endif
        configured = true
        backend = LiveVaultBackend(account: account)
    }

    func reload() async {
        keys = store.list()
        guard let backend else { return }
        do {
            grants = try await backend.grants(agentID: nil)
            let start = Calendar(identifier: .gregorian).dateInterval(of: .month, for: .now)?.start ?? .now
            var byKey: [String: Int] = [:], byAgent: [String: Int] = [:]
            for u in try await backend.uses(since: start) {
                byKey[(u.key ?? "").lowercased(), default: 0] += u.costCents ?? 0
                byAgent[(u.agentID ?? "").lowercased() + "|" + (u.key ?? "").lowercased(), default: 0] += u.costCents ?? 0
            }
            spentCents = byKey
            spentByAgent = byAgent
            error = nil
        } catch {
            self.error = "Couldn't reach Yui to read this month's spend."
        }
    }

    func spent(_ key: VaultKeyMeta) -> Int { spentCents[key.id.uuidString.lowercased()] ?? 0 }
    func spent(agent: String, key: String) -> Int { spentByAgent[agent.lowercased() + "|" + key.lowercased()] ?? 0 }

    func grants(for key: VaultKeyMeta) -> [VaultGrant] { grants.filter { $0.key == key.id.uuidString.lowercased() && $0.live } }

    /// When this key last made a call: the newest grant's last use.
    func lastUsed(_ key: VaultKeyMeta) -> Date? {
        grants.filter { $0.key == key.id.uuidString.lowercased() }
            .compactMap { $0.lastUsedAt.flatMap(YuiTime.date) }.max()
    }

    /// "Not used yet", "Used 2 days ago".
    func lastUsedLine(_ key: VaultKeyMeta, now: Date = .now) -> String {
        guard let d = lastUsed(key) else { return "Not used yet" }
        let days = Int(now.timeIntervalSince(d) / 86_400)
        return days <= 0 ? "Used today" : days == 1 ? "Used yesterday" : "Used \(days) days ago"
    }

    /// Where the key lives, in words (each row says it).
    static func lives(_ key: VaultKeyMeta) -> String {
        key.icloud ? "On this iPhone and your iCloud Keychain" : "On this iPhone only"
    }

    // MARK: Changes, each behind Face ID

    @discardableResult
    func add(_ secret: String, provider: VaultProvider, name: String, capCents: Int, icloud: Bool, limitConfirmed: Bool) async -> VaultKeyMeta? {
        let key = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard provider.matches(key) else { error = provider.wrongShape; return nil }
        guard await VaultAuth.confirm("Add your \(provider.label) key to Yui") else { error = VaultAuth.refused; return nil }
        do {
            let m = try store.add(key, provider: provider, name: name, capCents: capCents, icloud: icloud, providerLimitConfirmed: limitConfirmed)
            keys = store.list()
            error = nil
            return m
        } catch {
            self.error = "Couldn't save the key on this iPhone."
            return nil
        }
    }

    func replace(_ id: UUID, with secret: String) async -> Bool {
        let key = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = store.meta(id) else { return false }
        guard m.provider.matches(key) else { error = m.provider.wrongShape; return false }
        guard await VaultAuth.confirm("Replace your \(m.provider.label) key") else { error = VaultAuth.refused; return false }
        do {
            _ = try store.replace(id, with: key)
            // A new key: the old sealed copy goes, the next grant seals the new one.
            try? await backend?.deleteKey(id)
            keys = store.list()
            await reload()
            return true
        } catch {
            self.error = "Couldn't replace the key."
            return false
        }
    }

    func remove(_ id: UUID) async -> Bool {
        guard let m = store.meta(id) else { return false }
        guard await VaultAuth.confirm("Remove your \(m.provider.label) key") else { error = VaultAuth.refused; return false }
        do {
            try store.remove(id)
            try? await backend?.deleteKey(id)  // the sealed copy, and every grant with it
            keys = store.list()
            await reload()
            return true
        } catch {
            self.error = "Couldn't remove the key."
            return false
        }
    }

    func setICloud(_ id: UUID, _ on: Bool) async -> Bool {
        guard await VaultAuth.confirm(on ? "Keep this key in iCloud Keychain" : "Keep this key on this iPhone only") else {
            error = VaultAuth.refused
            return false
        }
        do { _ = try store.setICloud(id, on); keys = store.list(); return true } catch { self.error = "Couldn't change that."; return false }
    }

    func setLimitConfirmed(_ id: UUID, _ on: Bool) {
        guard var m = store.meta(id) else { return }
        m.providerLimitConfirmed = on
        try? store.update(m)
        keys = store.list()
    }

    // MARK: Grants

    enum GrantError: Error, Equatable { case refused, noKey, needsLimit, seal, relay }

    /// `vk_fal_3f9a`
    static func handle(_ provider: VaultProvider) -> String {
        "vk_\(provider.rawValue)_" + String(format: "%04x", UInt16.random(in: 0...UInt16.max))
    }

    /// Grants `agentID` this key: Face ID, then the key is sealed to the connector and put on the relay,
    /// then the grant row. The key itself never leaves the phone in the clear. Returns the handle.
    func grant(_ key: VaultKeyMeta, agentID: String, purpose: String, capCents: Int?, once: Bool) async throws -> String {
        if !key.provider.hasPriceEntry, !key.providerLimitConfirmed { throw GrantError.needsLimit }
        guard await VaultAuth.confirm("Let an agent use your \(key.provider.label) key") else { throw GrantError.refused }
        guard let secret = store.secret(key.id) else { throw GrantError.noKey }
        guard let backend else { throw GrantError.relay }
        let sealed: Data
        do { sealed = try VaultSeal.seal(secret) } catch { throw GrantError.seal }
        let handle = Self.handle(key.provider)
        do {
            try await backend.putSealed(key, sealed: sealed, connectorKeyID: VaultConnectorKey.keyID)
            try await backend.createGrant(key: key.id, agentID: agentID, handle: handle, purpose: purpose,
                                          capCents: capCents.map { min($0, key.capCents) }, once: once)
        } catch {
            throw GrantError.relay
        }
        await reload()
        return handle
    }

    func revoke(_ grant: VaultGrant) async -> Bool {
        do { try await backend?.revoke(grant.id) } catch { self.error = "Couldn't revoke that. Try again."; return false }
        await reload()
        return true
    }

    func grants(agent: String) -> [VaultGrant] { grants.filter { $0.agentID == agent && $0.live } }
    func key(forGrant g: VaultGrant) -> VaultKeyMeta? { keys.first { $0.id.uuidString.lowercased() == g.key } }
}

// MARK: The ask (spec/VAULT.md section 3)

/// A host's `key_ask` control row.
struct KeyAsk: Equatable, Identifiable, Sendable {
    let req: String
    let provider: VaultProvider
    let purpose: String
    var est: String?
    /// The suggested monthly cap, dollars.
    var cap: Int?
    var id: String { req }

    enum Parsed: Equatable { case ask(KeyAsk), refuse(req: String, provider: String), ignore }

    static let maxFor = 80

    /// One `meta` from a control row. A key-shaped or over-long `for` is refused, not shown.
    static func parse(_ meta: YLValue?) -> Parsed {
        guard let o = meta?.object, o["op"]?.string == "key_ask", let req = o["req"]?.string, !req.isEmpty else { return .ignore }
        guard o["v"]?.number == 1, let p = o["provider"]?.string, let provider = VaultProvider(rawValue: p) else {
            return o["v"]?.number == 1 ? .refuse(req: req, provider: o["provider"]?.string ?? "") : .ignore
        }
        let why = (o["for"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !why.isEmpty, why.count <= maxFor, KeyShape.find(in: why) == nil else { return .refuse(req: req, provider: p) }
        let est = o["est"]?.string.map { String($0.prefix(80)) }
        if let est, KeyShape.find(in: est) != nil { return .refuse(req: req, provider: p) }
        return .ask(KeyAsk(req: req, provider: provider, purpose: why, est: est, cap: o["cap"]?.number.map { max(Int($0), 1) }))
    }
}

/// The app's answer: a control row, op `key_answer` (contract item 7).
struct KeyAnswer: Equatable, Sendable {
    enum Decision: String, Sendable { case allow, once, deny }
    let req: String
    let decision: Decision
    let provider: String
    var handle: String?
    /// Dollars a month; 0 on a no.
    var cap: Int = 0

    var meta: YLValue {
        var o: [String: YLValue] = ["v": .number(1), "req": .string(req), "op": .string("key_answer"),
                                    "decision": .string(decision.rawValue), "provider": .string(provider), "cap": .number(Double(cap))]
        if let handle { o["handle"] = .string(handle) }
        return .object(o)
    }

    /// The line the agent hears (the relay writes it; the demo account shows it).
    func line(purpose: String) -> String {
        switch decision {
        case .deny: "[yui] Key access: \(provider) not allowed."
        case .allow: "[yui] Key access: \(provider) allowed for \"\(purpose)\", cap $\(cap) a month, handle \(handle ?? "")."
        case .once: "[yui] Key access: \(provider) allowed once for \"\(purpose)\", handle \(handle ?? "")."
        }
    }
}

/// Which asks were already answered on this phone, so a poll never shows one twice.
enum KeyAsks {
    private static let defaultsKey = "yui.vault.answered"

    static func answered(_ req: String) -> Bool { (UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []).contains(req) }

    static func markAnswered(_ req: String) {
        var all = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        guard !all.contains(req) else { return }
        all.append(req)
        UserDefaults.standard.set(Array(all.suffix(200)), forKey: defaultsKey)
    }
}
