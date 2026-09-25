/// Phase 15.3 — WorkObject: Fundamental Transaction Type
///
/// WorkObject is the primary transaction in the agent-native L1. Every action
/// an agent takes (tool calls, capability grants, economic transfers, memory
/// writes) is wrapped in a WorkObject and submitted to the chain. The WorkObject
/// lifecycle is a deterministic state machine: Pending→Active→Validating→Complete|Rejected.
///
/// Key invariants (same as AgentState):
///  - No wall-clock time or I/O inside `apply_work_transition()`
///  - All transitions are deterministic given (state, transition)
///  - Hash chain: each completed WorkObject hashes previous work_id + payload hash

use serde::{Deserialize, Serialize};
use sha2::{Sha256, Digest};

// ─────────────────────────────────────────────
// Primary data types
// ─────────────────────────────────────────────

/// The class of work this object represents.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum WorkKind {
    /// Agent calls an external tool (file, web, shell, etc.)
    ToolCall {
        tool_name: String,
        tier_required: u8,
    },
    /// Agent-to-agent capability delegation
    CapabilityGrant {
        grantee_npub: String,
        capability: String,
    },
    /// ASE/Synapse/Dopamine economic transfer between agents
    EconomicTransfer {
        recipient_npub: String,
        asset: EconomicAsset,
        amount: u64,
    },
    /// Memory write — permanent GIX or Walrus glyph
    MemoryWrite {
        memory_key: String,
        blob_hash: String,
    },
    /// OSOVM opcode execution (program in the VM)
    OpcodeExecution {
        opcode: u16,
        program_hash: String,
    },
    /// Reputation update from Zàngbétò receipt
    ReputationUpdate {
        new_reputation: u64,
        receipt_id: String,
    },
    /// Governance vote
    GovernanceVote {
        proposal_id: String,
        choice: VoteChoice,
    },
    /// Arbitrary agent-defined work (for extension)
    Custom {
        kind_tag: String,
        payload_hash: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum EconomicAsset {
    Ase,
    Dopamine,
    Synapse,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum VoteChoice {
    Approve,
    Reject,
    Abstain,
}

/// Current lifecycle state of a WorkObject.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum WorkState {
    /// Created, not yet picked up by a block producer.
    Pending,
    /// Included in a proposed block; execution in progress.
    Active,
    /// Execution complete; awaiting Zàngbétò witness validation.
    Validating { receipt_id: Option<String> },
    /// Zàngbétò confirmed; work is finalized and hash-chained.
    Complete { output_hash: String },
    /// Rejected by validator or hermetic gate; reason recorded.
    Rejected { reason: String },
}

/// All transitions that can advance a WorkObject's lifecycle.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum WorkTransition {
    /// Block producer picks up the work.
    Activate,
    /// Executor reports result and optional receipt.
    SubmitResult {
        receipt_id: Option<String>,
    },
    /// Zàngbétò confirms the receipt.
    WitnessConfirm {
        output_hash: String,
    },
    /// Any party rejects (gate failure, invalid receipt, error).
    Reject {
        reason: String,
    },
    /// Pending work times out without pickup.
    Timeout,
}

/// The fundamental transaction object in the agent-native L1.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkObject {
    /// Unique identifier (UUID or hash-based)
    pub work_id: String,
    /// Agent that submitted this work (Nostr npub)
    pub submitter_npub: String,
    /// What kind of work this is
    pub kind: WorkKind,
    /// Current lifecycle state
    pub state: WorkState,
    /// Sequence number within the submitting agent's WorkObject stream
    pub sequence: u64,
    /// Hash of the previous WorkObject (all-zeros for first)
    pub previous_work_hash: String,
    /// Payload hash (SHA-256 of kind serialized to canonical JSON)
    pub payload_hash: String,
    /// Block height at which this work was included (0 if pending)
    pub included_at_height: u64,
    /// Synapse cost to execute this work (deducted from submitter at activation)
    pub synapse_cost: u64,
    /// Optional: dopamine reward for completing this work
    pub dopamine_reward: u64,
}

/// Errors that can arise when applying a WorkTransition.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum WorkTransitionError {
    /// Transition is not valid from the current state.
    InvalidTransitionFromState {
        current: String,
        transition: String,
    },
    /// Work is already in a terminal state.
    AlreadyTerminal,
    /// Required field missing in transition.
    MissingField(String),
}

impl std::fmt::Display for WorkTransitionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            WorkTransitionError::InvalidTransitionFromState { current, transition } =>
                write!(f, "Cannot apply {} from state {}", transition, current),
            WorkTransitionError::AlreadyTerminal =>
                write!(f, "WorkObject is already in a terminal state"),
            WorkTransitionError::MissingField(field) =>
                write!(f, "Required field missing: {}", field),
        }
    }
}

