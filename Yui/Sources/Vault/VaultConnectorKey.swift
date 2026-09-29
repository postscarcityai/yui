import Foundation

/// The hosted connector's vault public key (spec/VAULT.md section 4), pinned in the app.
/// Keys are sealed to it (HPKE) when a grant is made. The one place the constant lives.
///
/// DEV PLACEHOLDER: this is a throwaway development keypair's public half. The backend lane
/// replaces `publicKeyBase64` and `keyID` with the real connector key, published at
/// /.well-known/yui-vault.json ({key_id, public_key, rotated_at}). Nothing sealed to the dev key
/// is worth anything: its private half is not in this repository and was never a real secret.
enum VaultConnectorKey {
    /// The id blobs carry (`yui_vault_keys.key_id`) and the HPKE info string names.
    static let keyID = "yui-vault-dev-1"
    /// X25519 public key, base64 of the 32 raw bytes.
    static let publicKeyBase64 = "oI2I5LDixBXWzni3wUs2p9heeWJ7qzEYR4wN/RrLZUc="
}
