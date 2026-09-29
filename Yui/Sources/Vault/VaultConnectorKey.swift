import Foundation

/// The hosted connector's vault public key (spec/VAULT.md section 4), pinned in the app.
/// Keys are sealed to it (HPKE) when a grant is made. The one place the constant lives.
///
/// Published at /.well-known/yui-vault.json ({key_id, public_key, rotated_at}); the private half is the
/// yui-vault function secret and never in this repository.
enum VaultConnectorKey {
    /// The id blobs carry (`yui_vault_keys.key_id`) and the HPKE info string names.
    static let keyID = "yvk-1"
    /// X25519 public key, base64 of the 32 raw bytes.
    static let publicKeyBase64 = "tJvEIAAfPdMGaIdSKOvBFdXJG8a25svLdnGvyUZ4SD8="
}
