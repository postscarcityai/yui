import CryptoKit
import Foundation

/// Sealing a key to the hosted connector (spec/VAULT.md section 4, contract item 5).
/// HPKE base mode, Curve25519_SHA256_ChachaPoly, info = utf8("yui-vault-v1|" + key_id),
/// sealed = enc (32 bytes) || ciphertext || tag. The plaintext is the key's utf8.
enum VaultSeal {
    enum Failure: Error, Equatable { case badPublicKey, tooShort, notUtf8 }

    static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly

    static func info(keyID: String) -> Data { Data(("yui-vault-v1|" + keyID).utf8) }

    /// The pinned connector key.
    static func pinnedPublicKey() throws -> Curve25519.KeyAgreement.PublicKey {
        guard let raw = Data(base64Encoded: VaultConnectorKey.publicKeyBase64),
              let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) else { throw Failure.badPublicKey }
        return key
    }

    /// `secret` sealed to `publicKey` under the connector key id `keyID`. Fresh ephemeral key per call.
    static func seal(_ secret: String, keyID: String = VaultConnectorKey.keyID,
                     to publicKey: Curve25519.KeyAgreement.PublicKey? = nil) throws -> Data {
        let to = try publicKey ?? pinnedPublicKey()
        var sender = try HPKE.Sender(recipientKey: to, ciphersuite: suite, info: info(keyID: keyID))
        let ciphertext = try sender.seal(Data(secret.utf8))
        return sender.encapsulatedKey + ciphertext
    }

    /// The connector's side, here for the tests and as the reference for the backend lane.
    static func open(_ sealed: Data, keyID: String, with privateKey: Curve25519.KeyAgreement.PrivateKey) throws -> String {
        guard sealed.count > 32 + 16 else { throw Failure.tooShort }
        var recipient = try HPKE.Recipient(privateKey: privateKey, ciphersuite: suite, info: info(keyID: keyID),
                                           encapsulatedKey: sealed.prefix(32))
        let plain = try recipient.open(sealed.dropFirst(32))
        guard let s = String(data: plain, encoding: .utf8) else { throw Failure.notUtf8 }
        return s
    }
}
