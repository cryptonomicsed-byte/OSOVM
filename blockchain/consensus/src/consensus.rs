// **BFT Consensus Engine**
// Byzantine Fault Tolerant block production and finality

use crate::block::{Block, BlockHeader, Transaction};
use crate::crypto::Ed25519Verifier;
use crate::error::{ConsensusError, Result};
use crate::state::State;
use crate::validator::ValidatorSet;
use parking_lot::RwLock;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

/// BFT Consensus engine (2/3 threshold voting)
pub struct BFTConsensus {
    /// This node's ID
    pub node_id: String,
    /// Current validator set
    pub validator_set: ValidatorSet,
    /// Current round number
    pub round: Arc<RwLock<u64>>,
    /// Current phase (Propose, Prevote, Precommit)
    pub phase: Arc<RwLock<BFTPhase>>,
    /// Accumulated votes for current block
    pub votes: Arc<RwLock<BlockVotes>>,
    /// Cryptographic verifier
    pub crypto: Ed25519Verifier,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum BFTPhase {
    /// Waiting for proposal
    NewRound,
    /// Proposer has broadcast a block
    Propose,
    /// Validators broadcast prevotes
    Prevote,
    /// Validators broadcast precommits
    Precommit,
    /// Block is committed
    Commit,
}

/// Votes accumulated for a block candidate
#[derive(Clone, Debug)]
pub struct BlockVotes {
    /// Block hash being voted on
    pub block_hash: Option<[u8; 32]>,
    /// Prevotes (from validators)
    pub prevotes: std::collections::HashMap<String, bool>,
    /// Precommits (from validators)
    pub precommits: std::collections::HashMap<String, bool>,
}

impl BlockVotes {
    pub fn new() -> Self {
        Self {
            block_hash: None,
            prevotes: std::collections::HashMap::new(),
            precommits: std::collections::HashMap::new(),
        }
    }

    pub fn add_prevote(&mut self, validator: String) {
        self.prevotes.insert(validator, true);
    }

    pub fn add_precommit(&mut self, validator: String) {
        self.precommits.insert(validator, true);
    }

    pub fn prevote_count(&self) -> u64 {
        self.prevotes.len() as u64
    }

    pub fn precommit_count(&self) -> u64 {
        self.precommits.len() as u64
    }

    pub fn has_polka(&self, threshold: u64) -> bool {
        self.prevote_count() >= threshold
    }

    pub fn has_commit(&self, threshold: u64) -> bool {
        self.precommit_count() >= threshold
    }

    pub fn reset(&mut self) {
        self.block_hash = None;
        self.prevotes.clear();
        self.precommits.clear();
    }
}

impl BFTConsensus {
    pub fn new(node_id: String, validator_set: ValidatorSet) -> Self {
        Self {
            node_id,
            validator_set,
            round: Arc::new(RwLock::new(0)),
            phase: Arc::new(RwLock::new(BFTPhase::NewRound)),
            votes: Arc::new(RwLock::new(BlockVotes::new())),
            crypto: Ed25519Verifier::new(),
        }
    }

    /// Propose a new block
    pub async fn propose_block(
        &self,
        state: &mut State,
        transactions: Vec<Transaction>,
    ) -> Result<Block> {
        // Only proposer can propose (in real implementation, would be round-robin)
        if !self.is_proposer() {
            return Err(ConsensusError::Internal(
                "only proposer can create blocks".to_string(),
            ));
        }

        // Validate all transactions
        for tx in &transactions {
            state.validate_transaction(tx)?;
        }

        // Calculate merkle root
        let merkle_root = Ed25519Verifier::hash_transactions(&transactions);

        // Create block header
        let header = BlockHeader::new(
            state.block_height + 1,
            [0u8; 32], // Parent hash (would be from previous block)
            current_timestamp(),
            state.root_hash,
            merkle_root,
            Self::hash_validator_set(&self.validator_set),
        );

        Ok(Block::new(header, transactions))
    }

    /// Validate state transitions (would call Julia state machine)
    pub async fn validate_state_transitions(&self, state: &State, block: &Block) -> Result<()> {
        // For now, just validate each transaction
        for tx in &block.transactions {
            state.validate_transaction(tx)?;
        }

        // In production: call Julia executor to verify economic invariants
        // let result = julia_execute_block(state, block)?;
        // verify_state_transition(result)?;

        Ok(())
    }

    /// Finalize a block (apply to state, record in history)
    pub async fn finalize_block(&self, state: &mut State, block: Block) -> Result<()> {
        // Apply transactions to state
        for tx in &block.transactions {
            match tx {
                Transaction::Transfer { from, to, amount, .. } => {
                    state.transfer(from, to, *amount)?;
                }
                Transaction::TechGnosDeploy { sender, bytecode, .. } => {
                    // In production: would create contract address
                    let contract_addr = format!("{}_contract_{}", sender, state.block_height);
                    state.deploy_contract(&contract_addr, bytecode.clone())?;
                }
                _ => {
                    // Other transaction types handled elsewhere
                }
            }

            // Increment sender nonce
            let sender = tx.sender();
            state.get_or_create_account(sender).nonce += 1;
        }

        // Commit block to state
        state.commit_block([0u8; 32])?;

        Ok(())
    }

