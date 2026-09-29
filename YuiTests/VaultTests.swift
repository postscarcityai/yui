import CryptoKit
import XCTest
import YuiLines
@testable import Yui

/// The vault, app side (YUI-34 step 2): shape checks, the hold on key-shaped text, the Keychain items,
/// HPKE sealing, the ask and its answer, grants and their lapse. Fake keys only; nothing calls a provider.
@MainActor
final class VaultTests: XCTestCase {
    // Fake keys of each provider's shape (random-looking, not real).
    static let fal = "3f9a1c2e-7b4d-4e6a-9c1d-2a8b5e7f0c13:9d8c7b6a5f4e3d2c1b0a9f8e7d6c5b4a"
    static let replicate = "r8_Zx3Kq9LmN2pR7sT4vW6yB8cD1eF5gH0jAb"
    static let eleven = "sk_1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f"
    static let anthropic = "sk-ant-api03-Qx7Lm2Pn9Rs4Tv6Wy8Zb1Cd3Ef5Gh0Jk"
    static let openai = "sk-proj-Ab1Cd2Ef3Gh4Ij5Kl6Mn7Op8Qr9St0Uv"
    static let openrouter = "sk-or-v1-0123456789abcdef0123456789abcdef0123456789abcdef"

    static let all: [(VaultProvider, String)] = [(.fal, fal), (.replicate, replicate), (.elevenlabs, eleven),
                                                 (.anthropic, anthropic), (.openai, openai)]

    // MARK: Shape

    func testEachProviderShapeMatchesOnlyItsOwnKey() {
        for (p, key) in Self.all {
            XCTAssertTrue(p.matches(key), "\(p) refused its own key")
            XCTAssertEqual(VaultProvider.detect(key), p, "\(key.prefix(6)) detected as another provider")
            for other in VaultProvider.allCases where other != p { XCTAssertFalse(other.matches(key), "\(other) took a \(p) key") }
        }
        XCTAssertFalse(VaultProvider.openai.matches(Self.openrouter), "OpenRouter's key is not an OpenAI key")
        XCTAssertEqual(VaultProvider.fal.wrongShape, "That doesn't look like a fal key.")
        XCTAssertEqual(VaultProvider.last4(Self.anthropic), "h0Jk")
    }

    func testHeldTextNamesTheKeyShape() {
        for (p, key) in Self.all {
            let shape = KeyShape.find(in: "here you go: \(key) thanks")
            XCTAssertEqual(shape, .provider(p, key: key))
            XCTAssertTrue(shape?.isKnown == true, "a known provider shape has no Send anyway")
        }
        XCTAssertEqual(KeyShape.find(in: "FAL_KEY=\(Self.fal)"), .provider(.fal, key: Self.fal))
        XCTAssertEqual(KeyShape.find(in: "\"\(Self.replicate)\""), .provider(.replicate, key: Self.replicate))
        XCTAssertEqual(KeyShape.find(in: Self.openrouter), .openRouter(key: Self.openrouter))
        XCTAssertTrue(KeyShape.find(in: Self.openrouter)?.isKnown == true)
    }

