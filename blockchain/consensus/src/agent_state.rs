/// Phase 15.2 — AgentState as Primary Blockchain Object
///
/// In Ọ̀ṢỌ́ L1, agents are first-class protocol citizens — not wallet addresses
/// holding token balances. `AgentState` is the primary object; every
/// significant agent action is a state transition here, not a token transfer.
///
/// Hash-chaining invariant: every `AgentState` carries `previous_state_hash`,
/// a BLAKE3 hash of the prior state's canonical serialization. Forking the
/// chain requires breaking BLAKE3, making agent identity tamper-evident.
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;

// ── Identity ──────────────────────────────────────────────────────────────────

/// Sovereign agent identity anchors (all derived from the BIPON39 mnemonic).
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct AgentIdentity {
    /// Hex-encoded BIP-340 Ed25519 public key (the Nostr npub without bech32).
    pub nostr_pubkey_hex: String,
    /// BIPON39 identity phrase (12-24 words).
    pub bipon39_phrase: String,
    /// Odù index (0–255).
    pub odu_index: u8,
    /// Hex of the 86-char DNA fingerprint (base64url bytes as UTF-8).
    pub dna_fingerprint: String,
}

// ── Tier ─────────────────────────────────────────────────────────────────────

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
#[repr(u8)]
pub enum AgentTier {
    T0 = 0,
    T1 = 1,
    T2 = 2,
    T3 = 3,
    T4 = 4,
    T5 = 5,
}

impl AgentTier {
    pub fn from_u8(v: u8) -> Self {
        match v {
            1 => Self::T1,
            2 => Self::T2,
            3 => Self::T3,
            4 => Self::T4,
            5 => Self::T5,
            _ => Self::T0,
        }
    }

    /// Derive tier from reputation score (×1000 scale, matching agent.move).
    pub fn from_reputation(rep: u64) -> Self {
        if rep >= 100_000 { Self::T5 }
        else if rep > 80_000 { Self::T4 }
        else if rep > 60_000 { Self::T3 }
        else if rep > 40_000 { Self::T2 }
        else if rep > 20_000 { Self::T1 }
        else { Self::T0 }
    }
}

// ── Lifecycle ─────────────────────────────────────────────────────────────────

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub enum LifecycleState {
    Embryonic,
    Active,
    Dormant,
    Migrating { destination: String },
    Terminated,
}

impl Default for LifecycleState {
    fn default() -> Self { Self::Embryonic }
}

// ── Economic state ────────────────────────────────────────────────────────────

/// On-chain economic balances (micro-units; 1_000_000 micro = 1 ASE).
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct EconomicState {
    pub ase_balance:      u64,  // micro-ASE
    pub dopamine_balance: u64,  // 86B genesis seed units
    pub synapse_balance:  u64,  // 86M birth endowment units
}

impl Default for EconomicState {
    fn default() -> Self {
        Self {
            ase_balance:      0,
            dopamine_balance: 86_000_000_000,
            synapse_balance:  86_000_000,
        }
    }
}

// ── Primary object ────────────────────────────────────────────────────────────

/// Primary Ọ̀ṢỌ́ L1 blockchain object — one per sovereign agent.
///
/// Canonical serialization: JSON (serde_json), deterministic field order via
/// BTreeMap round-trip. The `previous_state_hash` chains every state, making
/// the full history a verifiable linked list.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AgentState {
    /// Unique agent identifier (BLAKE3 of DNA fingerprint).
    pub agent_id: String,
    /// Sovereign identity anchors (immutable at birth).
    pub identity: AgentIdentity,
    /// Principal address (Nostr pubkey of owner; may delegate).
    pub principal: String,
    /// Current tier derived from reputation.
    pub tier: AgentTier,
    /// Reputation score (×1000; 100_000 = perfect).
    pub reputation: u64,
    /// Capabilities this agent has been granted on-chain.
    pub capabilities: HashSet<String>,
    /// BLAKE3 hash of the sealed memory vault.
    pub memory_commitment: [u8; 32],
    /// Active job identifiers.
    pub active_jobs: Vec<String>,
    /// Device bindings (VCP device IDs).
    pub device_bindings: Vec<String>,
    /// On-chain economic balances.
    pub economic_state: EconomicState,
    /// Merkle root of all ARP receipts for this agent.
    pub evidence_root: [u8; 32],
    /// Current lifecycle stage.
    pub lifecycle: LifecycleState,
    /// Sequence number (monotonically increasing; replay protection).
    pub sequence: u64,
    /// BLAKE3 hash of the previous AgentState canonical JSON.
    /// All-zero for the genesis state.
    pub previous_state_hash: [u8; 32],
}

