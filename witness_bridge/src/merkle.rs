//! Deterministic Merkle commitment for sensor data.
//!
//! Matches the ecosystem convention: `leaf(blob) = SHA256(blob)`, binary tree,
//! odd leaf promoted. The root (32 bytes) is the `merkle_root` argument to
//! `proof_of_witness::submit_attestation`.

use sha2::{Digest, Sha256};

/// SHA256 of a single blob — the leaf hash for one checkpoint / sensor reading.
pub fn leaf_hash(blob: &[u8]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(blob);
    h.finalize().into()
}

/// SHA256 of a concatenation (internal node).
fn sha256_pair(left: &[u8], right: &[u8]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(left);
    h.update(right);
    h.finalize().into()
}

/// Compute the Merkle root over an ordered list of leaf hashes (32 bytes each).
/// Odd leaf is promoted (carried up unchanged) to the next level.
/// Empty input returns the zero hash.
pub fn merkle_root(leaves: &[[u8; 32]]) -> [u8; 32] {
    if leaves.is_empty() {
        return [0u8; 32];
    }
    let mut level: Vec<[u8; 32]> = leaves.to_vec();
    while level.len() > 1 {
        let mut next: Vec<[u8; 32]> = Vec::with_capacity((level.len() + 1) / 2);
        for pair in level.chunks(2) {
            if pair.len() == 2 {
                next.push(sha256_pair(&pair[0], &pair[1]));
            } else {
                next.push(pair[0]); // odd leaf promoted
            }
        }
        level = next;
    }
    level[0]
}

/// Compute the Merkle root directly from raw checkpoint blobs (hashes each leaf first).
pub fn merkle_root_from_blobs(blobs: &[&[u8]]) -> [u8; 32] {
    let leaves: Vec<[u8; 32]> = blobs.iter().map(|b| leaf_hash(b)).collect();
    merkle_root(&leaves)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_root_is_zero() {
        assert_eq!(merkle_root(&[]), [0u8; 32]);
    }

    #[test]
    fn single_leaf_root_is_the_leaf() {
        let l = leaf_hash(b"checkpoint-1");
        assert_eq!(merkle_root(&[l]), l);
    }

    #[test]
    fn deterministic_and_order_sensitive() {
        let a = leaf_hash(b"a");
        let b = leaf_hash(b"b");
        let r1 = merkle_root(&[a, b]);
        let r2 = merkle_root(&[a, b]);
        let r3 = merkle_root(&[b, a]);
        assert_eq!(r1, r2, "same inputs -> same root");
        assert_ne!(r1, r3, "different order -> different root");
    }

    #[test]
    fn odd_leaf_promotion_matches_manual() {
        // 3 leaves: pair(a,b) then promote c.
        let a = leaf_hash(b"a");
        let b = leaf_hash(b"b");
        let c = leaf_hash(b"c");
        let ab = sha256_pair(&a, &b);
        let expected = sha256_pair(&ab, &c);
        assert_eq!(merkle_root(&[a, b, c]), expected);
    }
}