    func testALookalikeIsHeldButMaySendAnyway() {
        let token = "Zk3Jq8Vn2Lp7Xw5Ty9Bm4Rc6Hd1Fs0Ga8Ue"
        let shape = KeyShape.find(in: "the token is \(token)")
        XCTAssertEqual(shape, .lookalike(key: token))
        XCTAssertFalse(shape?.isKnown ?? true, "a mere lookalike may be sent anyway")
        XCTAssertNotNil(KeyShape.find(in: "ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
    }

    func testOrdinaryTextIsNeverHeld() {
        for text in ["Plan my week", "Book 12:30 with Sam at https://example.com/a/very/long/path/that/keeps/going/and/going",
                     "internationalization-and-localization-considerations for the app",
                     "call me on 555-0100 about the 3:45 flight", "", "sk-",
                     "my number is 4111111111111111"] {
            XCTAssertNil(KeyShape.find(in: text), "held: \(text)")
        }
    }

    // MARK: Sealing

    func testSealedKeyOpensWithTheConnectorsPrivateKey() throws {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        for (_, key) in Self.all {
            let sealed = try VaultSeal.seal(key, keyID: "k-test", to: priv.publicKey)
            XCTAssertEqual(sealed.count, 32 + key.utf8.count + 16, "enc (32) + ciphertext + tag (16)")
            XCTAssertNil(sealed.range(of: Data(key.utf8)), "the sealed bytes hold the key in the clear")
            XCTAssertEqual(try VaultSeal.open(sealed, keyID: "k-test", with: priv), key)
        }
    }

    func testSealIsBoundToTheConnectorKeyIdAndTheRecipient() throws {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let sealed = try VaultSeal.seal(Self.fal, keyID: "k-1", to: priv.publicKey)
        XCTAssertThrowsError(try VaultSeal.open(sealed, keyID: "k-2", with: priv), "info binds the key id")
        XCTAssertThrowsError(try VaultSeal.open(sealed, keyID: "k-1", with: Curve25519.KeyAgreement.PrivateKey()), "another recipient")
        XCTAssertNotEqual(sealed, try VaultSeal.seal(Self.fal, keyID: "k-1", to: priv.publicKey), "a fresh ephemeral key each time")
        XCTAssertEqual(VaultSeal.info(keyID: "k-1"), Data("yui-vault-v1|k-1".utf8))
    }

    func testThePinnedConnectorKeyIsOneValid32ByteKey() throws {
        XCTAssertEqual(Data(base64Encoded: VaultConnectorKey.publicKeyBase64)?.count, 32)
        _ = try VaultSeal.pinnedPublicKey()
        XCTAssertNoThrow(try VaultSeal.seal(Self.fal))
    }

    // MARK: Keychain

    private func freshStore() -> VaultStore {
        let s = VaultStore(service: "com.yuigui.vault.unittest")
        s.removeAll()
        addTeardownBlock { s.removeAll() }
        return s
    }

    func testAKeyIsOneKeychainItemThisDeviceOnlyAndListingHoldsNoSecret() throws {
        let store = freshStore()
        let m = try store.add(Self.fal, provider: .fal, name: "Personal fal", capCents: 1000)
        XCTAssertEqual(store.list(), [m])
        XCTAssertEqual(m.last4, "5b4a")
        XCTAssertFalse(m.icloud, "iCloud is off by default")
        XCTAssertEqual(store.accessibility(m.id), kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(store.secret(m.id), Self.fal)
        let encoded = String(decoding: try JSONEncoder().encode(store.list()), as: UTF8.self)
        XCTAssertFalse(encoded.contains(Self.fal), "the listing carries the secret")
    }

    func testICloudSwitchMakesItSynchronizableAndOffPutsItBack() throws {
        let store = freshStore()
        let m = try store.add(Self.replicate, provider: .replicate, name: "R")
        let on = try store.setICloud(m.id, true)
        XCTAssertTrue(on.icloud)
        XCTAssertEqual(store.accessibility(m.id), kSecAttrAccessibleWhenUnlocked as String)
        XCTAssertEqual(store.secret(m.id), Self.replicate)
        let off = try store.setICloud(m.id, false)
        XCTAssertFalse(off.icloud)
        XCTAssertEqual(store.accessibility(m.id), kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(store.list().count, 1, "one item, never two")
    }

    func testReplaceKeepsTheIdAndRemoveDeletesTheItem() throws {
        let store = freshStore()
        let m = try store.add(Self.fal, provider: .fal, name: "Personal fal")
        let r = try store.replace(m.id, with: Self.fal.dropLast(4) + "0000")
        XCTAssertEqual(r.id, m.id)
        XCTAssertEqual(r.last4, "0000")
        XCTAssertEqual(r.name, "Personal fal")
        XCTAssertTrue(store.secret(m.id)?.hasSuffix("0000") == true)
        try store.remove(m.id)
        XCTAssertNil(store.secret(m.id))
        XCTAssertTrue(store.list().isEmpty)
    }

    // MARK: The model: Face ID, sealing, grants

    /// A relay that only writes down what it is told.
    @MainActor final class Spy: VaultBackend {
        var sealed: [(UUID, Data, String)] = []
        var grants: [(UUID, String, String, String, Int?, Bool)] = []
        var revoked: [String] = []
        var deleted: [UUID] = []
        func keys() async throws -> [VaultRelayKey] { [] }
        func putSealed(_ meta: VaultKeyMeta, sealed data: Data, connectorKeyID: String) async throws { sealed.append((meta.id, data, connectorKeyID)) }
        func deleteKey(_ id: UUID) async throws { deleted.append(id) }
        func grants(agentID: String?) async throws -> [VaultGrant] { [] }
        func createGrant(key: UUID, agentID: String, handle: String, purpose: String, capCents: Int?, once: Bool) async throws {
            grants.append((key, agentID, handle, purpose, capCents, once))
        }
        func revoke(_ grantID: String) async throws { revoked.append(grantID) }
        func uses(since: Date) async throws -> [VaultUse] { [] }
    }

    private func model(_ spy: Spy, auth: Bool = true) -> VaultModel {
        let saved = VaultAuth.confirm
        VaultAuth.confirm = { _ in auth }
        addTeardownBlock { VaultAuth.confirm = saved }
        return VaultModel(store: freshStore(), backend: spy)
    }

    func testAddNeedsTheRightShapeAndFaceID() async {
        let spy = Spy()
        let m = model(spy, auth: false)
        let wrong = await m.add(Self.replicate, provider: .fal, name: "x", capCents: 1000, icloud: false, limitConfirmed: false)
        XCTAssertNil(wrong)
        XCTAssertEqual(m.error, "That doesn't look like a fal key.")
        let refused = await m.add(Self.fal, provider: .fal, name: "x", capCents: 1000, icloud: false, limitConfirmed: false)
        XCTAssertNil(refused, "no Face ID, no key")
        XCTAssertEqual(m.error, VaultAuth.refused)
        XCTAssertTrue(m.store.list().isEmpty)
        let ok = model(spy)
        let saved = await ok.add(" \(Self.fal)\n", provider: .fal, name: "Personal fal", capCents: 1000, icloud: false, limitConfirmed: false)
        XCTAssertEqual(saved?.last4, "5b4a")
    }

    func testGrantSealsTheKeyAndTheRelayNeverSeesItClear() async throws {
        let spy = Spy()
        let m = model(spy)
        let added = await m.add(Self.anthropic, provider: .anthropic, name: "Claude", capCents: 1000, icloud: false, limitConfirmed: false)
        let key = try XCTUnwrap(added)
        XCTAssertTrue(spy.sealed.isEmpty, "nothing goes to the connector until a grant is made")
        let handle = try await m.grant(key, agentID: "agent-1", purpose: "Draft replies", capCents: 5000, once: false)
        XCTAssertNotNil(handle.range(of: #"^vk_anthropic_[0-9a-f]{4}$"#, options: .regularExpression))
        XCTAssertEqual(spy.sealed.count, 1)
        XCTAssertEqual(spy.sealed[0].2, VaultConnectorKey.keyID)
        XCTAssertNil(spy.sealed[0].1.range(of: Data(Self.anthropic.utf8)))
        XCTAssertEqual(spy.sealed[0].1.count, 32 + Self.anthropic.utf8.count + 16)
        let g = spy.grants[0]
        XCTAssertEqual(g.1, "agent-1")
        XCTAssertEqual(g.2, handle)
        XCTAssertEqual(g.4, 1000, "the grant cap never exceeds the key's cap ($10)")
        XCTAssertFalse(g.5)
    }

    func testGrantWithoutFaceIDSealsNothing() async throws {
        let spy = Spy()
        let good = model(spy)
        let added = await good.add(Self.fal, provider: .fal, name: "f", capCents: 1000, icloud: false, limitConfirmed: false)
        let key = try XCTUnwrap(added)
        VaultAuth.confirm = { _ in false }
        do { _ = try await good.grant(key, agentID: "a", purpose: "p", capCents: nil, once: true); XCTFail("granted without Face ID") }
        catch { XCTAssertEqual(error as? VaultModel.GrantError, .refused) }
        XCTAssertTrue(spy.sealed.isEmpty)
        XCTAssertTrue(spy.grants.isEmpty)
    }

    func testAProviderWithNoPriceNeedsAConfirmedLimitBeforeAGrant() async throws {
        let spy = Spy()
        let m = model(spy)
        let added = await m.add(Self.eleven, provider: .elevenlabs, name: "Voice", capCents: 1000, icloud: false, limitConfirmed: false)
        let key = try XCTUnwrap(added)
        do { _ = try await m.grant(key, agentID: "a", purpose: "p", capCents: nil, once: false); XCTFail("granted with no limit") }
        catch { XCTAssertEqual(error as? VaultModel.GrantError, .needsLimit) }
        m.setLimitConfirmed(key.id, true)
        let confirmed = try XCTUnwrap(m.store.meta(key.id))
        _ = try await m.grant(confirmed, agentID: "a", purpose: "p", capCents: nil, once: false)
        XCTAssertEqual(spy.grants.count, 1)
    }

    func testRemovingAKeyDeletesTheItemAndTheSealedCopy() async throws {
        let spy = Spy()
        let m = model(spy)
        let added = await m.add(Self.fal, provider: .fal, name: "f", capCents: 1000, icloud: false, limitConfirmed: false)
        let key = try XCTUnwrap(added)
        let removed = await m.remove(key.id)
        XCTAssertTrue(removed)
        XCTAssertNil(m.store.secret(key.id))
        XCTAssertEqual(spy.deleted, [key.id])
    }

    // MARK: The ask

    private func askMeta(_ extra: [String: YLValue] = [:]) -> YLValue {
        var o: [String: YLValue] = ["v": .number(1), "req": .string("k-19c4"), "op": .string("key_ask"), "provider": .string("fal"),
                                    "for": .string("Draw your agent avatars"), "est": .string("about 4 images a week"), "cap": .number(5)]
        o.merge(extra) { $1 }
        return .object(o)
    }

    func testAKeyAskParses() {
        guard case .ask(let a) = KeyAsk.parse(askMeta()) else { return XCTFail("not an ask") }
        XCTAssertEqual(a.provider, .fal)
        XCTAssertEqual(a.purpose, "Draw your agent avatars")
        XCTAssertEqual(a.cap, 5)
        XCTAssertEqual(a.est, "about 4 images a week")
        guard case .ask(let bare) = KeyAsk.parse(.object(["v": .number(1), "req": .string("r"), "op": .string("key_ask"),
                                                          "provider": .string("openai"), "for": .string("Read a photo")])) else { return XCTFail() }
        XCTAssertNil(bare.cap)
    }

    func testABadAskIsRefusedOrIgnoredNeverShown() {
        XCTAssertEqual(KeyAsk.parse(askMeta(["for": .string("use \(Self.fal) please")])), .refuse(req: "k-19c4", provider: "fal"))
        XCTAssertEqual(KeyAsk.parse(askMeta(["for": .string(String(repeating: "a", count: 81))])), .refuse(req: "k-19c4", provider: "fal"))
        XCTAssertEqual(KeyAsk.parse(askMeta(["provider": .string("openrouter")])), .refuse(req: "k-19c4", provider: "openrouter"))
        XCTAssertEqual(KeyAsk.parse(askMeta(["op": .string("list")])), .ignore)
        XCTAssertEqual(KeyAsk.parse(askMeta(["v": .number(2)])), .ignore)
        XCTAssertEqual(KeyAsk.parse(nil), .ignore)
    }

    func testTheAnswerRowsAndTheLinesTheAgentHears() throws {
        let allow = KeyAnswer(req: "k-19c4", decision: .allow, provider: "fal", handle: "vk_fal_3f9a", cap: 5)
        let o = try XCTUnwrap(allow.meta.object)
        XCTAssertEqual(o["op"]?.string, "key_answer")
        XCTAssertEqual(o["req"]?.string, "k-19c4")
        XCTAssertEqual(o["decision"]?.string, "allow")
        XCTAssertEqual(o["provider"]?.string, "fal")
        XCTAssertEqual(o["handle"]?.string, "vk_fal_3f9a")
        XCTAssertEqual(o["cap"]?.number, 5)
        XCTAssertEqual(allow.line(purpose: "Draw your agent avatars"),
                       "[yui] Key access: fal allowed for \"Draw your agent avatars\", cap $5 a month, handle vk_fal_3f9a.")
        let deny = KeyAnswer(req: "k-19c4", decision: .deny, provider: "fal")
        XCTAssertEqual(deny.meta.object?["decision"]?.string, "deny")
        XCTAssertNil(deny.meta.object?["handle"])
        XCTAssertEqual(deny.line(purpose: ""), "[yui] Key access: fal not allowed.")
        XCTAssertEqual(KeyAnswer(req: "r", decision: .once, provider: "fal", handle: "vk_fal_0001", cap: 5).meta.object?["decision"]?.string, "once")
    }

    func testAnsweredAsksAreRemembered() {
        let req = "k-test-\(UUID().uuidString)"
        XCTAssertFalse(KeyAsks.answered(req))
        KeyAsks.markAnswered(req)
        XCTAssertTrue(KeyAsks.answered(req))
    }

    // MARK: Grants lapse

    func testAGrantLapsesAfterNinetyIdleDaysWithAHeadsUpFromDayEighty() {
        let now = Date.now
        func grant(idle days: Int) -> VaultGrant {
            let at = ISO8601DateFormatter().string(from: now.addingTimeInterval(-Double(days) * 86_400 - 60))
            return VaultGrant(id: "g", key: "k", agentID: "a", handle: "vk_fal_0000", purpose: "p", createdAt: at)
        }
        XCTAssertNil(grant(idle: 79).lapseNote(now: now))
        XCTAssertEqual(grant(idle: 80).lapseNote(now: now), "Lapses in 10 days if it isn't used.")
        XCTAssertEqual(grant(idle: 89).lapseNote(now: now), "Lapses in 1 day if it isn't used.")
        XCTAssertEqual(Money.dollars(800), "$8")
        XCTAssertEqual(Money.dollars(250), "$2.50")
    }
}