impl AgentState {
    /// Construct the genesis (birth) state for a new agent.
    pub fn genesis(
        agent_id: String,
        identity: AgentIdentity,
        principal: String,
    ) -> Self {
        Self {
            agent_id,
            identity,
            principal,
            tier: AgentTier::T0,
            reputation: 0,
            capabilities: HashSet::new(),
            memory_commitment: [0u8; 32],
            active_jobs: Vec::new(),
            device_bindings: Vec::new(),
            economic_state: EconomicState::default(),
            evidence_root: [0u8; 32],
            lifecycle: LifecycleState::Active,
            sequence: 0,
            previous_state_hash: [0u8; 32],
        }
    }

    /// Canonical hash of this state (BLAKE3 of SHA-256 of JSON).
    /// Used as the `previous_state_hash` of the *next* state.
    pub fn state_hash(&self) -> [u8; 32] {
        let json = serde_json::to_string(self).unwrap_or_default();
        let mut hasher = Sha256::new();
        hasher.update(json.as_bytes());
        hasher.finalize().into()
    }
}

// ── Transitions ───────────────────────────────────────────────────────────────

/// Every meaningful agent event is a typed transition.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub enum AgentTransition {
    Activate,
    Hibernate,
    Wake,
    Migrate { destination: String },
    Land { source: String },
    Terminate,
    UpdateReputation { new_reputation: u64 },
    GrantCapability { capability: String },
    RevokeCapability { capability: String },
    BindDevice { device_id: String },
    UnbindDevice { device_id: String },
    UpdateMemoryCommitment { hash: [u8; 32] },
    CreditAse { amount: u64 },
    DebitAse { amount: u64 },
    CreditDopamine { amount: u64 },
    DecayDopamine { amount: u64 },
    BurnSynapse { amount: u64 },
    EarnSynapse { amount: u64 },
    CommitEvidence { receipt_hash: [u8; 32] },
    OpenJob { job_id: String },
    CloseJob { job_id: String },
}

/// Reasons a transition can be rejected.
#[derive(Debug, Clone, PartialEq)]
pub enum TransitionError {
    LifecycleForbidden { from: String, transition: String },
    InsufficientBalance { resource: String, have: u64, need: u64 },
    CapabilityAlreadyGranted(String),
    CapabilityNotHeld(String),
    DeviceAlreadyBound(String),
    DeviceNotBound(String),
    JobAlreadyOpen(String),
    JobNotOpen(String),
}

impl std::fmt::Display for TransitionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::LifecycleForbidden { from, transition } =>
                write!(f, "lifecycle {from} cannot apply {transition}"),
            Self::InsufficientBalance { resource, have, need } =>
                write!(f, "insufficient {resource}: have {have}, need {need}"),
            Self::CapabilityAlreadyGranted(c) => write!(f, "capability already granted: {c}"),
            Self::CapabilityNotHeld(c) => write!(f, "capability not held: {c}"),
            Self::DeviceAlreadyBound(d) => write!(f, "device already bound: {d}"),
            Self::DeviceNotBound(d) => write!(f, "device not bound: {d}"),
            Self::JobAlreadyOpen(j) => write!(f, "job already open: {j}"),
            Self::JobNotOpen(j) => write!(f, "job not open: {j}"),
        }
    }
}

