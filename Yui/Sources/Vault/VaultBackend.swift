import Foundation
import YuiLines

/// A grant: this agent may use this key for this purpose (spec/VAULT.md section 3).
struct VaultGrant: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let key: String
    let agentID: String
    let handle: String
    let purpose: String
    var capCents: Int?
    var once: Bool = false
    var createdAt: String = ""
    var revokedAt: String?
    var lastUsedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, key, handle, purpose, once
        case agentID = "agent_id", capCents = "cap_cents", createdAt = "created_at", revokedAt = "revoked_at", lastUsedAt = "last_used_at"
    }

    var live: Bool { revokedAt == nil }

    /// Grants lapse after 90 days with no call; a heads-up shows from day 80 (contract decision 7).
    static let lapseDays = 90, warnDays = 80

    func idleDays(now: Date = .now) -> Int {
        guard let since = YuiTime.date(lastUsedAt ?? createdAt) else { return 0 }
        return max(Int(now.timeIntervalSince(since) / 86_400), 0)
    }

    /// "Lapses in 6 days if it isn't used", from day 80.
    func lapseNote(now: Date = .now) -> String? {
        let idle = idleDays(now: now)
        guard live, idle >= Self.warnDays else { return nil }
        let left = max(Self.lapseDays - idle, 0)
        return left == 0 ? "Lapses today if it isn't used." : "Lapses in \(left) day\(left == 1 ? "" : "s") if it isn't used."
    }
}

/// A key as the relay shows it to its owner (`yui_vault_keys_public`: never the sealed bytes).
struct VaultRelayKey: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let provider: String
    let name: String
    let last4: String
    var capCents: Int = 1000
    enum CodingKeys: String, CodingKey { case id, provider, name, last4, capCents = "cap_cents" }
}

/// One call's cost, for this month's total.
struct VaultUse: Decodable, Equatable, Sendable {
    let key: String?
    let agentID: String?
    let costCents: Int?
    let at: String
    enum CodingKeys: String, CodingKey { case key, at, agentID = "agent_id", costCents = "cost_cents" }
}

/// What the vault asks of the relay. The live one is PostgREST as `yui_user`; the demo account has its own.
@MainActor
protocol VaultBackend {
    func keys() async throws -> [VaultRelayKey]
    /// The sealed copy, put once when the first grant is made. Already there: left as it is.
    func putSealed(_ meta: VaultKeyMeta, sealed: Data, connectorKeyID: String) async throws
    func deleteKey(_ id: UUID) async throws
    func grants(agentID: String?) async throws -> [VaultGrant]
    func createGrant(key: UUID, agentID: String, handle: String, purpose: String, capCents: Int?, once: Bool) async throws
    func revoke(_ grantID: String) async throws
    func uses(since: Date) async throws -> [VaultUse]
}

@MainActor
struct LiveVaultBackend: VaultBackend {
    let account: Account

    private func rest(_ table: String, _ items: [URLQueryItem] = []) -> URL {
        var c = URLComponents(url: YuiBackend.url.appending(path: "rest/v1/\(table)"), resolvingAgainstBaseURL: false)!
        if !items.isEmpty { c.queryItems = items }
        // Timestamps carry "+00:00"; a bare "+" in a query reads as a space.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

    private func send(_ method: String, _ url: URL, body: YLValue? = nil, prefer: String = "return=minimal") async throws -> Data {
        var r = URLRequest(url: url)
        r.httpMethod = method
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONEncoder().encode(body)
        }
        r.setValue(prefer, forHTTPHeaderField: "Prefer")
        return try await YuiRelay.data(account, r)
    }

    func keys() async throws -> [VaultRelayKey] {
        let data = try await send("GET", rest("yui_vault_keys_public", [URLQueryItem(name: "select", value: "id,provider,name,last4,cap_cents")]))
        return try JSONDecoder().decode([VaultRelayKey].self, from: data)
    }

    func putSealed(_ meta: VaultKeyMeta, sealed: Data, connectorKeyID: String) async throws {
        guard let user = account.session?.userID else { throw AccountError.signedOut }
        // bytea as PostgREST reads it: "\x" and hex.
        let hex = "\\x" + sealed.map { String(format: "%02x", $0) }.joined()
        let row: YLValue = .object(["id": .string(meta.id.uuidString.lowercased()), "user_id": .string(user),
                                    "provider": .string(meta.provider.rawValue), "name": .string(meta.name),
                                    "last4": .string(meta.last4), "sealed": .string(hex), "key_id": .string(connectorKeyID),
                                    "cap_cents": .number(Double(meta.capCents)),
                                    "provider_limit_confirmed": .bool(meta.providerLimitConfirmed)])
        _ = try await send("POST", rest("yui_vault_keys", [URLQueryItem(name: "on_conflict", value: "id")]), body: row,
                           prefer: "resolution=ignore-duplicates,return=minimal")
    }

