// **Cryptographic operations for Ọ̀ṢỌ́ consensus**
// Ed25519 signatures, SHA-256 hashing

use crate::error::{ConsensusError, Result};
use crate::{Block, ValidatorSet};
use ed25519_dalek::{Signature, VerifyingKey, Verifier};
use sha2::{Digest, Sha256};
use std::collections::HashMap;

/// Ed25519 signature verifier
#[derive(Clone)]
pub struct Ed25519Verifier {
    /// Cache of validator pubkeys (address → pubkey)
    pubkey_cache: HashMap<String, VerifyingKey>,
}

impl Ed25519Verifier {
    pub fn new() -> Self {
        Self {
            pubkey_cache: HashMap::new(),
        }
    }

    /// Load a validator's public key
    pub fn load_pubkey(&mut self, address: String, pubkey_bytes: &[u8]) -> Result<()> {
        if pubkey_bytes.len() != 32 {
            return Err(ConsensusError::InvalidPublicKey);
        }

        let pubkey_arr: [u8; 32] = pubkey_bytes
            .try_into()
            .map_err(|_| ConsensusError::InvalidPublicKey)?;
        let pubkey = VerifyingKey::from_bytes(&pubkey_arr)
            .map_err(|_| ConsensusError::InvalidPublicKey)?;

        self.pubkey_cache.insert(address, pubkey);
        Ok(())
    }

    /// Verify a single signature
    pub fn verify_signature(
        &self,
        address: &str,
        message: &[u8],
        signature_bytes: &[u8],
    ) -> Result<()> {
        let pubkey = self
            .pubkey_cache
            .get(address)
            .ok_or_else(|| ConsensusError::InvalidValidator(address.to_string()))?;

        let sig_arr: [u8; 64] = signature_bytes
            .try_into()
            .map_err(|_| ConsensusError::InvalidSignature("malformed signature".to_string()))?;
        let sig = Signature::from_bytes(&sig_arr);

        pubkey
            .verify(message, &sig)
            .map_err(|_| ConsensusError::InvalidSignature("signature verification failed".to_string()))
    }

    /// Verify block signatures
    pub fn verify_block_signatures(
        &self,
        block: &Block,
        validator_set: &ValidatorSet,
    ) -> Result<()> {
        // Require minimum threshold of signatures
        let required_sigs = validator_set.threshold();
        let provided_sigs = block.header.signatures.len() as u64;

        if provided_sigs < required_sigs {
            return Err(ConsensusError::InsufficientSignatures {
                required: required_sigs,
                actual: provided_sigs,
            });
        }

        // Message to sign = block header hash
        let message = Self::hash_block_header(&block.header);

        // Verify each signature
        for (validator_address, signature) in &block.header.signatures {
            // Verify validator is in set
            if !validator_set.contains_validator(validator_address) {
                return Err(ConsensusError::ValidatorNotInSet(
                    validator_address.clone(),
                ));
            }

            // Verify signature
            self.verify_signature(validator_address, &message, signature)?;
        }

        Ok(())
    }

    /// Hash block header
    pub fn hash_block_header(header: &crate::block::BlockHeader) -> Vec<u8> {
        let mut hasher = Sha256::new();
        hasher.update(header.block_num.to_le_bytes());
        hasher.update(&header.parent_hash);
        hasher.update(header.timestamp.to_le_bytes());
        hasher.update(&header.state_root);
        hasher.update(&header.merkle_root);
        hasher.update(header.validator_set_hash.to_le_bytes());
        hasher.finalize().to_vec()
    }

    /// Hash a transaction
    pub fn hash_transaction(tx: &crate::block::Transaction) -> Vec<u8> {
        let mut hasher = Sha256::new();
        hasher.update(&bincode::serialize(tx).unwrap_or_default());
        hasher.finalize().to_vec()
    }

    /// Hash a list of transactions (merkle root)
    pub fn hash_transactions(transactions: &[crate::block::Transaction]) -> [u8; 32] {
        let hashes: Vec<Vec<u8>> = transactions.iter().map(Self::hash_transaction).collect();

        let mut root = Self::hash_pair(hashes.first().map(|h| h.as_slice()).unwrap_or(&[]), &[]);

        for hash in hashes.iter().skip(1) {
            root = Self::hash_pair(&root, hash.as_slice());
        }

        let mut arr = [0u8; 32];
        arr.copy_from_slice(&root[..]);
        arr
    }

    /// Hash a pair of items (merkle tree node)
    fn hash_pair(left: &[u8], right: &[u8]) -> Vec<u8> {
        let mut hasher = Sha256::new();
        hasher.update(left);
        hasher.update(right);
        hasher.finalize().to_vec()
    }

    /// Sign a message (for testing)
    #[cfg(test)]
    pub fn sign_message(
        message: &[u8],
        private_key_bytes: &[u8],
    ) -> Result<[u8; 64]> {
        use ed25519_dalek::{Signer, SigningKey};
        
        let signing_key = SigningKey::from_bytes(&<[u8; 32]>::try_from(private_key_bytes)
            .map_err(|_| ConsensusError::InvalidPublicKey)?);
        let signature = signing_key.sign(message);
        
        Ok(signature.to_bytes())
    }
}

impl Default for Ed25519Verifier {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hash_consistency() {
        let data = b"test data";
        let hash1 = {
            let mut hasher = Sha256::new();
            hasher.update(data);
            hasher.finalize().to_vec()
        };

        let hash2 = {
            let mut hasher = Sha256::new();
            hasher.update(data);
            hasher.finalize().to_vec()
        };

        assert_eq!(hash1, hash2);
    }
}
