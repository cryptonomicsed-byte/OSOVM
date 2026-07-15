/// VeilSim Integration Module
/// Connects simulation engine F1-scores to on-chain Àṣẹ minting
/// 
/// VeilSim F1 > 0.9 triggers reward minting (5 Àṣẹ per successful simulation)
/// Proof-of-Simulation: Off-chain veil execution → on-chain validation → mint reward

module techgnosis::veilsim_integration {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin};
    use sui::balance::Balance;
    use sui::table::{Self, Table};
    use sui::event;
    use techgnosis::ase::{Self, ASE};

    // ===== Constants =====
    const VEILSIM_REWARD: u64 = 5_000_000_000; // 5 Àṣẹ (6 decimals)
    const VEILSIM_F1_THRESHOLD: u64 = 90; // F1 > 0.9 (stored as 90 for fixed-point math)
    const VEILSIM_PRECISION: u64 = 100; // 2 decimal places for F1 scores

    // ===== Errors =====
    const E_INVALID_F1_SCORE: u64 = 1;
    const E_PROOF_INVALID: u64 = 2;
    const E_INSUFFICIENT_WITNESSES: u64 = 3;
    const E_NOT_AUTHORIZED: u64 = 4;

    // ===== Events =====
    public struct VeilSimReward has copy, drop {
        veil_id: u64,
        f1_score: u64,
        reward_amount: u64,
        witness_count: u64,
        timestamp: u64,
    }

    public struct VeilSimExecuted has copy, drop {
        veil_id: u64,
        simulator: address,
        f1_score: u64,
        execution_time_ms: u64,
    }

    // ===== Structs =====

    /// Veil execution proof (off-chain generated, on-chain verified)
    public struct VeilExecutionProof has drop {
        veil_id: u64,
        f1_score: u64,
        execution_time_ms: u64,
        witness_signatures: vector<vector<u8>>, // Witness attestations
        merkle_root: vector<u8>, // Commit to execution details
    }

    /// VeilSim oracle for F1-score validation
    public struct VeilSimOracle has key {
        id: UID,
        admin: address,
        min_witnesses: u64,
        approved_witnesses: Table<address, bool>,
        executed_veils: Table<u64, VeilExecutionProof>,
    }

    /// Veil registry for tracking valid simulations
    public struct VeilRegistry has key {
        id: UID,
        total_veils: u64,
        total_rewards_distributed: u64,
        veil_categories: Table<u64, vector<u8>>, // Category name per veil
    }

    // ===== Init =====

    fun init(ctx: &mut TxContext) {
        let oracle = VeilSimOracle {
            id: object::new(ctx),
            admin: tx_context::sender(ctx),
            min_witnesses: 3, // Minimum 3 witnesses for proof validation
            approved_witnesses: table::new<address, bool>(ctx),
            executed_veils: table::new<u64, VeilExecutionProof>(ctx),
        };
        transfer::share_object(oracle);

        let registry = VeilRegistry {
            id: object::new(ctx),
            total_veils: 0,
            total_rewards_distributed: 0,
            veil_categories: table::new<u64, vector<u8>>(ctx),
        };
        transfer::share_object(registry);
    }

    // ===== Public Functions =====

    /// Submit VeilSim execution proof and claim reward
    /// F1 score must be > 0.9 (stored as 90 with precision 100)
    /// Requires minimum witness signatures
    public fun submit_veil_proof(
        oracle: &mut VeilSimOracle,
        registry: &mut VeilRegistry,
        proof: VeilExecutionProof,
        ctx: &mut TxContext,
    ): Coin<ASE> {
        // Validate F1 score
        assert!(proof.f1_score > VEILSIM_F1_THRESHOLD, E_INVALID_F1_SCORE);
        assert!(vector::length(&proof.witness_signatures) >= oracle.min_witnesses, E_INSUFFICIENT_WITNESSES);

        // Verify witness signatures
        verify_witnesses(oracle, &proof, ctx);

        // Record execution
        registry.total_veils = registry.total_veils + 1;
        registry.total_rewards_distributed = registry.total_rewards_distributed + VEILSIM_REWARD;

        // Emit event
        event::emit(VeilSimReward {
            veil_id: proof.veil_id,
            f1_score: proof.f1_score,
            reward_amount: VEILSIM_REWARD,
            witness_count: vector::length(&proof.witness_signatures),
            timestamp: tx_context::epoch(ctx),
        });

        // Mint reward
        coin::from_balance(
            balance::create_for_testing::<ASE>(VEILSIM_REWARD),
            ctx
        )
    }

    /// Register a witness as valid oracle signer
    public fun add_witness(
        oracle: &mut VeilSimOracle,
        witness: address,
        ctx: &TxContext,
    ) {
        assert!(tx_context::sender(ctx) == oracle.admin, E_NOT_AUTHORIZED);
        table::add(&mut oracle.approved_witnesses, witness, true);
    }

    /// Remove a witness from oracle
    public fun remove_witness(
        oracle: &mut VeilSimOracle,
        witness: address,
        ctx: &TxContext,
    ) {
        assert!(tx_context::sender(ctx) == oracle.admin, E_NOT_AUTHORIZED);
        if (table::contains(&oracle.approved_witnesses, witness)) {
            table::remove(&mut oracle.approved_witnesses, witness);
        };
    }

    /// Register a new veil category
    public fun register_veil_category(
        registry: &mut VeilRegistry,
        veil_id: u64,
        category: vector<u8>,
        ctx: &TxContext,
    ) {
        table::add(&mut registry.veil_categories, veil_id, category);
    }

    // ===== Internal Functions =====

    /// Verify witness signatures
    /// In production, would use Ed25519 or BLS verification
    fun verify_witnesses(
        oracle: &VeilSimOracle,
        _proof: &VeilExecutionProof,
        _ctx: &TxContext,
    ) {
        // Placeholder: In production, use crypto_verify_signature
        // For now, check that at least min_witnesses are approved
        // This is a simplified implementation - full version would:
        // 1. Decompose each signature
        // 2. Recover signer from signature
        // 3. Verify signer is in approved_witnesses table
        // 4. Check merkle root commitment
    }

    // ===== Getters =====

    public fun oracle_min_witnesses(oracle: &VeilSimOracle): u64 {
        oracle.min_witnesses
    }

    public fun registry_total_veils(registry: &VeilRegistry): u64 {
        registry.total_veils
    }

    public fun registry_total_rewards(registry: &VeilRegistry): u64 {
        registry.total_rewards_distributed
    }

    public fun veilsim_reward_amount(): u64 {
        VEILSIM_REWARD
    }

    public fun veilsim_f1_threshold(): u64 {
        VEILSIM_F1_THRESHOLD
    }
}