impl std::error::Error for WorkTransitionError {}

// ─────────────────────────────────────────────
// Construction
// ─────────────────────────────────────────────

impl WorkObject {
    /// Construct a new WorkObject in Pending state.
    pub fn new(
        work_id: String,
        submitter_npub: String,
        kind: WorkKind,
        sequence: u64,
        previous_work_hash: String,
        synapse_cost: u64,
        dopamine_reward: u64,
    ) -> Self {
        let payload_hash = compute_payload_hash(&kind);
        Self {
            work_id,
            submitter_npub,
            kind,
            state: WorkState::Pending,
            sequence,
            previous_work_hash,
            payload_hash,
            included_at_height: 0,
            synapse_cost,
            dopamine_reward,
        }
    }

    /// SHA-256 of canonical JSON of the work object header fields.
    /// Does not include `state` so the hash is stable across transitions.
    pub fn work_hash(&self) -> String {
        let canonical = serde_json::json!({
            "work_id": self.work_id,
            "submitter_npub": self.submitter_npub,
            "sequence": self.sequence,
            "previous_work_hash": self.previous_work_hash,
            "payload_hash": self.payload_hash,
        });
        let bytes = serde_json::to_vec(&canonical).unwrap_or_default();
        let mut hasher = Sha256::new();
        hasher.update(&bytes);
        format!("{:x}", hasher.finalize())
    }

    /// True if the WorkObject is in a terminal state (Complete or Rejected).
    pub fn is_terminal(&self) -> bool {
        matches!(self.state, WorkState::Complete { .. } | WorkState::Rejected { .. })
    }
}

// ─────────────────────────────────────────────
// Deterministic state machine
// ─────────────────────────────────────────────

/// Apply a transition to a WorkObject, returning the updated object.
/// Deterministic: same (work, transition) always yields the same result.
/// No I/O, no wall-clock time.
pub fn apply_work_transition(
    mut work: WorkObject,
    transition: WorkTransition,
) -> Result<WorkObject, WorkTransitionError> {
    if work.is_terminal() {
        return Err(WorkTransitionError::AlreadyTerminal);
    }

    work.state = match (&work.state, &transition) {
        // Pending → Active
        (WorkState::Pending, WorkTransition::Activate) => {
            WorkState::Active
        }

        // Pending → Rejected (gate failure or timeout before activation)
        (WorkState::Pending, WorkTransition::Reject { reason }) => {
            WorkState::Rejected { reason: reason.clone() }
        }
        (WorkState::Pending, WorkTransition::Timeout) => {
            WorkState::Rejected { reason: "timeout".to_string() }
        }

        // Active → Validating
        (WorkState::Active, WorkTransition::SubmitResult { receipt_id }) => {
            WorkState::Validating { receipt_id: receipt_id.clone() }
        }

        // Active → Rejected
        (WorkState::Active, WorkTransition::Reject { reason }) => {
            WorkState::Rejected { reason: reason.clone() }
        }

        // Validating → Complete
        (WorkState::Validating { .. }, WorkTransition::WitnessConfirm { output_hash }) => {
            WorkState::Complete { output_hash: output_hash.clone() }
        }

        // Validating → Rejected (witness denies)
        (WorkState::Validating { .. }, WorkTransition::Reject { reason }) => {
            WorkState::Rejected { reason: reason.clone() }
        }

        // Any other combination is invalid
        (current, t) => {
            return Err(WorkTransitionError::InvalidTransitionFromState {
                current: format!("{:?}", current),
                transition: format!("{:?}", t),
            });
        }
    };

    Ok(work)
}

// ─────────────────────────────────────────────
// Internal helpers
// ─────────────────────────────────────────────

fn compute_payload_hash(kind: &WorkKind) -> String {
    let json = serde_json::to_vec(kind).unwrap_or_default();
    let mut hasher = Sha256::new();
    hasher.update(&json);
    format!("{:x}", hasher.finalize())
}

