//! Ed25519 signing for witness attestations.
//!
//! Uses ed25519-dalek (RFC 8032), which is byte-for-byte compatible with Sui's
//! `sui::ed25519::ed25519_verify`. A signature over the primary sensor's
//! `data_hash` produced here verifies on-chain with no adapter.

use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use rand::rngs::OsRng;

pub const PUBLIC_KEY_LEN: usize = 32;
pub const SIGNATURE_LEN: usize = 64;

/// Generate a fresh Ed25519 keypair from the OS RNG.
/// Returns (secret_seed_32_bytes, public_key_32_bytes).
pub fn generate_keypair() -> ([u8; 32], [u8; 32]) {
    let signing = SigningKey::generate(&mut OsRng);
    let secret = signing.to_bytes();
    let public = signing.verifying_key().to_bytes();
    (secret, public)
}

/// Decode a hex secret seed (32 bytes) into a SigningKey.
pub fn decode_secret(hex_secret: &str) -> Result<SigningKey, String> {
    let bytes = hex::decode(hex_secret.trim()).map_err(|e| format!("bad secret hex: {e}"))?;
    let len = bytes.len();
    let arr: [u8; 32] = bytes
        .try_into()
        .map_err(|_| format!("secret must be 32 bytes (got {len})"))?;
    Ok(SigningKey::from_bytes(&arr))
}

/// Decode a hex public key (32 bytes) into a VerifyingKey.
pub fn decode_public(hex_public: &str) -> Result<VerifyingKey, String> {
    let bytes = hex::decode(hex_public.trim()).map_err(|e| format!("bad public hex: {e}"))?;
    let len = bytes.len();
    let arr: [u8; 32] = bytes
        .try_into()
        .map_err(|_| format!("public key must be 32 bytes (got {len})"))?;
    VerifyingKey::from_bytes(&arr).map_err(|e| format!("invalid public key: {e}"))
}

/// Sign a message (e.g. the primary sensor's data_hash) with a secret seed.
/// Returns the 64-byte Ed25519 signature.
pub fn sign_data_hash(secret: &SigningKey, data_hash: &[u8]) -> [u8; 64] {
    let sig: Signature = secret.sign(data_hash);
    sig.to_bytes()
}

/// Verify an Ed25519 signature over a message. Mirrors on-chain verification.
pub fn verify_data_hash(public: &VerifyingKey, data_hash: &[u8], signature: &[u8; 64]) -> bool {
    let sig = Signature::from_bytes(signature);
    public.verify(data_hash, &sig).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keypair_lengths_match_contract() {
        let (secret, public) = generate_keypair();
        assert_eq!(secret.len(), 32);
        assert_eq!(public.len(), PUBLIC_KEY_LEN);
    }

    #[test]
    fn signature_roundtrip() {
        let (secret_hex, public_hex) = {
            let (s, p) = generate_keypair();
            (hex::encode(s), hex::encode(p))
        };
        let data_hash = hex::decode("a3c5b7d9e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c").unwrap();

        let secret = decode_secret(&secret_hex).unwrap();
        let public = decode_public(&public_hex).unwrap();
        let sig = sign_data_hash(&secret, &data_hash);
        assert_eq!(sig.len(), SIGNATURE_LEN);
        assert!(verify_data_hash(&public, &data_hash, &sig), "valid signature must verify");
    }

    #[test]
    fn wrong_message_fails() {
        let (s, p) = generate_keypair();
        let secret = SigningKey::from_bytes(&s);
        let public = VerifyingKey::from_bytes(&p).unwrap();
        let sig = sign_data_hash(&secret, b"right-message");
        assert!(!verify_data_hash(&public, b"wrong-message", &sig), "tampered message must fail");
    }

    #[test]
    fn wrong_key_fails() {
        let (s, _) = generate_keypair();
        let (_, other_p) = generate_keypair();
        let secret = SigningKey::from_bytes(&s);
        let other_public = VerifyingKey::from_bytes(&other_p).unwrap();
        let sig = sign_data_hash(&secret, b"msg");
        assert!(!verify_data_hash(&other_public, b"msg", &sig), "wrong key must fail");
    }
}