    func deleteKey(_ id: UUID) async throws {
        _ = try await send("DELETE", rest("yui_vault_keys", [URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())")]))
    }

    func grants(agentID: String?) async throws -> [VaultGrant] {
        var items = [URLQueryItem(name: "select", value: "id,key,agent_id,handle,purpose,cap_cents,once,created_at,revoked_at,last_used_at"),
                     URLQueryItem(name: "revoked_at", value: "is.null"),
                     URLQueryItem(name: "order", value: "created_at.desc")]
        if let agentID { items.append(URLQueryItem(name: "agent_id", value: "eq.\(agentID)")) }
        return try JSONDecoder().decode([VaultGrant].self, from: try await send("GET", rest("yui_vault_grants", items)))
    }

    func createGrant(key: UUID, agentID: String, handle: String, purpose: String, capCents: Int?, once: Bool) async throws {
        var row: [String: YLValue] = ["key": .string(key.uuidString.lowercased()), "agent_id": .string(agentID), "handle": .string(handle),
                                      "purpose": .string(purpose), "once": .bool(once)]
        if let capCents { row["cap_cents"] = .number(Double(capCents)) }
        _ = try await send("POST", rest("yui_vault_grants"), body: .object(row))
    }

    func revoke(_ grantID: String) async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        _ = try await send("PATCH", rest("yui_vault_grants", [URLQueryItem(name: "id", value: "eq.\(grantID)")]),
                           body: .object(["revoked_at": .string(now)]))
    }

    func uses(since: Date) async throws -> [VaultUse] {
        let from = ISO8601DateFormatter().string(from: since)
        let items = [URLQueryItem(name: "select", value: "key,agent_id,cost_cents,at"), URLQueryItem(name: "kind", value: "eq.call"),
                     URLQueryItem(name: "at", value: "gte.\(from)"), URLQueryItem(name: "limit", value: "5000")]
        return try JSONDecoder().decode([VaultUse].self, from: try await send("GET", rest("yui_vault_uses", items)))
    }
}

#if DEBUG
/// The demo account's relay, in memory (screenshots and UI tests, no network). `-yuiDemoVault` starts with a grant and some spend.
@MainActor
final class DemoVaultBackend: VaultBackend {
    static let shared = DemoVaultBackend()
    var relayKeys: [VaultRelayKey] = []
    var sealed: [String: Data] = [:]
    var allGrants: [VaultGrant] = []
    var spend: [(key: String, agent: String, cents: Int)] = []
    /// Every request the demo relay took, for tests to read.
    var log: [String] = []

    func reset() { relayKeys = []; sealed = [:]; allGrants = []; spend = []; log = [] }

    func keys() async throws -> [VaultRelayKey] { relayKeys }

    func putSealed(_ meta: VaultKeyMeta, sealed data: Data, connectorKeyID: String) async throws {
        log.append("putSealed \(meta.provider.rawValue)")
        guard sealed[meta.id.uuidString.lowercased()] == nil else { return }
        sealed[meta.id.uuidString.lowercased()] = data
        relayKeys.append(VaultRelayKey(id: meta.id.uuidString.lowercased(), provider: meta.provider.rawValue, name: meta.name,
                                       last4: meta.last4, capCents: meta.capCents))
    }

    func deleteKey(_ id: UUID) async throws {
        let k = id.uuidString.lowercased()
        log.append("deleteKey")
        relayKeys.removeAll { $0.id == k }
        sealed[k] = nil
        allGrants.removeAll { $0.key == k }
    }

    func grants(agentID: String?) async throws -> [VaultGrant] {
        allGrants.filter { $0.live && (agentID == nil || $0.agentID == agentID) }
    }

    func createGrant(key: UUID, agentID: String, handle: String, purpose: String, capCents: Int?, once: Bool) async throws {
        log.append("createGrant \(handle)")
        let now = ISO8601DateFormatter().string(from: .now)
        allGrants.append(VaultGrant(id: UUID().uuidString.lowercased(), key: key.uuidString.lowercased(), agentID: agentID, handle: handle,
                                    purpose: purpose, capCents: capCents, once: once, createdAt: now))
    }

    func revoke(_ grantID: String) async throws {
        log.append("revoke")
        if let i = allGrants.firstIndex(where: { $0.id == grantID }) { allGrants[i].revokedAt = ISO8601DateFormatter().string(from: .now) }
    }

    func uses(since: Date) async throws -> [VaultUse] {
        let now = ISO8601DateFormatter().string(from: .now)
        return spend.map { VaultUse(key: $0.key, agentID: $0.agent, costCents: $0.cents, at: now) }
    }
}
#endif
