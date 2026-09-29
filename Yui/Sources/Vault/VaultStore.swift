import Foundation
import LocalAuthentication
import Security

/// What the phone knows about one vault key besides the key itself. Kept in the Keychain item's own
/// attributes, so listing keys never reads a secret.
struct VaultKeyMeta: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var provider: VaultProvider
    var name: String
    var last4: String
    /// This key's monthly cap in cents (default $10).
    var capCents: Int = 1000
    /// "Also on my other Apple devices" (iCloud Keychain). Off by default.
    var icloud: Bool = false
    var createdAt: Date = .now
    /// The owner confirmed a spend limit set at the provider (needed when the connector has no price for it).
    var providerLimitConfirmed: Bool = false

    /// `sk-...x7Qa`
    var masked: String { "\u{2022}\u{2022}\u{2022}\u{2022} \(last4)" }
}

/// One Keychain item per key: generic password, service `com.yuigui.vault`, readable only while unlocked and
/// on this device only, unless the per-key iCloud switch is on (synchronizable, WhenUnlocked).
/// The secret is never returned by a listing and never logged.
struct VaultStore: Sendable {
    let service: String

    static let liveService = "com.yuigui.vault"
    static let shared = VaultStore(service: liveService)

    init(service: String = VaultStore.liveService) { self.service = service }

    enum Failure: Error, Equatable { case keychain(OSStatus), missing }

    private func base(_ id: UUID? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
        if let id { q[kSecAttrAccount as String] = id.uuidString }
        return q
    }

    private static func encode(_ m: VaultKeyMeta) -> Data { (try? JSONEncoder().encode(m)) ?? Data() }

    /// Every key, newest first. Metadata only.
    func list() -> [VaultKeyMeta] {
        var q = base()
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let rows = out as? [[String: Any]] else { return [] }
        return rows.compactMap { ($0[kSecAttrGeneric as String] as? Data).flatMap { try? JSONDecoder().decode(VaultKeyMeta.self, from: $0) } }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func meta(_ id: UUID) -> VaultKeyMeta? { list().first { $0.id == id } }

    /// Saves a new key. The secret goes in as the item's data.
    func add(_ secret: String, provider: VaultProvider, name: String, capCents: Int = 1000, icloud: Bool = false,
             providerLimitConfirmed: Bool = false) throws -> VaultKeyMeta {
        let m = VaultKeyMeta(id: UUID(), provider: provider, name: name, last4: VaultProvider.last4(secret), capCents: capCents,
                             icloud: icloud, providerLimitConfirmed: providerLimitConfirmed)
        try write(m, secret: secret)
        return m
    }

    private func write(_ m: VaultKeyMeta, secret: String) throws {
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: m.id.uuidString,
            kSecValueData as String: Data(secret.utf8),
            kSecAttrGeneric as String: Self.encode(m),
            kSecAttrSynchronizable as String: m.icloud,
            kSecAttrAccessible as String: m.icloud ? kSecAttrAccessibleWhenUnlocked : kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    /// The key itself, for sealing. Only the grant flow calls this, after Face ID.
    func secret(_ id: UUID) -> String? {
        var q = base(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Paste a new key over this one: same id, name and cap, new secret and last four.
    func replace(_ id: UUID, with secret: String) throws -> VaultKeyMeta {
        guard var m = meta(id) else { throw Failure.missing }
        m.last4 = VaultProvider.last4(secret)
        try remove(id)
        try write(m, secret: secret)
        return m
    }

    /// Name or cap changes: attributes only.
    func update(_ m: VaultKeyMeta) throws {
        let s = SecItemUpdate(base(m.id) as CFDictionary, [kSecAttrGeneric as String: Self.encode(m)] as CFDictionary)
        guard s == errSecSuccess else { throw Failure.keychain(s) }
    }

    /// The per-key iCloud switch: the item is written again with the other accessibility.
    func setICloud(_ id: UUID, _ on: Bool) throws -> VaultKeyMeta {
        guard var m = meta(id), let s = secret(id) else { throw Failure.missing }
        guard m.icloud != on else { return m }
        m.icloud = on
        try remove(id)
        try write(m, secret: s)
        return m
    }

    func remove(_ id: UUID) throws {
        let s = SecItemDelete(base(id) as CFDictionary)
        guard s == errSecSuccess || s == errSecItemNotFound else { throw Failure.keychain(s) }
    }

    func removeAll() {
        SecItemDelete(base() as CFDictionary)
    }

    /// The Keychain item's accessibility class, for the test that says "this device only".
    func accessibility(_ id: UUID) -> String? {
        var q = base(id)
        q[kSecReturnAttributes as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let row = out as? [String: Any] else { return nil }
        return row[kSecAttrAccessible as String] as? String
    }
}

/// Face ID, or the passcode: add, replace, remove, and every grant.
@MainActor
enum VaultAuth {
    /// Tests swap this; the app uses the phone's own check.
    static var confirm: (String) async -> Bool = { reason in
        #if DEBUG
        // UI tests and the demo: no biometrics on a simulator.
        if ProcessInfo.processInfo.arguments.contains("-yuiVaultNoAuth") { return true }
        #endif
        let context = LAContext()
        var err: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    static let refused = "Face ID or your passcode is needed for that."
}