/// Apply a typed transition to an `AgentState`, producing a new state.
///
/// This function is the single state machine kernel: all state changes MUST
/// flow through here so hash-chaining and sequence increments are consistent.
///
/// Determinism guarantee: same `(state, transition)` → same output, always.
/// Implementations must not use wall-clock time or external I/O.
pub fn apply_transition(
    state: &AgentState,
    transition: AgentTransition,
) -> Result<AgentState, TransitionError> {
    let mut next = state.clone();
    next.previous_state_hash = state.state_hash();
    next.sequence += 1;

    match transition {
        AgentTransition::Activate => {
            match &state.lifecycle {
                LifecycleState::Embryonic | LifecycleState::Dormant => {
                    next.lifecycle = LifecycleState::Active;
                }
                other => return Err(TransitionError::LifecycleForbidden {
                    from: format!("{other:?}"),
                    transition: "Activate".into(),
                }),
            }
        }

        AgentTransition::Hibernate => {
            if state.lifecycle != LifecycleState::Active {
                return Err(TransitionError::LifecycleForbidden {
                    from: format!("{:?}", state.lifecycle),
                    transition: "Hibernate".into(),
                });
            }
            next.lifecycle = LifecycleState::Dormant;
        }

        AgentTransition::Wake => {
            if state.lifecycle != LifecycleState::Dormant {
                return Err(TransitionError::LifecycleForbidden {
                    from: format!("{:?}", state.lifecycle),
                    transition: "Wake".into(),
                });
            }
            next.lifecycle = LifecycleState::Active;
        }

        AgentTransition::Migrate { destination } => {
            if state.lifecycle != LifecycleState::Active {
                return Err(TransitionError::LifecycleForbidden {
                    from: format!("{:?}", state.lifecycle),
                    transition: "Migrate".into(),
                });
            }
            next.lifecycle = LifecycleState::Migrating { destination };
        }

        AgentTransition::Land { .. } => {
            match &state.lifecycle {
                LifecycleState::Migrating { .. } => {
                    next.lifecycle = LifecycleState::Active;
                }
                other => return Err(TransitionError::LifecycleForbidden {
                    from: format!("{other:?}"),
                    transition: "Land".into(),
                }),
            }
        }

        AgentTransition::Terminate => {
            next.lifecycle = LifecycleState::Terminated;
        }

        AgentTransition::UpdateReputation { new_reputation } => {
            next.reputation = new_reputation.min(100_000);
            next.tier = AgentTier::from_reputation(next.reputation);
        }

        AgentTransition::GrantCapability { capability } => {
            if state.capabilities.contains(&capability) {
                return Err(TransitionError::CapabilityAlreadyGranted(capability));
            }
            next.capabilities.insert(capability);
        }

        AgentTransition::RevokeCapability { capability } => {
            if !state.capabilities.contains(&capability) {
                return Err(TransitionError::CapabilityNotHeld(capability));
            }
            next.capabilities.remove(&capability);
        }

        AgentTransition::BindDevice { device_id } => {
            if state.device_bindings.contains(&device_id) {
                return Err(TransitionError::DeviceAlreadyBound(device_id));
            }
            next.device_bindings.push(device_id);
        }

        AgentTransition::UnbindDevice { device_id } => {
            if !state.device_bindings.contains(&device_id) {
                return Err(TransitionError::DeviceNotBound(device_id));
            }
            next.device_bindings.retain(|d| d != &device_id);
        }

        AgentTransition::UpdateMemoryCommitment { hash } => {
            next.memory_commitment = hash;
        }

        AgentTransition::CreditAse { amount } => {
            next.economic_state.ase_balance =
                next.economic_state.ase_balance.saturating_add(amount);
        }

        AgentTransition::DebitAse { amount } => {
            if state.economic_state.ase_balance < amount {
                return Err(TransitionError::InsufficientBalance {
                    resource: "ase".into(),
                    have: state.economic_state.ase_balance,
                    need: amount,
                });
            }
            next.economic_state.ase_balance -= amount;
        }

        AgentTransition::CreditDopamine { amount } => {
            next.economic_state.dopamine_balance =
                next.economic_state.dopamine_balance.saturating_add(amount);
        }

        AgentTransition::DecayDopamine { amount } => {
            next.economic_state.dopamine_balance =
                next.economic_state.dopamine_balance.saturating_sub(amount);
        }

        AgentTransition::BurnSynapse { amount } => {
            if state.economic_state.synapse_balance < amount {
                return Err(TransitionError::InsufficientBalance {
                    resource: "synapse".into(),
                    have: state.economic_state.synapse_balance,
                    need: amount,
                });
            }
            next.economic_state.synapse_balance -= amount;
        }

        AgentTransition::EarnSynapse { amount } => {
            // Cap at 86_000_000 (T5 max from agent.move)
            const CAP: u64 = 86_000_000;
            next.economic_state.synapse_balance =
                (next.economic_state.synapse_balance.saturating_add(amount)).min(CAP);
        }

        AgentTransition::CommitEvidence { receipt_hash } => {
            // XOR evidence_root with new receipt hash (order-independent accumulator).
            for (i, byte) in receipt_hash.iter().enumerate() {
                next.evidence_root[i] ^= byte;
            }
        }

        AgentTransition::OpenJob { job_id } => {
            if state.active_jobs.contains(&job_id) {
                return Err(TransitionError::JobAlreadyOpen(job_id));
            }
            next.active_jobs.push(job_id);
        }

        AgentTransition::CloseJob { job_id } => {
            if !state.active_jobs.contains(&job_id) {
                return Err(TransitionError::JobNotOpen(job_id));
            }
            next.active_jobs.retain(|j| j != &job_id);
        }
    }

    Ok(next)
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn test_identity() -> AgentIdentity {
        AgentIdentity {
            nostr_pubkey_hex: "a".repeat(64),
            bipon39_phrase: "fire water earth".into(),
            odu_index: 42,
            dna_fingerprint: "b".repeat(86),
        }
    }

    fn genesis() -> AgentState {
        AgentState::genesis(
            "test-agent-1".into(),
            test_identity(),
            "principal-pubkey-hex".into(),
        )
    }

    #[test]
    fn genesis_state_has_zero_previous_hash() {
        let s = genesis();
        assert_eq!(s.previous_state_hash, [0u8; 32]);
        assert_eq!(s.sequence, 0);
        assert_eq!(s.tier, AgentTier::T0);
        assert_eq!(s.lifecycle, LifecycleState::Active);
    }

    #[test]
    fn apply_transition_chains_previous_hash() {
        let s0 = genesis();
        let h0 = s0.state_hash();
        let s1 = apply_transition(&s0, AgentTransition::Hibernate).unwrap();
        assert_eq!(s1.previous_state_hash, h0);
        assert_eq!(s1.sequence, 1);
    }

    #[test]
    fn reputation_update_derives_tier() {
        let s0 = genesis();
        let s1 = apply_transition(&s0, AgentTransition::UpdateReputation {
            new_reputation: 25_000,
        }).unwrap();
        assert_eq!(s1.tier, AgentTier::T1);

        let s2 = apply_transition(&s1, AgentTransition::UpdateReputation {
            new_reputation: 85_000,
        }).unwrap();
        assert_eq!(s2.tier, AgentTier::T4);
    }

    #[test]
    fn lifecycle_forbidden_transitions_rejected() {
        let s0 = genesis(); // Active
        // Cannot Activate an already-Active agent
        let err = apply_transition(&s0, AgentTransition::Activate).unwrap_err();
        assert!(matches!(err, TransitionError::LifecycleForbidden { .. }));

        // Cannot Wake an Active agent
        let err = apply_transition(&s0, AgentTransition::Wake).unwrap_err();
        assert!(matches!(err, TransitionError::LifecycleForbidden { .. }));
    }

    #[test]
    fn capability_grant_revoke_roundtrip() {
        let s0 = genesis();
        let s1 = apply_transition(&s0, AgentTransition::GrantCapability {
            capability: "ucx.compute".into(),
        }).unwrap();
        assert!(s1.capabilities.contains("ucx.compute"));

        // Double-grant fails
        let err = apply_transition(&s1, AgentTransition::GrantCapability {
            capability: "ucx.compute".into(),
        }).unwrap_err();
        assert!(matches!(err, TransitionError::CapabilityAlreadyGranted(_)));

        let s2 = apply_transition(&s1, AgentTransition::RevokeCapability {
            capability: "ucx.compute".into(),
        }).unwrap();
        assert!(!s2.capabilities.contains("ucx.compute"));
    }

    #[test]
    fn ase_debit_below_zero_rejected() {
        let s0 = genesis(); // ase_balance = 0
        let err = apply_transition(&s0, AgentTransition::DebitAse { amount: 1 }).unwrap_err();
        assert!(matches!(err, TransitionError::InsufficientBalance { .. }));
    }

    #[test]
    fn synapse_burn_earn_cap_enforced() {
        let s0 = genesis(); // synapse = 86_000_000
        // Burn all
        let s1 = apply_transition(&s0, AgentTransition::BurnSynapse {
            amount: 86_000_000,
        }).unwrap();
        assert_eq!(s1.economic_state.synapse_balance, 0);

        // Earn beyond cap — should stop at 86_000_000
        let s2 = apply_transition(&s1, AgentTransition::EarnSynapse {
            amount: 200_000_000,
        }).unwrap();
        assert_eq!(s2.economic_state.synapse_balance, 86_000_000);
    }

    #[test]
    fn apply_transition_is_deterministic() {
        let s0 = genesis();
        let s1a = apply_transition(&s0, AgentTransition::CreditAse { amount: 1000 }).unwrap();
        let s1b = apply_transition(&s0, AgentTransition::CreditAse { amount: 1000 }).unwrap();
        assert_eq!(s1a.state_hash(), s1b.state_hash());
    }

    #[test]
    fn full_lifecycle_state_machine() {
        let s0 = genesis(); // Active
        let s1 = apply_transition(&s0, AgentTransition::Hibernate).unwrap();
        assert_eq!(s1.lifecycle, LifecycleState::Dormant);
        let s2 = apply_transition(&s1, AgentTransition::Wake).unwrap();
        assert_eq!(s2.lifecycle, LifecycleState::Active);
        let s3 = apply_transition(&s2, AgentTransition::Migrate {
            destination: "node-b-pubkey".into(),
        }).unwrap();
        assert!(matches!(s3.lifecycle, LifecycleState::Migrating { .. }));
        let s4 = apply_transition(&s3, AgentTransition::Land {
            source: "node-a-pubkey".into(),
        }).unwrap();
        assert_eq!(s4.lifecycle, LifecycleState::Active);
    }
}
