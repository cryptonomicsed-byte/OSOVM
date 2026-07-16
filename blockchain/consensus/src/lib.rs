// **Ọ̀ṢỌ́ CONSENSUS LAYER**
// Native blockchain consensus engine (BFT)
// 🛡️🌀⚛️🕯️🔥

pub mod block;
pub mod validator;
pub mod consensus;
pub mod crypto;
pub mod messages;
pub mod state;
pub mod error;

pub use block::{Block, BlockHeader, Transaction};
pub use validator::{Validator, ValidatorSet};
pub use consensus::BFTConsensus;
pub use crypto::Ed25519Verifier;
pub use messages::{Message, ConsensusMessage};
pub use state::State;
pub use error::{ConsensusError, Result};

/// Ọ̀ṢỌ́ Consensus Node
/// Orchestrates BFT validation, block production, and finality
pub struct OsoConsensusNode {
    pub consensus: BFTConsensus,
    pub state: State,
    pub validator_set: ValidatorSet,
    pub crypto: Ed25519Verifier,
}

impl OsoConsensusNode {
    /// Initialize a new consensus node
    pub fn new(
        node_id: String,
        validators: Vec<Validator>,
        threshold: u64,
    ) -> Result<Self> {
        let validator_set = ValidatorSet::new(validators, threshold)?;
        let consensus = BFTConsensus::new(node_id, validator_set.clone());
        let state = State::new();
        let crypto = Ed25519Verifier::new();

        Ok(Self {
            consensus,
            state,
            validator_set,
            crypto,
        })
    }

    /// Propose a new block
    pub async fn propose_block(&mut self, transactions: Vec<Transaction>) -> Result<Block> {
        self.consensus
            .propose_block(&mut self.state, transactions)
            .await
    }

    /// Validate an incoming block
    pub async fn validate_block(&self, block: &Block) -> Result<()> {
        // 1. Verify block structure
        block.verify_structure()?;

        // 2. Verify signatures
        self.crypto.verify_block_signatures(block, &self.validator_set)?;

        // 3. Verify state transitions
        self.consensus
            .validate_state_transitions(&self.state, block)
            .await?;

        Ok(())
    }

    /// Finalize a block (achieve consensus)
    pub async fn finalize_block(&mut self, block: Block) -> Result<()> {
        self.consensus
            .finalize_block(&mut self.state, block)
            .await
    }

    /// Get current state root
    pub fn state_root(&self) -> [u8; 32] {
        self.state.root_hash()
    }

    /// Get current block height
    pub fn block_height(&self) -> u64 {
        self.state.block_height()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_node_creation() {
        let validators = vec![
            Validator::new("validator_1".to_string(), [0u8; 32]),
            Validator::new("validator_2".to_string(), [1u8; 32]),
        ];

        let node = OsoConsensusNode::new("node_1".to_string(), validators, 2);
        assert!(node.is_ok());
    }
}