    /// Check if this node is the proposer for this round
    fn is_proposer(&self) -> bool {
        let round = self.round.read();
        let proposer_index = (*round as usize) % self.validator_set.len();
        let proposer = &self.validator_set.validators()[proposer_index];
        proposer.address == self.node_id
    }

    /// Hash validator set (for validator_set_hash in block header)
    fn hash_validator_set(validator_set: &ValidatorSet) -> u64 {
        let mut hasher = std::collections::hash_map::DefaultHasher::default();
        use std::hash::{Hash, Hasher};
        for validator in validator_set.validators() {
            validator.address.hash(&mut hasher);
        }
        hasher.finish()
    }

    /// Move to next round
    pub fn next_round(&self) {
        let mut round = self.round.write();
        *round += 1;

        let mut phase = self.phase.write();
        *phase = BFTPhase::NewRound;

        let mut votes = self.votes.write();
        votes.reset();
    }

    /// Get current round
    pub fn current_round(&self) -> u64 {
        *self.round.read()
    }

    /// Get current phase
    pub fn current_phase(&self) -> BFTPhase {
        self.phase.read().clone()
    }

    /// Record a prevote
    pub fn add_prevote(&self, validator: String) -> Result<()> {
        let mut votes = self.votes.write();
        votes.add_prevote(validator);

        let mut phase = self.phase.write();
        *phase = BFTPhase::Prevote;

        Ok(())
    }

    /// Record a precommit
    pub fn add_precommit(&self, validator: String) -> Result<()> {
        let mut votes = self.votes.write();
        votes.add_precommit(validator);

        let mut phase = self.phase.write();
        *phase = BFTPhase::Precommit;

        Ok(())
    }

    /// Check if we have a polka (2/3+ prevotes)
    pub fn has_polka(&self) -> bool {
        let votes = self.votes.read();
        votes.has_polka(self.validator_set.threshold())
    }

    /// Check if we have a commit (2/3+ precommits)
    pub fn has_commit(&self) -> bool {
        let votes = self.votes.read();
        votes.has_commit(self.validator_set.threshold())
    }
}

impl Default for BlockVotes {
    fn default() -> Self {
        Self::new()
    }
}

/// Get current Unix timestamp in milliseconds
fn current_timestamp() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::validator::Validator;

    #[test]
    fn test_consensus_creation() {
        let validators = vec![
            Validator::new("node_1".to_string(), [1u8; 32]),
            Validator::new("node_2".to_string(), [2u8; 32]),
            Validator::new("node_3".to_string(), [3u8; 32]),
        ];
        let validator_set = ValidatorSet::new(validators, 3).unwrap();
        let consensus = BFTConsensus::new("node_1".to_string(), validator_set);

        assert_eq!(consensus.current_round(), 0);
        assert_eq!(consensus.current_phase(), BFTPhase::NewRound);
    }

    #[test]
    fn test_round_increment() {
        let validators = vec![
            Validator::new("node_1".to_string(), [1u8; 32]),
            Validator::new("node_2".to_string(), [2u8; 32]),
            Validator::new("node_3".to_string(), [3u8; 32]),
        ];
        let validator_set = ValidatorSet::new(validators, 3).unwrap();
        let consensus = BFTConsensus::new("node_1".to_string(), validator_set);

        assert_eq!(consensus.current_round(), 0);
        consensus.next_round();
        assert_eq!(consensus.current_round(), 1);
    }

    #[test]
    fn test_block_votes() {
        let mut votes = BlockVotes::new();
        votes.add_prevote("validator_1".to_string());
        votes.add_prevote("validator_2".to_string());

        assert_eq!(votes.prevote_count(), 2);
    }

    #[tokio::test]
    async fn test_propose_block() {
        let validators = vec![
            Validator::new("node_1".to_string(), [1u8; 32]),
            Validator::new("node_2".to_string(), [2u8; 32]),
        ];
        let validator_set = ValidatorSet::new(validators, 3).unwrap();
        let consensus = BFTConsensus::new("node_1".to_string(), validator_set);

        let mut state = State::new();
        state.update_balance("alice", 1000).unwrap();

        let tx = Transaction::Transfer {
            from: "alice".to_string(),
            to: "bob".to_string(),
            amount: 100,
            nonce: 0,
        };

        let result = consensus.propose_block(&mut state, vec![tx]).await;
        assert!(result.is_ok());
    }
}