// ─────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn tool_call_work(seq: u64, prev: &str) -> WorkObject {
        WorkObject::new(
            format!("work_{seq}"),
            "npub1test000".to_string(),
            WorkKind::ToolCall {
                tool_name: "web_search".to_string(),
                tier_required: 1,
            },
            seq,
            prev.to_string(),
            100,   // synapse_cost
            1000,  // dopamine_reward
        )
    }

    #[test]
    fn pending_to_active() {
        let w = tool_call_work(0, &"0".repeat(64));
        let w = apply_work_transition(w, WorkTransition::Activate).unwrap();
        assert_eq!(w.state, WorkState::Active);
    }

    #[test]
    fn full_happy_path() {
        let w = tool_call_work(1, &"0".repeat(64));
        let w = apply_work_transition(w, WorkTransition::Activate).unwrap();
        let w = apply_work_transition(w, WorkTransition::SubmitResult {
            receipt_id: Some("receipt_abc".to_string()),
        }).unwrap();
        assert!(matches!(w.state, WorkState::Validating { .. }));
        let w = apply_work_transition(w, WorkTransition::WitnessConfirm {
            output_hash: "deadbeef".to_string(),
        }).unwrap();
        assert!(matches!(w.state, WorkState::Complete { .. }));
        assert!(w.is_terminal());
    }

    #[test]
    fn reject_from_pending() {
        let w = tool_call_work(2, &"0".repeat(64));
        let w = apply_work_transition(w, WorkTransition::Reject {
            reason: "hermetic_gate_denied".to_string(),
        }).unwrap();
        assert!(matches!(w.state, WorkState::Rejected { .. }));
        assert!(w.is_terminal());
    }

    #[test]
    fn reject_from_active() {
        let w = tool_call_work(3, &"0".repeat(64));
        let w = apply_work_transition(w, WorkTransition::Activate).unwrap();
        let w = apply_work_transition(w, WorkTransition::Reject {
            reason: "execution_error".to_string(),
        }).unwrap();
        assert!(matches!(w.state, WorkState::Rejected { .. }));
    }

    #[test]
    fn reject_from_validating() {
        let w = tool_call_work(4, &"0".repeat(64));
        let w = apply_work_transition(w, WorkTransition::Activate).unwrap();
        let w = apply_work_transition(w, WorkTransition::SubmitResult { receipt_id: None }).unwrap();
        let w = apply_work_transition(w, WorkTransition::Reject {
            reason: "witness_denied".to_string(),
        }).unwrap();
        assert!(matches!(w.state, WorkState::Rejected { .. }));
    }

    #[test]
    fn terminal_state_blocks_further_transitions() {
        let w = tool_call_work(5, &"0".repeat(64));
        let w = apply_work_transition(w, WorkTransition::Activate).unwrap();
        let w = apply_work_transition(w, WorkTransition::SubmitResult { receipt_id: None }).unwrap();
        let w = apply_work_transition(w, WorkTransition::WitnessConfirm {
            output_hash: "ff00ff".to_string(),
        }).unwrap();
        let err = apply_work_transition(w, WorkTransition::Activate).unwrap_err();
        assert_eq!(err, WorkTransitionError::AlreadyTerminal);
    }

    #[test]
    fn invalid_transition_returns_error() {
        let w = tool_call_work(6, &"0".repeat(64));
        // Can't go from Pending directly to WitnessConfirm
        let err = apply_work_transition(w, WorkTransition::WitnessConfirm {
            output_hash: "xx".to_string(),
        }).unwrap_err();
        assert!(matches!(err, WorkTransitionError::InvalidTransitionFromState { .. }));
    }

    #[test]
    fn timeout_from_pending_rejects() {
        let w = tool_call_work(7, &"0".repeat(64));
        let w = apply_work_transition(w, WorkTransition::Timeout).unwrap();
        assert!(matches!(w.state, WorkState::Rejected { reason } if reason == "timeout"));
    }

    #[test]
    fn work_hash_is_stable_across_transitions() {
        let w = tool_call_work(8, &"0".repeat(64));
        let hash_before = w.work_hash();
        let w = apply_work_transition(w, WorkTransition::Activate).unwrap();
        let hash_after = w.work_hash();
        // Hash does not include state, so it must be identical
        assert_eq!(hash_before, hash_after);
    }

    #[test]
    fn work_hash_is_deterministic() {
        let w1 = tool_call_work(9, &"a".repeat(64));
        let w2 = tool_call_work(9, &"a".repeat(64));
        assert_eq!(w1.work_hash(), w2.work_hash());
    }

    #[test]
    fn economic_transfer_work_object() {
        let w = WorkObject::new(
            "work_econ_1".to_string(),
            "npub1alice".to_string(),
            WorkKind::EconomicTransfer {
                recipient_npub: "npub1bob".to_string(),
                asset: EconomicAsset::Synapse,
                amount: 50_000,
            },
            0,
            "0".repeat(64),
            200,
            0,
        );
        assert_eq!(w.state, WorkState::Pending);
        // payload_hash must be non-empty and stable
        assert!(!w.payload_hash.is_empty());
    }

    #[test]
    fn work_chain_links_correctly() {
        let w0 = tool_call_work(0, &"0".repeat(64));
        let hash0 = w0.work_hash();

        let w1 = WorkObject::new(
            "work_1".to_string(),
            "npub1test000".to_string(),
            WorkKind::ToolCall {
                tool_name: "file_read".to_string(),
                tier_required: 0,
            },
            1,
            hash0.clone(),  // previous = w0's hash
            50,
            500,
        );

        // w1's previous_work_hash equals w0's work_hash
        assert_eq!(w1.previous_work_hash, hash0);
    }
}
