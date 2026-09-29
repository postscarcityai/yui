// Seals a key the way the app will (CryptoKit HPKE, Curve25519_SHA256_ChachaPoly)
// so the proxy's opener can be checked against the real implementation.
//   swift seal_interop.swift <connector public key, base64> <key id> <plaintext>
// Prints base64(enc || ciphertext || tag).
import CryptoKit
import Foundation

let a = CommandLine.arguments
guard a.count == 4, let pub = Data(base64Encoded: a[1]) else { FileHandle.standardError.write(Data("usage\n".utf8)); exit(2) }
let key = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pub)
var sender = try HPKE.Sender(recipientKey: key, ciphersuite: .Curve25519_SHA256_ChachaPoly, info: Data(("yui-vault-v1|" + a[2]).utf8))
let ct = try sender.seal(Data(a[3].utf8))
print((sender.encapsulatedKey + ct).base64EncodedString())
